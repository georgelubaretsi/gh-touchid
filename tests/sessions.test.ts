// Sessions, elevations, `status` and `lock`. Sessions and elevations live in this test's own `gh-touchid agent`;
// the session's program is the test runner itself, the parent of every gh-touchid a test starts.

import { describe, expect, test } from "bun:test";
import { TestEnv } from "./support/harness";

function seedAcme(env: TestEnv): void {
  env.seedApp("acme", { clientId: "Iv23liacme", clientSecret: "secret", slug: "acme-agent" });
}

/**
 * Approves the session that lists acme/widgets the way a client does: its first use asks once. No token can be minted
 * here (the stored App has no sign-in or key to mint with, and the mock no installation), so the use itself fails
 * after the approval; the approval stays.
 */
async function approveSession(env: TestEnv): Promise<void> {
  const use = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
  expect(use.auth).toHaveLength(1);
  expect(env.ghCalls()).toEqual([]);
  const status = await env.run(["status"]);
  expect(status.stdout).toMatch(/^ {2}approved +bun\[\d+\].*acme\/widgets$/m);
}

describe("session", () => {
  test("registers a pending session that status lists, and lock ends it", async () => {
    await using env = await TestEnv.create();
    const registered = await env.run(["session", "--repo", "acme/widgets", "--repo", "Acme/Gadgets"]);
    expect(registered.status).toBe(0);
    expect(registered.auth).toEqual([]);
    expect(registered.stderr).toContain("pending");
    expect(env.accessLog().some((line) => line.includes("session registered"))).toBe(true);

    const status = await env.run(["status"]);
    expect(status.status).toBe(0);
    expect(status.stdout).toMatch(/^Sessions:$/m);
    expect(status.stdout).toMatch(/^ {2}pending +bun\[\d+\].*: acme\/gadgets, acme\/widgets$/m);

    const locked = await env.run(["lock"]);
    expect(locked.status).toBe(0);
    expect(locked.stdout).toContain("Locked");
    const after = await env.run(["status"]);
    expect(after.stdout).not.toContain("Sessions:");
    expect(after.stdout).toContain("No sessions or elevations.");

    const again = await env.run(["lock"]);
    expect(again.stdout).toContain("Nothing was active.");
  });

  test("outside a repository, without --repo, there is nothing to register", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["session"]);
    expect(result.status).toBe(1);
    expect(env.agentSockets()).toEqual([]);
  });

  test("--repo takes owner/name", async () => {
    await using env = await TestEnv.create();
    for (const args of [["session", "--repo", "widgets"], ["session", "--repo", "a/b/c"]]) {
      const result = await env.run(args);
      expect(result.status).toBe(1);
    }
    expect((await env.run(["session", "--repo"])).status).toBe(2);
    expect((await env.run(["session", "--for", "1h"])).status).toBe(2);
  });

  test("an approved session gives the App's repositories without asking again", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    expect((await env.run(["session", "--repo", "acme/widgets"])).status).toBe(0);
    await approveSession(env);
    const next = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(next.auth).toEqual([]);
    expect(env.accessLog().some((line) => line.includes("session approved"))).toBe(true);
  });

  test("a denied session approval leaves the session pending", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    await env.run(["session", "--repo", "acme/widgets"]);
    const denied = await env.run(["gh", "-R", "acme/widgets", "issue", "list"], { env: { GH_TOUCHID_TEST_DENY: "1" } });
    expect(denied.status).toBe(1);
    expect(denied.auth).toHaveLength(1);
    expect(env.ghCalls()).toEqual([]);
    expect(env.mock.requests).toEqual([]);
    expect((await env.run(["status"])).stdout).toMatch(/^ {2}pending +bun/m);
    expect(env.accessLog().some((line) => line.includes("session not approved"))).toBe(true);
  });

  test("as <login> asks every time, even inside an approved session", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    env.seedAccount("alice", "ghp_alice");
    await env.run(["session", "--repo", "acme/widgets"]);
    await approveSession(env);
    for (let use = 0; use < 2; use++) {
      const result = await env.run(["as", "alice", "gh", "-R", "acme/widgets", "issue", "list"]);
      expect(result.status).toBe(0);
      expect(result.auth).toHaveLength(1);
    }
    const calls = env.ghCalls();
    expect(calls.map((call) => call.ghToken)).toEqual(["ghp_alice", "ghp_alice"]);
    expect(calls.every((call) => call.configDirEntries?.length === 0)).toBe(true);
  });
});

describe("elevate", () => {
  test("needs --for with a duration of at most one day, before asking", async () => {
    await using env = await TestEnv.create();
    const invalid = [
      ["elevate", "--repo", "acme/widgets"],
      ["elevate", "--for", "2d", "--repo", "acme/widgets"],
      ["elevate", "--for", "25h", "--repo", "acme/widgets"],
      ["elevate", "--for", "1d1m", "--repo", "acme/widgets"],
      ["elevate", "--for", "0m", "--repo", "acme/widgets"],
      ["elevate", "--for", "30", "--repo", "acme/widgets"],
      ["elevate", "--for", "soon", "--repo", "acme/widgets"],
      ["elevate", "--for", "30m", "--for", "1h", "--repo", "acme/widgets"],
      ["elevate", "--for", "30m", "--repo", "widgets"],
    ];
    for (const args of invalid) {
      const result = await env.run(args);
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
    }
    expect(env.agentSockets()).toEqual([]);
  });

  test("outside a repository, without --repo, is refused before asking", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["elevate", "--for", "30m"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
  });

  test("asks once, then status lists the elevation until lock ends it", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["elevate", "--for", "1d", "--repo", "acme/widgets", "--repo", "acme/gadgets"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("workflows");
    expect(env.accessLog().filter((line) => line.includes("elevated acme/"))).toHaveLength(2);

    const status = await env.run(["status"]);
    expect(status.stdout).toMatch(/^Elevated/m);
    expect(status.stdout).toMatch(/^ {2}acme\/gadgets +until /m);
    expect(status.stdout).toMatch(/^ {2}acme\/widgets +until /m);

    await env.run(["lock"]);
    expect((await env.run(["status"])).stdout).toContain("No sessions or elevations.");
  });

  test("a denied Touch ID elevates nothing", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["elevate", "--for", "30m", "--repo", "acme/widgets"], {
      env: { GH_TOUCHID_TEST_DENY: "1" },
    });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect((await env.run(["status"])).stdout).not.toContain("Elevated");
  });
});

describe("status", () => {
  test("lists stored Apps and accounts by name, reading no secret", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    env.writeItem("com.lubaretsi.gh-touchid.app", "beta", "not JSON at all");
    env.seedAccount("bob", "ghp_bob");
    env.seedAccount("alice", "ghp_alice");
    const result = await env.run(["status"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(result.stdout).toMatch(/^Apps \(owners\): acme, beta$/m);
    expect(result.stdout).toMatch(/^Accounts: alice, bob$/m);
    expect(result.stdout).toContain("No sessions or elevations.");
    expect(result.stdout).not.toContain("ghp_");
    expect(env.mock.requests).toEqual([]);
  });

  test("says none when nothing is stored", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["status"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/^Apps \(owners\): none$/m);
    expect(result.stdout).toMatch(/^Accounts: none$/m);
  });

  test("takes no arguments", async () => {
    await using env = await TestEnv.create();
    expect((await env.run(["status", "--all"])).status).toBe(2);
    expect((await env.run(["lock", "now"])).status).toBe(2);
  });
});
