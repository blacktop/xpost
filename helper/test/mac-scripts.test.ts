// Exercise the exact JavaScript shipped in the macOS backend against a real DOM.
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";
import { expect, test } from "vitest";

const source = await readFile(
  new URL("../../Sources/XPostTwitter/Composer.swift", import.meta.url),
  "utf8",
);
const notices = /let visibleNoticesJS = """\n([\s\S]*?)\n  """/.exec(source)?.[1];
const language = /let englishPageJS = "(.*)"/.exec(source)?.[1];
if (notices === undefined || language === undefined)
  throw new Error("macOS composer scripts missing");

const noticeScript = `(() => { const toastSel = '[data-testid="toast"]'; ${notices} })()`;
const languageScript = `(() => { ${language} })()`;

test("macOS excludes hidden success nodes and retains rendered notices", async () => {
  const browser = await chromium.launch({ timeout: 10_000 });
  try {
    const page = await browser.newPage();
    await page.setContent(`<html lang="es"><body>
      <div data-testid="toast" hidden>Your post was sent.</div>
      <div role="alert" style="display:none">Your post was sent.</div>
      <div role="alertdialog" style="visibility:hidden">Your post was sent.</div>
      <div style="display:none"><div data-testid="toast">Your post was sent.</div></div>
      <div data-testid="toast">Saving your post…</div>
    </body></html>`);
    expect(await page.evaluate(noticeScript)).toBe("Saving your post…");
    expect(await page.evaluate(languageScript)).toBe(false);
    await page.setContent(
      '<html lang="en-US"><body><div data-testid="toast">Your post was sent.</div></body></html>',
    );
    expect(await page.evaluate(noticeScript)).toBe("Your post was sent.");
    expect(await page.evaluate(languageScript)).toBe(true);
  } finally {
    await browser.close();
  }
});
