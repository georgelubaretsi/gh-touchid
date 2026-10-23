// The format of stored items: gh-touchid writes `gh-touchid format 1` in every item's description, reads an item
// without one (as 0.4.0 wrote it) as format 1, and refuses an item a newer gh-touchid wrote before any Touch ID,
// in `status` too, reading attributes only.

import { describe, expect, test } from "bun:test";
import { services, TestEnv } from "./support/harness";

const current = "gh-touchid format 1";

/** acme's App installed on acme/widgets, alice signed in, as 0.4.0 stored them: without a format. */
function seedAcme(env: TestEnv, options: { expiresIn?: number } = {}) {
  return env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"], ...options });
}

describe("writing", () => {
  test("an account token is stored in the current format", async () => {
    await using env = await TestEnv.create();
    const { token } = env.mock.seedPersonalToken("alice");
    expect((await env.run(["account", "add", "alice"], { stdin: `${token}\n` })).status).toBe(0);
    expect(env.description(services.user, "alice")).toBe(current);
  });

  test("a sign-in renewed from one 0.4.0 stored is stored in the current format", async () => {
    await using env = await TestEnv.create();
    seedAcme(env, { expiresIn: 600 });
    expect(env.description(services.signIn, "acme")).toBeUndefined();
    expect((await env.run(["gh", "-R", "acme/widgets", "issue", "list"])).status).toBe(0);
    expect(env.mock.requestsTo("POST", "/login/oauth/access_token")).toHaveLength(1);
    expect(env.description(services.signIn, "acme")).toBe(current);
  });
});

describe("items without a format", () => {
  test("are read as format 1: a use works and status lists them normally", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    env.seedAccount("alice", "ghp_alice");
    expect((await env.run(["gh", "-R", "acme/widgets", "issue", "list"])).status).toBe(0);
    const status = await env.run(["status"]);
    expect(status.stdout).toContain("acme (signed in as alice)");
    expect(status.stdout).toContain("Accounts: alice\n");
  });
});

describe("items a newer gh-touchid wrote", () => {
  const newer: [string, string, string][] = [
    ["the App", services.app, "acme"],
    ["the sign-in", services.signIn, "acme"],
  ];
  for (const [what, service, account] of newer) {
    test(`${what} in format 2 is refused before Touch ID, and nothing is minted`, async () => {
      await using env = await TestEnv.create();
      seedAcme(env);
      env.writeFormat(service, account, 2);
      const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(result.stderr).toContain("newer gh-touchid");
      expect(result.stderr).toContain("format 2");
      expect(env.mock.scopedTokens()).toEqual([]);
      expect(env.ghCalls()).toEqual([]);
      expect((await env.run(["status"])).stdout).toContain("acme (stored by a newer gh-touchid: upgrade it)");
    });
  }

  test("an account token in format 2 is refused before Touch ID", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", "ghp_alice");
    env.writeFormat(services.user, "alice", 2);
    const result = await env.run(["as", "alice", "gh", "api", "user"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toContain("newer gh-touchid");
    expect(env.ghCalls()).toEqual([]);
    expect((await env.run(["status"])).stdout).toContain("Accounts: alice (stored by a newer gh-touchid: upgrade it)");
  });
});
