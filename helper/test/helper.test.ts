import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "vitest";

import type { HelperResult } from "../src/protocol.ts";
import { FakeX, type Scenario } from "./fixtures/server.ts";

const helperScript = new URL("../dist/helper.js", import.meta.url).pathname;

interface Run {
  code: number | null;
  stdout: string;
  stderr: string;
  result: HelperResult | undefined;
}

function isResult(value: unknown): value is HelperResult {
  return typeof value === "object" && value !== null && "outcome" in value;
}

function runHelper(input: object | string, timeoutMs = 60_000): Promise<Run> {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [helperScript], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.on("data", (chunk: Buffer) => (stderr += chunk.toString()));
    const killer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.on("close", (code) => {
      clearTimeout(killer);
      let result: HelperResult | undefined;
      try {
        const parsed: unknown = JSON.parse(stdout);
        if (isResult(parsed)) result = parsed;
      } catch {
        result = undefined;
      }
      resolve({ code, stdout, stderr, result });
    });
    child.stdin.end(typeof input === "string" ? input : JSON.stringify(input));
  });
}

const x = new FakeX();
let workdir = "";

beforeAll(async () => {
  await x.start();
});

afterAll(async () => {
  await x.stop();
});

beforeEach(async () => {
  workdir = await mkdtemp(join(tmpdir(), "xpost-helper-"));
});

afterEach(async () => {
  await rm(workdir, { recursive: true, force: true });
});

/** A valid post request; an `undefined` override removes that field. */
function request(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const merged: Record<string, unknown> = {
    op: "post",
    baseURL: x.baseURL,
    username: x.username,
    password: x.password,
    accountID: x.accountID,
    text: "hello from the fixture\n\nhttps://example.com/x",
    timeoutMs: 45_000,
    ...overrides,
  };
  return Object.fromEntries(Object.entries(merged).filter(([, value]) => value !== undefined));
}

/** A cookie as a Playwright storage state holds it. */
function stateCookie(name: string, value: string, domain: string, path = "/", httpOnly = false) {
  return { name, value, domain, path, expires: -1, httpOnly, secure: false, sameSite: "Lax" };
}

describe("request validation", () => {
  test("rejects malformed JSON without starting a browser", async () => {
    const run = await runHelper("{not json");
    expect(run.code).toBe(2);
    expect(run.result).toBeUndefined();
    expect(run.stderr).toContain("bad request");
  });

  test.each([
    ["missing op", { op: undefined }],
    ["unknown op", { op: "delete" }],
    ["non-numeric account id", { accountID: "blacktop" }],
    ["post without text", { text: undefined }],
    ["zero timeout", { timeoutMs: 0 }],
  ])("rejects %s", async (_name, overrides) => {
    const run = await runHelper(request(overrides));
    expect(run.code).toBe(2);
  });
});

describe("password login", () => {
  beforeEach(() => x.reset("normal"));

  test("signs in, verifies the account, saves state and posts", async () => {
    const stateFile = join(workdir, "state.json");
    const run = await runHelper(request({ stateFile }));

    expect(run.code).toBe(0);
    expect(run.result).toMatchObject({
      outcome: "posted",
      accountID: x.accountID,
      sessionSource: "password",
      stateSaved: true,
      notice: "Your post was sent.",
    });
    expect(x.posts).toEqual([
      { text: "hello from the fixture\n\nhttps://example.com/x", hasMedia: false },
    ]);
    expect((await stat(stateFile)).mode & 0o777).toBe(0o600);
    expect(run.stderr).not.toContain(x.password);
    expect(run.stdout).not.toContain(x.password);
  });

  test("a saved state signs in without the password", async () => {
    const stateFile = join(workdir, "state.json");
    expect((await runHelper(request({ op: "check", stateFile }))).result).toMatchObject({
      outcome: "checked",
      sessionSource: "password",
      stateSaved: true,
    });

    const run = await runHelper(request({ op: "check", stateFile, password: undefined }));

    expect(run.result).toMatchObject({
      outcome: "checked",
      sessionSource: "state",
      stateSaved: false,
    });
    expect(x.loginAttempts).toBe(1);
  });

  test.each([
    { op: "check", image: false, scenario: "popupComposer" },
    { op: "post", image: false, scenario: "popupComposer" },
    { op: "post", image: true, scenario: "popupComposer" },
    { op: "post", image: true, scenario: "popupReplacesAfterUpload" },
  ] satisfies { op: string; image: boolean; scenario: Scenario }[])(
    "$scenario: $op with image=$image uses the reachable popup composer",
    async ({ op, image, scenario }) => {
      x.reset(scenario);
      const stateFile = join(workdir, "state.json");
      await writeFile(
        stateFile,
        JSON.stringify({
          cookies: [
            stateCookie("auth_token", "fixture-token", "127.0.0.1", "/", true),
            stateCookie("twid", `u%3D${x.accountID}`, "127.0.0.1"),
          ],
          origins: [],
        }),
      );
      const text = "popup draft\n\nhttps://example.com/popup";
      const imagePath = image ? join(workdir, "shot.png") : undefined;
      if (imagePath) await writeFile(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
      const run = await runHelper(request({ op, stateFile, password: undefined, text, imagePath }));
      expect(run.result).toMatchObject({
        outcome: op === "check" ? "checked" : "posted",
        sessionSource: "state",
      });
      expect(x.posts).toEqual(op === "check" ? [] : [{ text, hasMedia: image }]);
      expect(x.loginAttempts).toBe(0);
      expect(run.stdout + run.stderr).not.toContain("private background draft");
    },
  );

  test("a replaced editor cannot pass the draft check using detached text", async () => {
    x.reset("replacesComposer");
    const run = await runHelper(request());
    expect(run.result).toMatchObject({ outcome: "failed", reason: "composerUnavailable" });
    expect(x.posts).toEqual([]);
  });

  test("a saved state that no longer signs in falls back to the password", async () => {
    const stateFile = join(workdir, "state.json");
    await writeFile(stateFile, JSON.stringify({ cookies: [], origins: [] }));

    const run = await runHelper(request({ op: "check", stateFile }));

    expect(run.result).toMatchObject({
      outcome: "checked",
      sessionSource: "password",
      stateSaved: true,
    });
    expect(JSON.parse(await readFile(stateFile, "utf8"))).toMatchObject({
      cookies: expect.any(Array),
    });
  });

  test("keeps Chromium's native headless user agent", async () => {
    const run = await runHelper(request({ op: "check" }));

    expect(run.result).toMatchObject({ outcome: "checked" });
    expect(x.agents.length).toBeGreaterThan(0);
    for (const { userAgent } of x.agents) {
      expect(userAgent).toContain("HeadlessChrome/");
    }
  });

  test("still accepts the legacy Next and Log in flow", async () => {
    x.reset("legacyLogin");
    const run = await runHelper(request({ op: "check" }));
    expect(run.result).toMatchObject({ outcome: "checked", sessionSource: "password" });
    expect(x.posts).toEqual([]);
  });

  test.each(["limitedAtUsername", "limitedOnArrival"] satisfies Scenario[])(
    "%s reports X's alert without waiting for the composer",
    async (scenario) => {
      x.reset(scenario);
      const started = Date.now();
      const run = await runHelper(request({ op: "check", timeoutMs: 10_000 }));
      expect(run.result).toMatchObject({
        outcome: "failed",
        reason: "loginFailed",
        detail: expect.stringContaining("temporarily limited"),
      });
      expect(Date.now() - started).toBeLessThan(10_000);
      expect(x.posts).toEqual([]);
    },
  );

  test.each(["expired", "challenged"])(
    "%s saved state without a password never starts login",
    async (state) => {
      const stateFile = join(workdir, "state.json");
      const savedCookies =
        state === "challenged"
          ? [
              stateCookie("auth_token", "fixture-token", "127.0.0.1", "/", true),
              stateCookie("twid", `u%3D${x.accountID}`, "127.0.0.1"),
            ]
          : [];
      await writeFile(stateFile, JSON.stringify({ cookies: savedCookies, origins: [] }));
      if (state === "challenged") x.reset("stateChallenge");
      const run = await runHelper(
        request({ op: "check", stateFile, password: undefined, timeoutMs: 10_000 }),
      );
      expect(run.result).toMatchObject({
        outcome: "failed",
        reason: state === "challenged" ? "challenge" : "notSignedIn",
      });
      expect(x.loginAttempts).toBe(0);
      expect(x.posts).toEqual([]);
    },
  );

  test("without a session or a password it stops before typing anything", async () => {
    const run = await runHelper(request({ password: undefined }));

    expect(run.result).toMatchObject({ outcome: "failed", reason: "notSignedIn" });
    expect(x.loginAttempts).toBe(0);
  });

  test.for([
    { problem: "malformed JSON", contents: "{broken", mode: 0o600 },
    {
      problem: "invalid schema",
      contents: JSON.stringify({ cookies: "invalid", origins: [] }),
      mode: 0o600,
    },
    { problem: "unreadable", contents: JSON.stringify({ cookies: [], origins: [] }), mode: 0o000 },
  ])(
    "unusable saved state ($problem) falls back to the password",
    async ({ contents, mode }, { skip }) => {
      if (mode === 0o000 && process.getuid?.() === 0) skip("root can read mode-000 files");
      const stateFile = join(workdir, "state.json");
      await writeFile(stateFile, contents);
      await chmod(stateFile, mode);
      if (mode === 0o000) {
        await expect(readFile(stateFile)).rejects.toMatchObject({ code: "EACCES" });
      }

      const run = await runHelper(request({ op: "check", stateFile }));

      expect(run.code).toBe(0);
      expect(run.result).toMatchObject({
        outcome: "checked",
        sessionSource: "password",
        stateSaved: true,
      });
      expect(x.loginAttempts).toBe(1);
      expect((await stat(stateFile)).mode & 0o777).toBe(0o600);
      expect(JSON.parse(await readFile(stateFile, "utf8"))).toMatchObject({
        cookies: expect.any(Array),
      });
    },
  );

  test("unusable saved state without a password reports notSignedIn", async () => {
    const stateFile = join(workdir, "state.json");
    await writeFile(stateFile, "{broken");

    const run = await runHelper(request({ op: "check", stateFile, password: undefined }));

    expect(run.code).toBe(0);
    expect(run.result).toMatchObject({ outcome: "failed", reason: "notSignedIn" });
    expect(x.loginAttempts).toBe(0);
  });

  test("a state path that cannot be replaced leaves no session copy behind", async () => {
    const stateFile = join(workdir, "state.json");
    await mkdir(stateFile);

    const run = await runHelper(request({ op: "check", stateFile }));

    expect(run.result).toMatchObject({ outcome: "failed", reason: "internal" });
    expect(x.loginAttempts).toBe(1);
    expect(await readdir(workdir)).toEqual(["state.json"]);
  });

  test("a rejected password is reported, not retried", async () => {
    x.reset("wrongPassword");
    const run = await runHelper(request());

    expect(run.result).toMatchObject({
      outcome: "failed",
      reason: "loginFailed",
      detail: expect.stringContaining("Wrong password!"),
    });
    expect(x.loginAttempts).toBe(1);
  });
});

describe("secrets", () => {
  test("a browser error while typing the password does not disclose it", async () => {
    x.reset("passwordFieldDisabled");
    const run = await runHelper(request({ timeoutMs: 6_000 }));

    expect(run.result).toMatchObject({ outcome: "failed" });
    expect(run.stdout).not.toContain(x.password);
    expect(run.stderr).not.toContain(x.password);
  });

  // A fill that fails outright carries Playwright's call log, which repeats the typed value.
  test.each([x.password, 'a"b', "a\\b", "line\nbreak\t\u0001"])(
    "a rejected password fill does not disclose it: %j",
    async (password) => {
      x.reset("passwordFieldUnfillable");
      const run = await runHelper(request({ password }));
      expect(run.result).toMatchObject({
        outcome: "failed",
        detail: "password field cannot be filled",
      });
      for (const spelling of [password, JSON.stringify(password).slice(1, -1)]) {
        expect(run.stdout).not.toContain(spelling);
        expect(run.stderr).not.toContain(spelling);
      }
    },
  );
});

describe("challenges and account checks", () => {
  test.each(["challengeAfterUsername", "challengeAfterPassword", "captchaAfterPassword"] as const)(
    "%s stops with a challenge and no post",
    async (scenario) => {
      x.reset(scenario);
      const run = await runHelper(request({ screenshotPath: join(workdir, "shot.png") }));

      expect(run.result).toMatchObject({ outcome: "failed", reason: "challenge" });
      expect(x.posts).toEqual([]);
      expect(x.loginAttempts).toBe(1);
      expect((await stat(join(workdir, "shot.png"))).size).toBeGreaterThan(0);
    },
  );

  test("a twid cookie for another site does not vouch for the X account", async () => {
    x.reset("wrongAccount");
    const stateFile = join(workdir, "state.json");
    await writeFile(
      stateFile,
      JSON.stringify({
        cookies: [stateCookie("twid", `u%3D${x.accountID}`, "other.example")],
        origins: [],
      }),
    );

    const run = await runHelper(request({ stateFile }));

    expect(run.result).toMatchObject({ outcome: "failed", reason: "wrongAccount" });
    expect(x.posts).toEqual([]);
  });

  test("conflicting composer-path identities are rejected before posting", async () => {
    x.reset("normal");
    const stateFile = join(workdir, "state.json");
    await writeFile(
      stateFile,
      JSON.stringify({
        cookies: [
          stateCookie("auth_token", "fixture-token", "127.0.0.1", "/", true),
          stateCookie("twid", `u%3D${x.accountID}`, "127.0.0.1", "/"),
          stateCookie("twid", "u%3D999", "127.0.0.1", "/compose"),
        ],
        origins: [],
      }),
    );
    const run = await runHelper(request({ stateFile }));
    expect(run.result).toMatchObject({ outcome: "failed", reason: "wrongAccount" });
    expect(x.posts).toEqual([]);
  });

  test("another account's session is rejected and not saved", async () => {
    x.reset("wrongAccount");
    const stateFile = join(workdir, "state.json");
    const run = await runHelper(request({ stateFile }));

    expect(run.result).toMatchObject({
      outcome: "failed",
      reason: "wrongAccount",
      detail: expect.stringContaining("999"),
    });
    expect(x.posts).toEqual([]);
    await expect(stat(stateFile)).rejects.toThrow();
  });
});

describe("composer", () => {
  beforeEach(() => x.reset("normal"));

  test.each([
    ["a composer that defaults to Spanish is asked for English", "localized"],
    ["an earlier toast does not end the wait for the confirmation", "infoToastThenSent"],
  ] as const)("%s", async (_name, scenario) => {
    x.reset(scenario);
    const run = await runHelper(request());
    expect(run.result).toMatchObject({ outcome: "posted", notice: "Your post was sent." });
    expect(x.posts).toHaveLength(1);
  });

  test.each([
    ["ignores the requested locale", "ignoresLocale"],
    ["holds a restored draft", "restoredDraft"],
    ["keeps only the first line", "keepsFirstLine"],
  ] as const)("a composer that %s stops before Post", async (_name, scenario) => {
    x.reset(scenario);
    const run = await runHelper(request());
    expect(run.result).toMatchObject({ outcome: "failed", reason: "composerUnavailable" });
    expect(x.posts).toEqual([]);
  });

  // The confirmation wait runs out the budget, so keep it short.
  test.each([
    ["no toast", "ambiguous"],
    ["a hidden leftover success toast", "hiddenStaleToast"],
  ] as const)("%s means ambiguous, and Post is pressed exactly once", async (_name, scenario) => {
    x.reset(scenario);
    const run = await runHelper(request({ timeoutMs: 12_000 }));
    expect(run.result).toMatchObject({ outcome: "failed", reason: "ambiguous" });
    expect(x.posts).toHaveLength(1);
  });

  test("attaches an image before posting", async () => {
    const image = join(workdir, "shot.png");
    await writeFile(image, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    const run = await runHelper(request({ imagePath: image }));

    expect(run.result).toMatchObject({ outcome: "posted" });
    expect(x.posts).toEqual([{ text: expect.any(String), hasMedia: true }]);
  });

  test.each(["uploadFails", "popupUploadFails", "popupGlobalUploadFails"] satisfies Scenario[])(
    "%s stops before the text is posted",
    async (scenario) => {
      x.reset(scenario);
      const image = join(workdir, "shot.png");
      await writeFile(image, Buffer.from([1]));

      const run = await runHelper(request({ imagePath: image, timeoutMs: 10_000 }));

      expect(run.result).toMatchObject({
        outcome: "failed",
        reason: "uploadFailed",
        detail: "image upload failed: Media upload failed.",
      });
      expect(x.posts).toEqual([]);
    },
  );

  test("the state file's directory is created privately when missing", async () => {
    const stateFile = join(workdir, "nested", "deeper", "state.json");
    const run = await runHelper(request({ op: "check", stateFile }));

    expect(run.result).toMatchObject({ outcome: "checked", stateSaved: true });
    expect((await stat(stateFile)).mode & 0o777).toBe(0o600);
    expect((await stat(join(workdir, "nested", "deeper"))).mode & 0o777).toBe(0o700);
  });

  test("check opens the composer without posting", async () => {
    const run = await runHelper(request({ op: "check", text: undefined }));

    expect(run.result).toMatchObject({ outcome: "checked" });
    expect(x.posts).toEqual([]);
  });
});

describe("time budget", () => {
  test("a page that never answers ends as a timeout inside the budget", async () => {
    x.reset("hangsAfterPost");
    const started = Date.now();
    const run = await runHelper(request({ timeoutMs: 8_000 }));

    expect(run.result).toMatchObject({
      outcome: "failed",
      reason: expect.stringMatching(/timeout|ambiguous/),
    });
    expect(Date.now() - started).toBeLessThan(30_000);
    expect(x.posts).toHaveLength(1);
  });
});
