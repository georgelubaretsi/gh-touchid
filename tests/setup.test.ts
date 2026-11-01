// `setup`: per owner the App, the sign-in and Git, then the public reader. Without a terminal, or with --no-input, it
// does only what needs no browser (Git) and fails (exit 2, input_needed) listing the commands for the rest.

import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { lastError, services, TestEnv } from "./support/harness";
import { seedReader } from "./support/reader";

async function helpers(env: TestEnv, owner: string): Promise<string> {
  const result = await env.exec(["git", "config", "--global", "--get-all", `credential.https://github.com/${owner}.helper`]);
  return result.stdout;
}

describe("setup", () => {
  test("with everything but Git in place, sets up Git and says the rest was already done", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice" });
    seedReader(env);
    const result = await env.run(["--json", "setup", "acme"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(result.open).toEqual([]);
    expect(JSON.parse(result.stdout)).toEqual({
      steps: [
        { step: "app", owner: "acme", state: "already" },
        { step: "sign_in", owner: "acme", state: "already" },
        { step: "git", owner: "acme", state: "done" },
        { step: "reader", state: "already" },
      ],
    });
    expect(await helpers(env, "acme")).toContain("git credential");

    // run again: nothing left to do
    const again = await env.run(["setup", "acme"]);
    expect(again.status).toBe(0);
    expect(again.stdout).toContain("already git acme");
  });

  test("without owners, takes those with a stored App", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice" });
    seedReader(env);
    const result = await env.run(["--json", "setup"]);
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout).steps.filter((step: { owner?: string }) => step.owner === "acme")).toHaveLength(3);
  });

  test("without a terminal, does Git and fails naming the commands that need a browser", async () => {
    await using env = await TestEnv.create();
    env.mock.seedUser("beta");
    env.seedOwner({ owner: "acme", login: "alice", signedIn: false });
    const result = await env.run(["--json", "setup", "acme", "beta"]);
    expect(result.status).toBe(2);
    const error = lastError(result.stderr);
    expect(error.code).toBe("input_needed");
    expect(error.message).toContain("gh-touchid app login acme");
    expect(error.message).toContain("gh-touchid app create beta");
    expect(error.message).toContain("gh-touchid reader create");
    expect(result.open).toEqual([]);
    expect(result.auth).toEqual([]);
    expect(env.items(services.app)).toEqual(["acme"]);
    expect(await helpers(env, "acme")).toContain("git credential");
    expect(await helpers(env, "beta")).toContain("git credential");
  });

  test("--no-input on a terminal does the same", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice" });
    const result = await env.run(["--no-input", "setup", "acme"], { tty: true });
    expect(result.status).toBe(2);
    expect(result.stdout).toContain("gh-touchid reader create");
    expect(result.open).toEqual([]);
    expect(await Bun.file(join(env.home, ".gitconfig")).text()).toContain("git credential");
  });

  test("an owner that is not a GitHub account name is refused before anything", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["setup", "not an owner"]);
    expect(result.status).toBe(2);
    expect(await Bun.file(join(env.home, ".gitconfig")).text()).toBe("");
  });
});
