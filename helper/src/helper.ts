// Entry point: one JSON request on stdin, one JSON result on stdout, diagnostics on stderr.
// Exit 0 whenever a result was produced, including failures; 2 for a request the helper
// could not act on; 1 for anything unexpected.

import { text } from "node:stream/consumers";

import { diagnose, run } from "./flow.ts";
import { type HelperResult, RequestError, parseRequest } from "./protocol.ts";

function emit(result: HelperResult): void {
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

async function main(): Promise<number> {
  let request;
  try {
    request = parseRequest(await text(process.stdin));
  } catch (error) {
    if (error instanceof RequestError) {
      diagnose(`bad request: ${error.message}`);
      return 2;
    }
    throw error;
  }

  // A run that never comes back still ends inside the budget xpost gave it.
  const guard = setTimeout(() => {
    emit({
      outcome: "failed",
      reason: "timeout",
      detail: `no result within ${request.timeoutMs} ms`,
    });
    process.exit(0);
  }, request.timeoutMs + 5_000);

  const result = await run(request);
  clearTimeout(guard);
  emit(result);
  return 0;
}

main().then(
  (code) => process.exit(code),
  (error: unknown) => {
    diagnose(`crashed: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  },
);
