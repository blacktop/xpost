import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, onTestFinished, test, vi } from "vitest";

import { run, sameDraft } from "../src/flow.ts";

const browser = vi.hoisted(() => ({
  newContext: vi.fn(),
  close: vi.fn(),
}));
vi.mock("playwright", () => ({ chromium: { launch: async () => browser } }));

test.each([true, false])("context recovery with saved state present=%s", async (present) => {
  const directory = await mkdtemp(join(tmpdir(), "xpost-context-"));
  onTestFinished(() => rm(directory, { recursive: true, force: true }));
  const stateFile = join(directory, "state.json");
  if (present) await writeFile(stateFile, "{broken");
  const loadError = new Error("saved state could not load");
  const browserError = new Error("browser unavailable");
  browser.newContext.mockReset().mockRejectedValueOnce(loadError).mockRejectedValue(browserError);
  browser.close.mockReset();

  await expect(
    run({
      op: "check",
      baseURL: "https://x.com",
      username: "fixture",
      password: "fixture-password",
      accountID: "123",
      stateFile,
      timeoutMs: 1_000,
    }),
  ).rejects.toBe(present ? browserError : loadError);

  expect(browser.newContext.mock.calls).toEqual(
    present
      ? [[{ locale: "en-US", storageState: stateFile }], [{ locale: "en-US" }]]
      : [[{ locale: "en-US" }]],
  );
  expect(browser.close).toHaveBeenCalledOnce();
});

test.each([
  ["the same text", "hi\n\nhttps://example.com", "hi\n\nhttps://example.com"],
  [
    "extra line breaks for a blank line",
    "hi\n\n\nhttps://example.com\n",
    "hi\n\nhttps://example.com",
  ],
  ["a non-breaking space", "a\u00a0b", "a b"],
  ["next-line whitespace", "\u0085a\u0085b\u0085", "a b"],
  ["Unicode separators", "\u2028a\u2029b\u3000", "a b"],
  ["decomposed accents", "cafe\u0301", "caf\u00e9"],
])("sameDraft accepts %s", (_name, held, requested) => {
  expect(sameDraft(held, requested)).toBe(true);
});

test.each([
  ["only the first line", "hi", "hi\n\nhttps://example.com"],
  ["a restored draft before the text", "an unsent draft hi", "hi"],
  ["a lost line break", "ab", "a\nb"],
  ["an empty composer", "", "hi"],
  ["a leading byte-order mark", "\ufeffhi", "hi"],
  ["a trailing byte-order mark", "hi\ufeff", "hi"],
  ["a byte-order mark between words", "a\ufeffb", "a b"],
  ["an extra combining mark", "a \u0301b", "a b"],
])("sameDraft rejects %s", (_name, held, requested) => {
  expect(sameDraft(held, requested)).toBe(false);
});
