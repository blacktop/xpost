// Drives X's login page and composer. Selectors are the ones X served in September 2026;
// the fixture pages under test/fixtures mirror them, so a change on X's side shows up
// as a live check failure, not as a fixture failure.

import { existsSync } from "node:fs";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { type Browser, type BrowserContext, type Locator, type Page, chromium } from "playwright";

import type { FailureReason, HelperRequest, HelperResult, SessionSource } from "./protocol.ts";

const selectors = {
  usernameInput: 'input[autocomplete="username"]',
  passwordInput: 'input[name="password"]',
  loginButton: '[data-testid="LoginForm_Login_Button"]',
  /** X asks for a phone or email, a code, or a password reset here: never automated. */
  challengeInput: '[data-testid="ocfEnterTextTextInput"]',
  alert: '[role="alert"]',
  textarea: '[data-testid="tweetTextarea_0"]',
  fileInput: 'input[data-testid="fileInput"]',
  attachments: '[data-testid="attachments"]',
  postButton: '[data-testid="tweetButton"]',
  toast: '[data-testid="toast"]',
} as const;

/** The toast X shows for a sent post, as observed on 2026-09-21. */
const sentNotice = "your post was sent";

const loginPaths = ["/i/flow/", "/login"];
const challengePaths = ["/account/access", "/i/account/"];

export class FlowFailure extends Error {
  constructor(
    readonly reason: FailureReason,
    detail: string,
  ) {
    super(detail);
  }
}

/** Tracks the run's budget; every wait gets what is left of it. */
class Deadline {
  private readonly end: number;

  constructor(totalMs: number) {
    this.end = Date.now() + totalMs;
  }

  /** Milliseconds left, capped at `atMost`. Zero when the budget is spent. */
  remaining(atMost = Number.POSITIVE_INFINITY): number {
    return Math.max(0, Math.min(atMost, this.end - Date.now()));
  }

  check(step: string): void {
    if (this.remaining() === 0) throw new FlowFailure("timeout", `out of time during ${step}`);
  }
}

let redacted: string[] = [];

/** A string that must never reach stderr or the result, however it got into a message. */
export function redact(secret: string | undefined): void {
  // Escaping never shortens a string, so the escaped spelling goes first.
  redacted =
    secret === undefined || secret === "" ? [] : [JSON.stringify(secret).slice(1, -1), secret];
}

export function scrub(text: string): string {
  return redacted.reduce((clean, secret) => clean.replaceAll(secret, "[redacted]"), text);
}

export function diagnose(message: string): void {
  process.stderr.write(`helper: ${scrub(message)}\n`);
}

function readUserID(cookies: { name: string; value: string }[]): string | undefined {
  const ids = new Set<string>();
  for (const cookie of cookies.filter((item) => item.name === "twid")) {
    let value: string;
    try {
      value = decodeURIComponent(cookie.value);
    } catch {
      return undefined;
    }
    if (!/^u=[0-9]+$/.test(value)) return undefined;
    ids.add(value.slice(2));
  }
  return ids.size === 1 ? ids.values().next().value : undefined;
}

function pathOf(page: Page): string {
  return new URL(page.url()).pathname;
}

/** The first candidate on screen, or "challenge" as soon as X moves to a challenge page. */
async function firstVisible(
  page: Page,
  candidates: { name: string; locator: Locator }[],
  timeoutMs: number,
): Promise<string | undefined> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (challengePaths.some((prefix) => pathOf(page).startsWith(prefix))) return "challenge";
    for (const candidate of candidates) {
      if (await candidate.locator.first().isVisible()) return candidate.name;
    }
    await delay(250);
  }
  return undefined;
}

export async function run(request: HelperRequest): Promise<HelperResult> {
  redact(request.password);
  const deadline = new Deadline(request.timeoutMs);
  let browser: Browser | undefined;
  try {
    // The full Chromium build: the headless shell names itself HeadlessChrome in the client
    // hints too, which a user agent override cannot change.
    browser = await chromium.launch({ channel: "chromium" });
    const userAgent = await desktopUserAgent(browser);
    const stateFile =
      request.stateFile !== undefined && existsSync(request.stateFile)
        ? request.stateFile
        : undefined;
    let context: BrowserContext;
    try {
      context = await browser.newContext({
        locale: "en-US",
        userAgent,
        ...(stateFile !== undefined ? { storageState: stateFile } : {}),
      });
    } catch (error) {
      if (stateFile === undefined) throw error;
      diagnose("browser context creation failed; retrying without saved session state");
      context = await browser.newContext({ locale: "en-US", userAgent });
    }
    const page = await context.newPage();
    page.on("dialog", (dialog) => void dialog.dismiss());
    try {
      return await drive(request, context, page, deadline);
    } catch (error) {
      return await failure(error, request, page);
    }
  } finally {
    await browser?.close();
  }
}

/** The browser's own user agent, as desktop Chrome sends it: without the headless marker. */
async function desktopUserAgent(browser: Browser): Promise<string> {
  const session = await browser.newBrowserCDPSession();
  const { userAgent } = await session.send("Browser.getVersion");
  await session.detach();
  return userAgent.replace("HeadlessChrome/", "Chrome/");
}

async function drive(
  request: HelperRequest,
  context: BrowserContext,
  page: Page,
  deadline: Deadline,
): Promise<HelperResult> {
  const composer = new URL("/compose/post", request.baseURL);
  composer.searchParams.set("lang", "en");
  const composeURL = composer.toString();
  await page.goto(composeURL, { timeout: deadline.remaining(30_000) });

  let sessionSource: SessionSource = "state";
  const landed = await firstVisible(
    page,
    [
      { name: "composer", locator: page.locator(selectors.textarea) },
      { name: "login", locator: page.locator(selectors.usernameInput) },
    ],
    deadline.remaining(30_000),
  );
  if (landed === "challenge") await stopOnChallenge(page, landed);
  if (landed === "login" || loginPaths.some((prefix) => pathOf(page).startsWith(prefix))) {
    if (request.password === undefined) {
      throw new FlowFailure(
        "notSignedIn",
        "the saved session does not sign in and no password was given",
      );
    }
    sessionSource = "password";
    diagnose("saved session absent or rejected; signing in with the password");
    await login(page, request, deadline);
  } else if (landed === undefined) {
    throw new FlowFailure(
      "composerUnavailable",
      `neither composer nor login appeared (url: ${page.url()})`,
    );
  }

  // Only cookies X itself would send; an imported state may carry other sites' cookies.
  const accountID = readUserID(await context.cookies(composeURL));
  if (accountID !== request.accountID) {
    await context.clearCookies();
    throw new FlowFailure(
      "wrongAccount",
      `signed in as X user id ${accountID ?? "unknown"}, expected ${request.accountID}`,
    );
  }
  diagnose(`account verified: ${accountID}`);

  let stateSaved = false;
  if (sessionSource === "password" && request.stateFile !== undefined) {
    await saveState(context, request.stateFile);
    stateSaved = true;
    diagnose("session state saved");
  }

  if (sessionSource === "password") {
    await page.goto(composeURL, { timeout: deadline.remaining(30_000) });
  }
  deadline.check("opening the composer");
  const textarea = page.locator(selectors.textarea);
  try {
    await textarea.waitFor({ state: "visible", timeout: deadline.remaining(30_000) });
  } catch {
    throw new FlowFailure("composerUnavailable", `composer did not open (url: ${page.url()})`);
  }

  if (request.op === "check") {
    await requireEnglishComposer(page);
    return { outcome: "checked", accountID, sessionSource, stateSaved };
  }
  const notice = await compose(page, request, deadline);
  return { outcome: "posted", accountID, sessionSource, stateSaved, notice };
}

/** The state is a credential: it is never on disk with permissive bits, even briefly. */
async function saveState(context: BrowserContext, stateFile: string): Promise<void> {
  const state = await context.storageState();
  await mkdir(dirname(stateFile), { recursive: true, mode: 0o700 });
  const temporary = join(dirname(stateFile), `.${process.pid}-${Date.now()}.state.tmp`);
  try {
    await writeFile(temporary, JSON.stringify(state), { mode: 0o600, flag: "wx" });
    await rename(temporary, stateFile);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

/** One pass through X's login screens. Anything X asks beyond username and password stops here. */
async function login(page: Page, request: HelperRequest, deadline: Deadline): Promise<void> {
  const username = page.locator(selectors.usernameInput);
  await username.waitFor({ state: "visible", timeout: deadline.remaining(30_000) });
  await username.fill(request.username);
  await page.getByRole("button", { name: "Next" }).click({ timeout: deadline.remaining(10_000) });

  const afterUsername = await firstVisible(
    page,
    [
      { name: "password", locator: page.locator(selectors.passwordInput) },
      { name: "challenge", locator: page.locator(selectors.challengeInput) },
      { name: "alert", locator: page.locator(selectors.alert) },
    ],
    deadline.remaining(30_000),
  );
  if (afterUsername !== "password") await stopOnChallenge(page, afterUsername);

  try {
    await page.locator(selectors.passwordInput).fill(request.password ?? "", {
      timeout: deadline.remaining(10_000),
    });
  } catch {
    // Playwright includes the fill argument in its call log, with arbitrary escaping.
    // Never forward that error, even after redaction.
    throw new FlowFailure("loginFailed", "password field cannot be filled");
  }
  await page.locator(selectors.loginButton).click({ timeout: deadline.remaining(10_000) });

  const afterPassword = await firstVisible(
    page,
    [
      { name: "composer", locator: page.locator(selectors.textarea) },
      { name: "signedIn", locator: page.locator("body", { has: page.locator("a[href='/home']") }) },
      { name: "challenge", locator: page.locator(selectors.challengeInput) },
      { name: "alert", locator: page.locator(selectors.alert) },
    ],
    deadline.remaining(60_000),
  );
  if (afterPassword === "composer" || afterPassword === "signedIn") return;
  await stopOnChallenge(page, afterPassword);
}

async function stopOnChallenge(page: Page, seen: string | undefined): Promise<never> {
  const path = pathOf(page);
  if (seen === "challenge" || challengePaths.some((prefix) => path.startsWith(prefix))) {
    throw new FlowFailure(
      "challenge",
      `X asked for a verification step at ${path}; finish it by hand`,
    );
  }
  if (seen === "alert") {
    const text = (await page.locator(selectors.alert).first().innerText()).trim();
    throw new FlowFailure("loginFailed", `X rejected the sign-in: ${text}`);
  }
  throw new FlowFailure("loginFailed", `sign-in did not finish (url: ${page.url()})`);
}

/** Fills the open composer and presses Post; only X's toast counts as sent. */
async function compose(page: Page, request: HelperRequest, deadline: Deadline): Promise<string> {
  if (request.imagePath !== undefined) {
    await page.locator(selectors.fileInput).setInputFiles(request.imagePath);
    const uploaded = await firstVisible(
      page,
      [
        { name: "attached", locator: page.locator(selectors.attachments) },
        { name: "alert", locator: page.locator(selectors.alert) },
      ],
      deadline.remaining(60_000),
    );
    if (uploaded !== "attached") {
      const text =
        uploaded === "alert"
          ? await page.locator(selectors.alert).first().innerText()
          : "no attachment appeared";
      throw new FlowFailure("uploadFailed", `image upload failed: ${text.trim()}`);
    }
    diagnose("image attached");
  }

  const textarea = page.locator(selectors.textarea);
  const text = request.text ?? "";
  await textarea.click({ timeout: deadline.remaining(10_000) });
  await page.keyboard.insertText(text);
  const held = await textarea.innerText();
  if (!sameDraft(held, text)) {
    // Lengths only: the body stays out of diagnostics.
    throw new FlowFailure(
      "composerUnavailable",
      `composer holds ${held.length} characters, not the ${text.length} requested; ` +
        "nothing was posted",
    );
  }

  const button = page.locator(selectors.postButton);
  await button
    .and(page.locator(':not([aria-disabled="true"])'))
    .waitFor({ state: "visible", timeout: deadline.remaining(90_000) });
  deadline.check("pressing Post");
  await requireEnglishComposer(page);
  await button.click({ timeout: deadline.remaining(10_000) });
  diagnose("pressed Post");

  // Pressed once. Whatever happens now, it is never pressed again. X may show other
  // toasts first, so keep reading them until the confirmation appears or time runs out.
  const confirmBy = Date.now() + deadline.remaining(20_000);
  let notices = "";
  while (Date.now() < confirmBy) {
    const texts = await visibleTexts(page.locator(selectors.toast));
    if (texts.length > 0) notices = texts.join(" | ");
    if (notices.toLowerCase().includes(sentNotice)) return notices;
    const path = pathOf(page);
    if (loginPaths.concat(challengePaths).some((prefix) => path.startsWith(prefix))) {
      throw new FlowFailure(
        "challenge",
        `X asked to sign in instead of posting (url: ${page.url()})`,
      );
    }
    await delay(250);
  }
  throw new FlowFailure(
    "ambiguous",
    `X did not confirm the post (url: ${page.url()}; X said: ${JSON.stringify(notices)}); check the account before posting again`,
  );
}

/**
 * Whether the composer holds exactly the requested text. Whitespace may differ, since the
 * composer renders blank lines as extra line breaks; every other character must match, so a
 * truncated insert or a restored draft stops the post.
 */
export function sameDraft(held: string, requested: string): boolean {
  return normalizeDraft(held) === normalizeDraft(requested);
}

function normalizeDraft(text: string): string {
  // Match Swift's Unicode White_Space scalars. JS trim() would also remove U+FEFF.
  return text
    .normalize("NFC")
    .replace(/\p{White_Space}+/gu, " ")
    .replace(/^ | $/gu, "");
}

async function requireEnglishComposer(page: Page): Promise<void> {
  const language = await page.locator("html").getAttribute("lang");
  if (language === null || !/^en(?:-|$)/i.test(language)) {
    throw new FlowFailure(
      "composerUnavailable",
      "X did not open an English composer; nothing was posted",
    );
  }
}

/** What the toasts on screen say; a hidden leftover from an earlier post says nothing. */
async function visibleTexts(toasts: Locator): Promise<string[]> {
  const texts: string[] = [];
  for (const toast of await toasts.all()) {
    if (await toast.isVisible()) texts.push(await toast.innerText());
  }
  return texts;
}

async function failure(error: unknown, request: HelperRequest, page: Page): Promise<HelperResult> {
  const reason: FailureReason = error instanceof FlowFailure ? error.reason : "internal";
  const detail =
    error instanceof Error
      ? reason === "internal" && /Timeout .*exceeded/i.test(error.message)
        ? `out of time: ${error.message.split("\n")[0] ?? ""}`
        : error.message
      : String(error);
  const result: HelperResult = { outcome: "failed", reason, detail: scrub(detail) };
  if (request.screenshotPath !== undefined) {
    try {
      await page.screenshot({ path: request.screenshotPath, timeout: 5_000 });
      result.screenshot = request.screenshotPath;
    } catch {
      diagnose("could not take the failure screenshot");
    }
  }
  return result;
}
