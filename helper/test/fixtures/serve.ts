// Runs the fixture X on its own, for driving the xpost binary end to end:
//   node test/fixtures/serve.ts        (prints the base URL, serves until killed)
// FIXTURE_SCENARIO selects a scenario; the default is a normal login and post.

import { FakeX, scenarios } from "./server.ts";

const x = new FakeX();
const requested = process.env["FIXTURE_SCENARIO"] ?? "normal";
const scenario = scenarios.find((name) => name === requested);
if (scenario === undefined) {
  process.stderr.write(`unknown FIXTURE_SCENARIO ${requested}\n`);
  process.exit(2);
}
x.reset(scenario);
await x.start();
process.stdout.write(`${x.baseURL}\n`);
process.stderr.write(
  `fixture X (${scenario}) at ${x.baseURL}: user ${x.username}, password ${x.password}, account ${x.accountID}\n`,
);
const stop = (): void => {
  void x.stop().then(() => process.exit(0));
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
