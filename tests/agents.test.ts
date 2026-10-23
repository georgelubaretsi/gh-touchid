// Which agent a gh-touchid uses, and whom an agent obeys: one agent per user at run/agent.sock, shared by this
// gh-touchid wherever it is installed, by earlier releases on its list and by later releases that prove themselves
// by code signature; a revoked release is locked and replaced; anything else on the socket is left alone. Agents of
// 0.4.1 keep their own sockets, and their approved sessions still count. The other builds come from
// scripts/test-builds.sh (`builds` in the harness).

import { describe, expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { binary, builds, olderVersion, type Running, TestEnv } from "./support/harness";

const fakeAgent = join(import.meta.dir, "support", "fake-agent.ts");
const use = ["gh", "-R", "acme/widgets", "issue", "list"];

/** acme's App, installed on acme/widgets and acme/gadgets, with alice signed in to it. */
function seedAcme(env: TestEnv) {
  return env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets", "gadgets"] });
}

/** A code requirement that `file` meets, whichever of its architectures runs: one of its cdhashes. */
function requirementFor(file: string): string {
  const hashes = ["arm64", "x86_64"].map((architecture) => {
    const shown = Bun.spawnSync(["/usr/bin/codesign", "-d", "-vvv", "--arch", architecture, file]).stderr.toString();
    const match = shown.match(/^CDHash=([0-9a-f]{40})$/m);
    if (!match) {
      throw new Error(`no ${architecture} cdhash for ${file}:\n${shown}`);
    }
    return `cdhash H"${match[1]}"`;
  });
  return hashes.join(" or ");
}

/** The version the test build states. */
async function currentVersion(env: TestEnv): Promise<string> {
  return (await env.run(["version"])).stdout.trim();
}

/** The version the agent at run/agent.sock states; undefined when none answers. */
async function agentVersion(env: TestEnv): Promise<unknown> {
  return (await env.agentRequest({ op: "status", protocol: 1 }))?.version;
}

async function waitFor(condition: () => boolean | Promise<boolean>, what: string, timeout = 10_000): Promise<void> {
  const deadline = Date.now() + timeout;
  while (!(await condition())) {
    if (Date.now() > deadline) {
      throw new Error(`timed out waiting for ${what}`);
    }
    await Bun.sleep(20);
  }
}

/** Registers a session for acme/widgets with `build` and approves it with that build's first use. */
async function approvedSession(env: TestEnv, build: string): Promise<void> {
  const registered = await env.run(["session", "--repo", "acme/widgets"], { binary: build });
  expect(registered.status).toBe(0);
  const approved = await env.run(use, { binary: build });
  expect(approved.status).toBe(0);
  expect(approved.auth).toHaveLength(1);
}

describe("the agent at agent.sock", () => {
  test("is shared by the same gh-touchid at another path", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    const copy = join(env.dir, "elsewhere", "gh-touchid");
    mkdirSync(join(env.dir, "elsewhere"));
    copyFileSync(binary, copy);
    chmodSync(copy, 0o755);

    expect((await env.run(["session", "--repo", "acme/widgets"])).status).toBe(0);
    const approved = await env.run(use, { binary: copy });
    expect(approved.status).toBe(0);
    expect(approved.auth).toHaveLength(1);
    const next = await env.run(use);
    expect(next.status).toBe(0);
    expect(next.auth).toEqual([]);
    expect(env.agentSockets()).toEqual([env.agentSocket]);
    expect(env.accessLog().some((line) => line.includes("session approved"))).toBe(true);
  });

  test("of an earlier release on the list serves its approved session to this one without asking", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    await approvedSession(env, builds.older);
    const result = await env.run(use);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(env.ghCalls()).toHaveLength(2);
    expect(await agentVersion(env)).toBe(olderVersion);
    const grants = env.accessLog().filter((line) => /granted acme\/widgets \(session bun\[\d+\]\) as alice/.test(line));
    expect(grants).toHaveLength(2);
  });

  test("of an earlier release takes approvals from a later one that meets its code requirement", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    const older = { binary: builds.older, env: { GH_TOUCHID_TEST_PEER_REQUIREMENT: requirementFor(binary) } };
    expect((await env.run(["session", "--repo", "acme/widgets"], older)).status).toBe(0);

    const first = await env.run(use);
    expect(first.status).toBe(0);
    expect(first.auth).toHaveLength(1);
    const next = await env.run(use);
    expect(next.status).toBe(0);
    expect(next.auth).toEqual([]);
    expect(await agentVersion(env)).toBe(olderVersion);
    expect(env.accessLog().join("\n")).toMatch(/session approved: bun\[\d+\] for acme\/widgets by gh-touchid\[/);
  });

  test("of an earlier release refuses approvals from a later one that does not meet its requirement", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    const older = { binary: builds.older, env: { GH_TOUCHID_TEST_PEER_REQUIREMENT: `cdhash H"${"0".repeat(40)}"` } };
    expect((await env.run(["session", "--repo", "acme/widgets"], older)).status).toBe(0);

    const refused = await env.run(use);
    expect(refused.status).toBe(1);
    expect(refused.auth).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
    expect(env.mock.scopedTokens()).toEqual([]);
    expect(env.accessLog().join("\n")).toMatch(/refused begin-approval to .*not a gh-touchid this one trusts/);
    expect((await env.run(["status"])).stdout).toMatch(/^ {2}pending +bun/m);
  });

  test("of a later release that meets the requirement serves an earlier one without asking", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    await approvedSession(env, binary);
    const older = { binary: builds.older, env: { GH_TOUCHID_TEST_PEER_REQUIREMENT: requirementFor(binary) } };

    const result = await env.run(use, older);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(result.stderr).not.toContain("not a gh-touchid this one trusts");
    expect(await agentVersion(env)).toBe(await currentVersion(env));
    const grants = env.accessLog().filter((line) => /granted acme\/widgets \(session bun\[\d+\]\) as alice/.test(line));
    expect(grants).toHaveLength(2);
  });

  test("that meets the requirement but states no later version is not trusted, and lock leaves it", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    // the revoking build states this build's version, and its cdhash is not on this build's list
    expect((await env.run(["session", "--repo", "acme/widgets"], { binary: builds.revoking })).status).toBe(0);
    const holder = (await env.agentRequest({ op: "status", protocol: 1 }))!;
    expect(holder.sessions).toHaveLength(1);
    const meets = { env: { GH_TOUCHID_TEST_PEER_REQUIREMENT: requirementFor(builds.revoking) } };

    const locked = await env.run(["lock"], meets);
    expect(locked.stdout).toContain("Nothing was active.");
    expect(locked.stderr).toMatch(/holds agent\.sock but is not a gh-touchid this one trusts \(it meets the release/);
    expect((await env.agentRequest({ op: "status", protocol: 1 }))?.sessions).toHaveLength(1);
    expect(env.accessLog().some((line) => line.includes("agent stopped"))).toBe(false);

    const result = await env.run(use, meets);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.stderr).toContain("not a gh-touchid this one trusts");
    const status = await env.run(["status"], meets);
    expect(status.stdout).toMatch(/^Agent: .*holds agent\.sock but is not a gh-touchid this one trusts/m);
    expect((await env.agentRequest({ op: "status", protocol: 1 }))?.sessions).toHaveLength(1);
  });

  test("of a revoked release is locked, and nothing it held is carried over", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    await approvedSession(env, builds.older);
    const elevated = await env.run(["elevate", "--for", "1h", "--repo", "acme/widgets"], { binary: builds.older });
    expect(elevated.status).toBe(0);
    expect((await env.run(use, { binary: builds.older })).status).toBe(0);
    expect(env.mock.scopedTokens().at(-1)?.permissions.workflows).toBeDefined();

    const first = await env.run(use, { binary: builds.revoking });
    expect(first.status).toBe(0);
    expect(first.stderr).toContain(
      `the background program of gh-touchid ${olderVersion} was revoked and has been stopped, ending its sessions; `
        + "run `gh-touchid session` again in each program to approve it once.",
    );
    expect(first.auth).toHaveLength(1);
    expect(await agentVersion(env)).toBeUndefined();
    const log = env.accessLog();
    expect(log.some((line) => line.includes("agent stopped: locked by"))).toBe(true);
    expect(log.some((line) => line.includes(`revoked agent locked: gh-touchid ${olderVersion}`))).toBe(true);
    // the elevation ended with the revoked agent
    expect(env.mock.scopedTokens().at(-1)?.permissions.workflows).toBeUndefined();

    // no session until the program registers again: every use asks
    const second = await env.run(use, { binary: builds.revoking });
    expect(second.status).toBe(0);
    expect(second.auth).toHaveLength(1);
    expect((await env.run(["status"], { binary: builds.revoking })).stdout).toContain("No sessions or elevations.");

    // registering again: one Touch ID, then none
    await approvedSession(env, builds.revoking);
    const next = await env.run(use, { binary: builds.revoking });
    expect(next.status).toBe(0);
    expect(next.auth).toEqual([]);
  });

  test("of a revoked release is locked once when several clients meet it at once, and none replaces it", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    await approvedSession(env, builds.older);

    const results = await Promise.all([1, 2, 3].map(() => env.run(["status"], { binary: builds.revoking })));
    expect(results.map((result) => result.status)).toEqual([0, 0, 0]);
    expect(await agentVersion(env)).toBeUndefined();
    const log = env.accessLog();
    expect(log.filter((line) => line.includes("agent stopped: locked by"))).toHaveLength(1);
    expect(log.filter((line) => line.includes("agent started"))).toHaveLength(1);
  });

  test("held by a program that is not a trusted gh-touchid is left alone, and each use asks", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    mkdirSync(join(env.dir, "run"), { mode: 0o700 });
    const requests = join(env.dir, "fake-agent.log");
    const fake = env.startCommand([process.execPath, fakeAgent, env.agentSocket, requests]);
    await fake.waitForStderr(/listening/);
    const holder = `${realpathSync(process.execPath)}[${fake.process.pid}] holds agent.sock`;

    const result = await env.run(use);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.stderr).toContain(`${holder} but is not a gh-touchid this one trusts`);

    const session = await env.run(["session", "--repo", "acme/widgets"]);
    expect(session.status).toBe(1);
    expect(session.stderr).toContain(holder);
    const locked = await env.run(["lock"]);
    expect(locked.stdout).toContain("Nothing was active.");
    const status = await env.run(["status"]);
    expect(status.stdout).toContain(`Agent: ${holder}`);

    expect(fake.exited).toBe(false);
    expect(existsSync(env.agentSocket)).toBe(true);
    expect(existsSync(requests) ? readFileSync(requests, "utf8") : "").toBe("");
    const refusal = `refused the agent at agent.sock held by ${realpathSync(process.execPath)}[${fake.process.pid}]`;
    expect(env.accessLog().some((line) => line.includes(refusal))).toBe(true);
  });
});

describe("agents starting and stopping", () => {
  /** Starts an agent of the test build and waits until it serves agent.sock. */
  async function startAgent(env: TestEnv): Promise<Running> {
    const agent = env.start(["agent"]);
    await waitFor(async () => (await agentVersion(env)) !== undefined, "the agent");
    return agent;
  }

  test("two agents starting at once: one serves, and its socket stays", async () => {
    await using env = await TestEnv.create();
    for (let round = 1; round <= 3; round++) {
      const agents = [1, 2, 3, 4].map(() => env.start(["agent"]));
      await waitFor(() => agents.filter((agent) => agent.exited).length >= 3, "all but one agent to leave");
      // nothing signals that a second agent stays: one that lost its socket runs on idle, so give it time to show
      await Bun.sleep(500);
      const running = agents.filter((agent) => !agent.exited);
      expect(running).toHaveLength(1);
      for (const agent of agents.filter((agent) => agent.exited)) {
        expect((await agent.finished).status).toBe(0);
      }
      expect(await agentVersion(env)).toBe(await currentVersion(env));
      expect(env.accessLog().filter((line) => line.includes("agent started"))).toHaveLength(round);
      await env.agentRequest({ op: "lock", protocol: 1 });
      expect((await running[0]!.finished).status).toBe(0);
      expect(existsSync(env.agentSocket)).toBe(false);
    }
  });

  test("an agent stopping after another took agent.sock leaves the other's socket", async () => {
    await using env = await TestEnv.create();
    const first = await startAgent(env);
    unlinkSync(env.agentSocket);
    const second = await startAgent(env);

    first.kill("SIGTERM");
    expect((await first.finished).status).toBe(0);
    expect(existsSync(env.agentSocket)).toBe(true);
    expect(await agentVersion(env)).toBe(await currentVersion(env));
    expect(second.exited).toBe(false);
  });

  test("a request in another protocol, or none, is refused and acts on nothing", async () => {
    await using env = await TestEnv.create();
    const agent = await startAgent(env);
    const register = { op: "register", repos: ["acme/widgets"], folder: env.workDir };
    for (const request of [
      register,
      { ...register, protocol: 2, version: "99.0.0" },
      { op: "lock" },
      { op: "lock", protocol: 2 },
    ]) {
      expect(await env.agentRequest(request)).toMatchObject({ error: "protocol", protocol: 1 });
    }
    expect(agent.exited).toBe(false);
    expect(await env.agentRequest({ op: "status", protocol: 1 })).toMatchObject({ sessions: [], elevations: [] });
    expect(env.accessLog().some((line) => /refused register to .*: not protocol 1/.test(line))).toBe(true);
  });
});

describe("an agent of 0.4.1", () => {
  test("serves its approved session to this gh-touchid, and lock ends it", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    await approvedSession(env, builds.legacy);
    const [socket] = env.agentSockets();
    expect(socket).toMatch(/\/agent-[0-9a-f]{16}\.sock$/);

    const result = await env.run(use);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(env.accessLog().join("\n")).toMatch(/granted acme\/widgets \(session bun\[\d+\] of gh-touchid 0\.4\.1\)/);
    const status = await env.run(["status"]);
    expect(status.stdout).toMatch(/^ {2}approved +bun\[\d+\].*: acme\/widgets \(gh-touchid 0\.4\.1\)$/m);

    const locked = await env.run(["lock"]);
    expect(locked.stdout).toContain("Locked");
    await waitFor(() => !existsSync(socket!), "the 0.4.1 agent to stop");
    const after = await env.run(use);
    expect(after.status).toBe(0);
    expect(after.auth).toHaveLength(1);
  });

  test("keeps its pending sessions to itself", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    expect((await env.run(["session", "--repo", "acme/widgets"], { binary: builds.legacy })).status).toBe(0);

    const result = await env.run(use);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.stderr).toContain("gh-touchid session");
    expect((await env.run(["status"], { binary: builds.legacy })).stdout).toMatch(/^ {2}pending +bun/m);
  });

  test("decides, elevated, over a session here that does not list the repository", async () => {
    await using env = await TestEnv.create();
    const { installation } = seedAcme(env);
    await approvedSession(env, builds.legacy);
    const elevated = await env.run(["elevate", "--for", "1h", "--repo", "acme/widgets"], { binary: builds.legacy });
    expect(elevated.status).toBe(0);
    expect((await env.run(["session", "--repo", "acme/gadgets"])).status).toBe(0);

    const result = await env.run(use);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(env.mock.scopedTokens().at(-1)?.permissions).toEqual(installation.permissions);
    expect(installation.permissions.workflows).toBeDefined();
    const grant = /granted acme\/widgets \(session bun\[\d+\] of gh-touchid 0\.4\.1\), elevated/;
    expect(env.accessLog().join("\n")).toMatch(grant);
    const status = await env.run(["status"]);
    expect(status.stdout).toMatch(/^ {2}pending +bun\[\d+\].*: acme\/gadgets$/m);
    expect(status.stdout).toMatch(/^ {2}acme\/widgets +until .* \(gh-touchid 0\.4\.1\)$/m);
  });

  test("elevated a repository: tokens include workflows even when a session here decides", async () => {
    await using env = await TestEnv.create();
    const { installation } = seedAcme(env);
    const elevated = await env.run(["elevate", "--for", "1h", "--repo", "acme/widgets"], { binary: builds.legacy });
    expect(elevated.status).toBe(0);
    await approvedSession(env, binary);

    const result = await env.run(use);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(installation.permissions.workflows).toBeDefined();
    expect(env.mock.scopedTokens().at(-1)?.permissions).toEqual(installation.permissions);
    expect(env.accessLog().join("\n")).toMatch(/granted acme\/widgets \(session bun\[\d+\]\), elevated/);
  });
});
