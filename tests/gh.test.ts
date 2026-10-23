// `gh-touchid gh …` and `as <login> gh …`: what is refused before anyone is asked, how often Touch ID is asked, and
// what gh gets. None of these mint an App token.

import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { TestEnv } from "./support/harness";

const aliceToken = "ghp_alice0000000000000000000000000000";

describe("forbidden gh commands", () => {
  const forbidden = [
    ["auth", "token"],
    ["auth", "login", "--with-token"],
    ["auth", "status", "-t"],
    ["auth", "status", "-at"],
    ["auth", "status", "--show-token"],
    ["api", "user", "--show-token"],
    ["pr", "list", "--show-token=true"],
    ["alias", "set", "co", "pr checkout"],
    ["extension", "install", "owner/gh-extension"],
    ["extensions", "list"],
    ["ext", "list"],
  ];

  for (const argv of forbidden) {
    test(`gh ${argv.join(" ")} is refused before Touch ID, with or without an account`, async () => {
      await using env = await TestEnv.create();
      env.seedAccount("alice", aliceToken);
      env.seedApp("acme", { clientId: "Iv23liacme", clientSecret: "secret", slug: "acme-agent" });

      for (const args of [["gh", ...argv], ["as", "alice", "gh", ...argv]]) {
        const result = await env.run(args, { env: { GH_REPO: "acme/widgets" } });
        expect(result.status).toBe(1);
        expect(result.auth).toEqual([]);
        expect(result.stderr).toContain("token");
      }
      expect(env.ghEvents()).toEqual([]);
      expect(env.mock.requests).toEqual([]);
      const refusals = env.accessLog().filter((line) => line.includes(`refused gh ${argv.slice(0, 2).join(" ")}`));
      expect(refusals).toHaveLength(2);
    });
  }

  test("auth status without -t runs, as an account, after one Touch ID", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    const result = await env.run(["as", "alice", "gh", "auth", "status", "-a", "--hostname", "github.com"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(env.ghCalls().map((call) => call.argv)).toEqual([["auth", "status", "-a", "--hostname", "github.com"]]);
  });
});

describe("refusals before Touch ID", () => {
  test("an owner without an App is refused, naming the stored accounts", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    env.seedAccount("bob", "ghp_bob");
    for (const options of [{ args: ["-R", "acme/widgets"] }, { args: [], env: { GH_REPO: "acme/widgets" } }]) {
      const result = await env.run(["gh", ...options.args, "issue", "list"], { env: options.env });
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(result.stderr).toContain("acme");
      expect(result.stderr).toContain("alice");
      expect(result.stderr).toContain("bob");
    }
    expect(env.ghCalls()).toEqual([]);
    expect(env.mock.requests).toEqual([]);
    expect(env.accessLog().filter((line) => line.includes("refused acme/widgets"))).toHaveLength(2);
  });

  test("an owner without an App and no stored account says how to add one", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["gh", "-R", "acme/widgets", "pr", "list"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toContain("user add");
    expect(env.ghCalls()).toEqual([]);
  });

  test("outside a repository, with no repository named and no account, the repository is missing", async () => {
    await using env = await TestEnv.create();
    env.seedApp("acme", { clientId: "Iv23liacme", clientSecret: "secret" });
    const result = await env.run(["gh", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toMatch(/origin/);
    expect(env.ghCalls()).toEqual([]);
    expect(env.mock.requests).toEqual([]);
  });

  test("a repository that is not on GitHub is refused", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["gh", "-R", "gitlab.com/acme/widgets", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
  });
});

describe("acting as an account", () => {
  test("as <login> gh: one Touch ID, then gh with the account's token in a fresh, empty configuration", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    const result = await env.run(["as", "alice", "gh", "api", "user"], {
      env: { GITHUB_TOKEN: "ghp_leaked", GH_ENTERPRISE_TOKEN: "ghp_enterprise", GH_TOKEN: "ghp_outer" },
    });
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("alice");

    const calls = env.ghCalls();
    expect(calls).toHaveLength(1);
    const call = calls[0]!;
    expect(call.argv).toEqual(["api", "user"]);
    expect(call.ghToken).toBe(aliceToken);
    expect(call.githubToken).toBeNull();
    expect(call.ghEnterpriseToken).toBeNull();
    expect(call.configDirExists).toBe(true);
    expect(call.configDirEntries).toEqual([]);
    expect(existsSync(call.configDir!)).toBe(false);
    expect(env.accessLog().some((line) => line.includes("granted no repository (as alice)"))).toBe(true);
    // the account's token is used as stored: nothing is minted or revoked
    expect(env.mock.requests).toEqual([]);
  });

  test("every use asks again and gets its own configuration folder", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    for (let use = 0; use < 2; use++) {
      const result = await env.run(["as", "alice", "gh", "api", "user"]);
      expect(result.auth).toHaveLength(1);
    }
    const folders = env.ghCalls().map((call) => call.configDir);
    expect(new Set(folders).size).toBe(2);
  });

  test("GH_TOUCHID_AS acts as the account, like as <login>", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"], { env: { GH_TOUCHID_AS: "Alice" } });
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("acme/widgets");
    expect(env.ghCalls().map((call) => call.ghToken)).toEqual([aliceToken]);
  });

  test("gh's exit status is gh-touchid's", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    const result = await env.run(["as", "alice", "gh", "pr", "list"], {
      env: { FAKE_GH_EXIT: "3", FAKE_GH_STDOUT: "from gh\n" },
    });
    expect(result.status).toBe(3);
    expect(result.stdout).toBe("from gh\n");
  });

  test("as <login> with no stored token is refused before Touch ID", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    for (const args of [["as", "carol", "gh", "api", "user"], ["gh", "api", "user"]]) {
      const result = await env.run(args, { env: args[0] === "gh" ? { GH_TOUCHID_AS: "carol" } : {} });
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(result.stderr).toContain("user add carol");
    }
    expect(env.ghCalls()).toEqual([]);
  });

  test("an invalid login is refused", async () => {
    await using env = await TestEnv.create();
    const as = await env.run(["as", "not a login", "gh", "api", "user"]);
    expect(as.status).toBe(1);
    const variable = await env.run(["gh", "api", "user"], { env: { GH_TOUCHID_AS: "not/a/login" } });
    expect(variable.status).toBe(1);
    expect([...as.auth, ...variable.auth]).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
  });

  test("as <login> <command> runs the command with GH_TOUCHID_AS, without Touch ID", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    const result = await env.run(["as", "alice", "/usr/bin/env"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(result.stdout.split("\n")).toContain("GH_TOUCHID_AS=alice");
    expect(result.stdout).not.toContain(aliceToken);
  });
});

describe("Touch ID outcomes", () => {
  test("a denied Touch ID refuses the use: logged, gh never runs", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    const result = await env.run(["as", "alice", "gh", "api", "user"], { env: { GH_TOUCHID_TEST_DENY: "1" } });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect(result.stderr).toContain("Touch ID");
    expect(env.ghEvents().filter((event) => event.kind === "run")).toEqual([]);
    expect(env.accessLog().some((line) => line.includes("refused"))).toBe(true);
    expect(env.accessLog().some((line) => line.includes("granted"))).toBe(false);
  });

  test("a denied Touch ID for an owner's App mints nothing", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"], { env: { GH_TOUCHID_TEST_DENY: "1" } });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("acme/widgets");
    expect(env.ghCalls()).toEqual([]);
    expect(env.mock.requests).toEqual([]);
    expect(env.accessLog().some((line) => line.includes("refused acme/widgets"))).toBe(true);
  });

  test("a locked screen fails without asking", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    for (const args of [["as", "alice", "gh", "api", "user"], ["gh", "-R", "acme/widgets", "issue", "list"]]) {
      const result = await env.run(args, { env: { GH_TOUCHID_TEST_SCREEN_LOCKED: "1" } });
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(result.stderr).toContain("screen is locked");
    }
    expect(env.ghCalls()).toEqual([]);
    expect(env.mock.requests).toEqual([]);
  });
});

describe("gh help reference", () => {
  test("is read only when a flag before -R may take it as its value", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    await env.run(["as", "alice", "gh", "issue", "list", "-R", "acme/widgets"]);
    expect(env.ghEvents().filter((event) => event.kind === "reference")).toEqual([]);

    // `-l` takes a value in `issue list`, so `-R` here is the label, not the repository
    const result = await env.run(["as", "alice", "gh", "issue", "list", "-l", "-R", "--repo", "acme/widgets"]);
    expect(result.status).toBe(0);
    const reference = env.ghEvents().filter((event) => event.kind === "reference");
    expect(reference).toHaveLength(1);
    expect(reference[0]!.hasGhToken).toBe(false);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("acme/widgets");
  });

  test("as an account, an ambiguous -R that the reference cannot settle is refused", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", aliceToken);
    const result = await env.run(["as", "alice", "gh", "issue", "list", "-l", "-R", "--repo", "acme/widgets"], {
      env: { FAKE_GH_REFERENCE_EXIT: "1" },
    });
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
  });
});
