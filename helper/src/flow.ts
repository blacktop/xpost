// Drives X's login page and composer. Selectors are the ones X served in September 2026;
// the fixture pages under test/fixtures mirror them, so a change on X's side shows up
// as a live check failure, not as a fixture failure.

import { existsSync } from "node:fs";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import {
  type Browser,
  type BrowserContext,
  type ElementHandle,
  type Locator,
  type Page,
  chromium,
} from "playwright";

import type { FailureReason, HelperRequest, HelperResult, SessionSource } from "./protocol.ts";

const selectors = {
  usernameInput: 'input[autocomplete~="username"]:visible, input[name="username_or_email"]:visible',
  passwordInput: 'input[name="password"]:visible, input[type="password"]:visible',
  /** X asks for a phone or email, a code, or a password reset here: never automated. */
  challengeInput: '[data-testid="ocfEnterTextTextInput"], input[autocomplete="one-time-code"]',
  alert: '[role="alert"]',
  textarea: '[data-testid="tweetTextarea_0"]',
  fileInput: 'input[data-testid="fileInput"]',
  attachments: '[data-testid="attachments"]',
  postButton: '[data-testid="tweetButton"]',
  toast: '[data-testid="toast"]',
} as const;

/** The toast X shows for a sent post, as observed on 2026-09-21. */
const sentNotice = "your post was sent";

const loginPaths = ["/i/flow/", "/i/jf/", "/login"];
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
      if (await candidate.locator.filter({ visible: true }).first().isVisible())
        return candidate.name;
    }
    if (
      candidates.some(({ name }) => name === "login") &&
      loginPaths.some((prefix) => pathOf(page).startsWith(prefix))
    ) {
      return "login";
    }
    await delay(250);
  }
  return undefined;
}

/** X keeps another editor behind its popup; select the element a centre click reaches. */
async function reachableComposer(
  page: Page,
  timeoutMs: number,
): Promise<ElementHandle<HTMLElement>> {
  try {
    const handle = await page.waitForFunction(
      (selector) => {
        for (const element of document.querySelectorAll<HTMLElement>(selector)) {
          const box = element.getBoundingClientRect();
          if (box.width <= 0 || box.height <= 0) continue;
          const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
          if (hit && (element === hit || element.contains(hit))) return element;
        }
        return null;
      },
      selectors.textarea,
      { timeout: Math.max(1, timeoutMs) },
    );
    const element = handle.asElement();
    if (element) return element;
    await handle.dispose();
    throw new Error("composer is no longer available");
  } catch (error) {
    // Playwright's later call-log lines can contain draft text.
    const detail = error instanceof Error ? error.message.split("\n")[0] : "unknown browser error";
    throw new FlowFailure(
      "composerUnavailable",
      `composer did not open: ${detail} (url: ${page.url()})`,
    );
  }
}

export async function run(request: HelperRequest): Promise<HelperResult> {
  redact(request.password);
  if (
    request.password === undefined &&
    (request.stateFile === undefined || !existsSync(request.stateFile))
  ) {
    return {
      outcome: "failed",
      reason: "notSignedIn",
      detail: "no saved session is available; export a session with xpost twitter export-session",
    };
  }
  const deadline = new Deadline(request.timeoutMs);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const stateFile =
      request.stateFile !== undefined && existsSync(request.stateFile)
        ? request.stateFile
        : undefined;
    let context: BrowserContext;
    try {
      context = await browser.newContext({
        locale: "en-US",
        ...(stateFile !== undefined ? { storageState: stateFile } : {}),
      });
    } catch (error) {
      if (stateFile === undefined) throw error;
      if (request.password === undefined) {
        return {
          outcome: "failed",
          reason: "notSignedIn",
          detail:
            "saved session could not load; export a new session with xpost twitter export-session",
        };
      }
      diagnose("browser context creation failed; retrying without saved session state");
      context = await browser.newContext({ locale: "en-US" });
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
      { name: "alert", locator: page.locator(selectors.alert) },
      { name: "composer", locator: page.locator(selectors.textarea) },
      { name: "login", locator: page.locator(selectors.usernameInput) },
    ],
    deadline.remaining(30_000),
  );
  if (landed === "challenge" || landed === "alert") await stopOnChallenge(page, landed);
  if (landed === "login" || loginPaths.some((prefix) => pathOf(page).startsWith(prefix))) {
    if (request.password === undefined) {
      throw new FlowFailure(
        "notSignedIn",
        "saved session was rejected or expired; export a new session with xpost twitter export-session",
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
  const textarea = await reachableComposer(page, deadline.remaining(30_000));
  await textarea.dispose();

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
  // The new flow keeps the old username form behind its modal. Only operate in the modal.
  const dialogs = page.locator('[role="dialog"]:visible');
  const surface = (await dialogs.count()) > 0 ? dialogs.last() : page.locator("body");
  const username = surface.locator(selectors.usernameInput).first();
  const initial = await firstVisible(
    page,
    [
      { name: "alert", locator: surface.locator(selectors.alert) },
      { name: "challenge", locator: surface.locator(selectors.challengeInput) },
      { name: "username", locator: username },
    ],
    deadline.remaining(30_000),
  );
  if (initial !== "username") await stopOnChallenge(page, initial);
  await username.fill(request.username);
  await surface
    .getByRole("button", { name: /^(next|continue)$/i })
    .filter({ visible: true })
    .click({ timeout: deadline.remaining(10_000) });

  const afterUsername = await firstVisible(
    page,
    [
      { name: "alert", locator: surface.locator(selectors.alert) },
      { name: "challenge", locator: surface.locator(selectors.challengeInput) },
      { name: "password", locator: surface.locator(selectors.passwordInput) },
    ],
    deadline.remaining(30_000),
  );
  if (afterUsername !== "password") await stopOnChallenge(page, afterUsername);

  try {
    await surface
      .locator(selectors.passwordInput)
      .first()
      .fill(request.password ?? "", {
        timeout: deadline.remaining(10_000),
      });
  } catch {
    // Playwright includes the fill argument in its call log, with arbitrary escaping.
    // Never forward that error, even after redaction.
    throw new FlowFailure("loginFailed", "password field cannot be filled");
  }
  await surface
    .getByRole("button", { name: /^(log in|continue)$/i })
    .filter({ visible: true })
    .click({ timeout: deadline.remaining(10_000) });

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
    const text = (
      await page.locator(selectors.alert).filter({ visible: true }).first().innerText()
    ).trim();
    throw new FlowFailure("loginFailed", `X rejected the sign-in: ${text}`);
  }
  throw new FlowFailure("loginFailed", `sign-in did not finish (url: ${page.url()})`);
}

/** Upload only within the selected editor's dialog, or its nearest upload container. */
async function uploadImage(
  page: Page,
  textarea: ElementHandle<HTMLElement>,
  imagePath: string,
  deadline: Deadline,
): Promise<void> {
  const handle = await textarea.evaluateHandle((element, fileInput) => {
    if (!element.isConnected) return null;
    const dialog = element.closest('[role="dialog"]');
    if (dialog) return dialog;
    for (let parent = element.parentElement; parent; parent = parent.parentElement) {
      if (parent.querySelector(fileInput)) return parent;
    }
    return null;
  }, selectors.fileInput);
  try {
    const container = handle.asElement();
    if (!container) throw new FlowFailure("uploadFailed", "composer has no upload container");
    const input = await container.waitForSelector(selectors.fileInput, {
      state: "attached",
      strict: true,
      timeout: Math.max(1, deadline.remaining(10_000)),
    });
    if (!input) throw new FlowFailure("uploadFailed", "composer has no file input");
    try {
      await input.setInputFiles(imagePath, { timeout: Math.max(1, deadline.remaining(10_000)) });
    } finally {
      await input.dispose();
    }
    const alert = page.locator(selectors.alert).filter({ visible: true }).first();
    const finishBy = Date.now() + deadline.remaining(60_000);
    while (Date.now() < finishBy) {
      if (await alert.isVisible()) {
        throw new FlowFailure(
          "uploadFailed",
          `image upload failed: ${(await alert.innerText()).trim()}`,
        );
      }
      const attachment = await container.$(`${selectors.attachments}:visible`);
      if (attachment) {
        await attachment.dispose();
        diagnose("image attached");
        return;
      }
      await delay(250);
    }
    throw new FlowFailure("uploadFailed", "no attachment appeared");
  } catch (error) {
    if (error instanceof FlowFailure) throw error;
    const detail = error instanceof Error ? error.message.split("\n")[0] : "unknown browser error";
    throw new FlowFailure("uploadFailed", `image upload failed: ${detail}`);
  } finally {
    await handle.dispose();
  }
}

/** Fills the open composer and presses Post; only X's toast counts as sent. */
async function compose(page: Page, request: HelperRequest, deadline: Deadline): Promise<string> {
  let textarea = await reachableComposer(page, deadline.remaining(10_000));
  const text = request.text ?? "";
  let held: string | null;
  try {
    if (request.imagePath !== undefined) {
      await uploadImage(page, textarea, request.imagePath, deadline);
      await textarea.dispose();
      textarea = await reachableComposer(page, deadline.remaining(10_000));
    }
    await textarea.click({ timeout: deadline.remaining(10_000) });
    await page.keyboard.insertText(text);
    held = await textarea.evaluate((element) => (element.isConnected ? element.innerText : null));
  } finally {
    await textarea.dispose();
  }
  if (held === null) {
    throw new FlowFailure("composerUnavailable", "composer was replaced; nothing was posted");
  }
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
