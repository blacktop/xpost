import { expect, test } from "vitest";
import { redact, scrub } from "../src/flow.ts";

test.each(['a"b', "a\\b", "line\nbreak\t\u0001"])(
  "scrub covers serialized secrets: %j",
  (password) => {
    redact(password);
    expect(scrub(`fill(${JSON.stringify(password)})`)).toBe('fill("[redacted]")');
    expect(scrub(password)).toBe("[redacted]");
  },
);

test("scrub removes the registered secret wherever it appears", () => {
  redact("hunter2");

  expect(scrub('locator.fill("hunter2") failed; retry hunter2')).toBe(
    'locator.fill("[redacted]") failed; retry [redacted]',
  );
  expect(scrub("nothing here")).toBe("nothing here");
});

test.each([undefined, ""])("no password (%j) redacts nothing", (password) => {
  redact("hunter2");
  redact(password);

  expect(scrub("hunter2")).toBe("hunter2");
});
