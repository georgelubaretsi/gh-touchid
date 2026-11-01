// `status --json`: the same facts as `status`, as data; the public reader's line from its item's comment alone.

import { describe, expect, test } from "bun:test";
import { TestEnv } from "./support/harness";
import { readerAccount, readerService, seedReader } from "./support/reader";

describe("status --json", () => {
  test("names Apps, accounts, the reader, Git, gh, the agent, sessions and elevations, reading no secret", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice" });
    env.seedAccount("bob", "ghp_bob");
    const reader = seedReader(env, { owner: "carol" });
    const result = await env.run(["status", "--json"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(result.stdout).not.toMatch(/gh[pousr]_|BEGIN/);
    const status = JSON.parse(result.stdout);
    expect(Object.keys(status).sort()).toEqual(
      ["accounts", "agent", "apps", "elevations", "gh", "git", "reader", "sessions"],
    );
    expect(status.apps).toEqual([{ owner: "acme", login: "alice", problem: null }]);
    expect(status.accounts).toEqual([{ login: "bob", problem: null }]);
    expect(status.reader).toEqual({ app: reader.slug, owner: "carol" });
    // the test build has no gh of its own
    expect(status.gh).toMatchObject({ wrapper: null, is_wrapper: false, path_folder: null, alias_command: null });
    expect(status.agent).toBeNull();
    expect(status.sessions).toEqual([]);
    expect(status.elevations).toEqual([]);
    expect(env.mock.requests).toEqual([]);
  });

  test("an App item another gh-touchid wrote in a newer format is a problem, not a login", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice" });
    env.writeFormat("com.lubaretsi.gh-touchid.app", "acme", 99);
    const status = JSON.parse((await env.run(["--json", "status"])).stdout);
    expect(status.apps).toEqual([{ owner: "acme", login: null, problem: "stored by a newer gh-touchid: upgrade it" }]);
  });
});

describe("status: the reader line", () => {
  test("says none when no reader is stored", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["status"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/^Accounts: none\nReader: none$/m);
  });

  test("names the reader and its owner from the item's comment, with no request", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env, { owner: "carol" });
    const result = await env.run(["status"]);
    expect(result.stdout).toMatch(new RegExp(`^Reader: ${reader.slug} on carol$`, "m"));
    expect(env.mock.requests).toEqual([]);
  });

  test("a reader item in a newer format is named with its problem", async () => {
    await using env = await TestEnv.create();
    seedReader(env, { owner: "carol" });
    env.writeFormat(readerService, readerAccount, 99);
    const result = await env.run(["status"]);
    expect(result.stdout).toMatch(/^Reader: .* \(stored by a newer gh-touchid: upgrade it\)$/m);
    const status = JSON.parse((await env.run(["--json", "status"])).stdout);
    expect(status.reader.problem).toBe("stored by a newer gh-touchid: upgrade it");
  });
});
