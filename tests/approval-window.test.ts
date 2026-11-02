// The approval window leaves the screen as soon as it is answered, even when gh-touchid keeps the main thread busy
// right after, as `reader create` and `setup` do while they wait for the browser and as a long gh command does. Once
// it stayed, frozen at "approval needed", until the process exited. With GH_TOUCHID_TEST_APPROVAL_WINDOW=1 a test
// build shows the real window, answers it itself instead of Touch ID, stays busy for 0.7 s, and prints the largest
// alpha the window server gives its windows on screen (`WINDOW: <alpha>`): a window that was taken away has faded to
// about 0, one still drawn is at 1. It needs a login session with a window server, as macOS runners have, and an
// unlocked screen: while the screen is locked the window server does not take windows away, so the test is skipped,
// and says so, rather than fail on a Mac its user stepped away from.

import { expect, test } from "bun:test";
import { TestEnv } from "./support/harness";

const screenLocked = /"CGSSessionScreenIsLocked"=Yes/.test(
  Bun.spawnSync(["/usr/sbin/ioreg", "-n", "Root", "-d1"]).stdout.toString(),
);

test.skipIf(screenLocked)("after Touch ID answers, the approval window is off the screen while gh-touchid goes on", async () => {
  await using env = await TestEnv.create();
  env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
  const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"], {
    env: { GH_TOUCHID_TEST_APPROVAL_WINDOW: "1" },
  });
  expect(result.status).toBe(0);
  expect(result.auth).toHaveLength(1);
  const report = result.stderr.split("\n").find((line) => line.startsWith("WINDOW: "));
  expect(report).toBeDefined();
  expect(report).not.toContain("unavailable");
  expect(Number(report!.slice("WINDOW: ".length))).toBeLessThan(0.1);
});
