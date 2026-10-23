// `user add <login>` stores a token of one of your accounts once GitHub (GET /user) confirms its login, after one
// Touch ID; `user remove <login>` deletes it.

import { describe, expect, test } from "bun:test";
import { services, TestEnv } from "./support/harness";

describe("user add", () => {
  test("stores a token GitHub confirms, after one Touch ID", async () => {
    await using env = await TestEnv.create();
    const { token } = env.mock.seedPersonalToken("alice", { scopes: "repo, workflow" });
    const result = await env.run(["user", "add", "Alice"], { stdin: `${token}\n` });
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("alice");
    expect(env.items(services.user)).toEqual(["alice"]);
    expect(env.item(services.user, "alice")).toBe(token);

    const asked = env.mock.requestsTo("GET", "/user");
    expect(asked).toHaveLength(1);
    expect(asked[0]!.headers.authorization).toBe(`Bearer ${token}`);
  });

  test("refuses a token of another account, storing nothing", async () => {
    await using env = await TestEnv.create();
    const { token } = env.mock.seedPersonalToken("bob");
    const result = await env.run(["user", "add", "alice"], { stdin: `${token}\n` });
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toContain("bob");
    expect(env.items(services.user)).toEqual([]);
  });

  test("refuses a token GitHub does not accept, storing nothing", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["user", "add", "alice"], { stdin: "ghp_unknown\n" });
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(env.mock.requestsTo("GET", "/user")).toHaveLength(1);
    expect(env.items(services.user)).toEqual([]);
  });

  test("refuses input that is not a token without asking GitHub", async () => {
    await using env = await TestEnv.create();
    for (const stdin of ["", "\n", "ghp_two words\n", "ghp_\u00e9t\u00e9\n"]) {
      const result = await env.run(["user", "add", "alice"], { stdin });
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
    }
    expect(env.mock.requests).toEqual([]);
    expect(env.items(services.user)).toEqual([]);
  });

  test("stores nothing when Touch ID is denied", async () => {
    await using env = await TestEnv.create();
    const { token } = env.mock.seedPersonalToken("alice");
    const result = await env.run(["user", "add", "alice"], { stdin: `${token}\n`, env: { GH_TOUCHID_TEST_DENY: "1" } });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect(env.items(services.user)).toEqual([]);
  });

  test("replaces the stored token of the account", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", "ghp_old");
    const { token } = env.mock.seedPersonalToken("alice");
    const result = await env.run(["user", "add", "alice"], { stdin: `${token}\n` });
    expect(result.status).toBe(0);
    expect(env.item(services.user, "alice")).toBe(token);
  });
});

describe("user remove", () => {
  test("deletes the stored token, and says when there is none", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", "ghp_alice");
    env.seedAccount("bob", "ghp_bob");
    const removed = await env.run(["user", "remove", "alice"]);
    expect(removed.status).toBe(0);
    expect(removed.auth).toEqual([]);
    expect(env.items(services.user)).toEqual(["bob"]);

    const again = await env.run(["user", "remove", "alice"]);
    expect(again.status).toBe(1);
    expect(again.stderr).toContain("alice");
    expect(env.items(services.user)).toEqual(["bob"]);
  });
});

test("user takes add or remove and one login", async () => {
  await using env = await TestEnv.create();
  for (const args of [["user"], ["user", "add"], ["user", "list"], ["user", "add", "alice", "bob"]]) {
    const result = await env.run(args);
    expect(result.status).toBe(2);
    expect(result.auth).toEqual([]);
  }
  const invalid = await env.run(["user", "add", "not a login"]);
  expect(invalid.status).toBe(1);
  expect(env.mock.requests).toEqual([]);
});
