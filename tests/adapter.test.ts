// `gh-touchid mcp` and `gh-touchid rpc`: the test build execs gh-touchid-adapter, which serves MCP (the official Swift
// SDK) or JSON-RPC 2.0 over stdio and runs the core once per call with `--json --input -`. These tests speak both by
// hand, one JSON message per line: the tools are the core's own declarations, results and errors carry the core's
// JSON and codes, secrets are refused, a cancelled call's core is ended (and gh's token still revoked), and the core
// sees the client, not the adapter, as the program that asked.

import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { isRunning, StdioClient, waitForExit } from "./support/adapter";
import { builds, services, TestEnv } from "./support/harness";

/** The program the core names in its dialogs and sessions: this test runner. */
const client = basename(process.execPath);

/** The tools `gh-touchid --help --json` declares. */
async function declaredTools(env: TestEnv): Promise<Record<string, any>[]> {
  const help = await env.run(["--help", "--json"]);
  expect(help.status).toBe(0);
  return JSON.parse(help.stdout).tools;
}

function errorOf(result: Record<string, any>): { code: string; message: string } {
  expect(result.isError).toBe(true);
  return JSON.parse(result.content[0].text).error;
}

describe("gh-touchid mcp", () => {
  test("initializes, lists the core's tools as declared, and calls version and status", async () => {
    await using env = await TestEnv.create();
    await using mcp = StdioClient.start(env, "mcp");
    const initialized = await mcp.initialize();
    expect(initialized.result.serverInfo.name).toBe("gh-touchid");
    expect(initialized.result.capabilities.tools).toBeDefined();

    const listed = await mcp.request("tools/list", {});
    expect(listed.result.tools).toEqual(await declaredTools(env));

    const version = await mcp.request("tools/call", { name: "version", arguments: {} });
    const expected = (await env.run(["version"])).stdout.trim();
    expect(version.result.isError).toBeFalsy();
    expect(version.result.structuredContent).toEqual({ version: expected });
    expect(version.result.content).toHaveLength(1);
    expect(version.result.content[0].type).toBe("text");
    expect(JSON.parse(version.result.content[0].text)).toEqual({ version: expected });

    const status = await mcp.request("tools/call", { name: "status", arguments: {} });
    expect(status.result.isError).toBeFalsy();
    for (const key of ["apps", "accounts", "reader", "git", "gh", "agent", "sessions", "elevations"]) {
      expect(status.result.structuredContent).toHaveProperty(key);
    }
    expect(JSON.parse(status.result.content[0].text)).toEqual(status.result.structuredContent);
    expect(mcp.garbage).toEqual([]);
    expect(mcp.auth).toEqual([]);
    expect(env.mock.requests).toEqual([]);

    expect(await mcp.close()).toBe(0);
    expect(mcp.children()).toEqual([]);
  });

  test("refuses a tool whose input is a secret, naming the command that takes it on stdin", async () => {
    await using env = await TestEnv.create();
    await using mcp = StdioClient.start(env, "mcp");
    await mcp.initialize();
    const secret = (await declaredTools(env)).filter((tool) => tool._meta?.["gh-touchid/secret"] === "input");
    expect(secret.map((tool) => tool.name).sort()).toEqual(["account_add", "app_add", "reader_add"]);

    const reply = await mcp.request("tools/call", {
      name: "account_add",
      arguments: { login: "alice", token: "ghp_notarealtoken0000000000000000000000" },
    });
    const error = errorOf(reply.result);
    expect(error.code).toBe("secret_needs_stdin");
    expect(error.message).toContain("gh-touchid account add");
    expect(mcp.auth).toEqual([]);
    expect(env.items(services.user)).toEqual([]);
    expect(env.mock.requests).toEqual([]);
    expect(mcp.stderr).not.toContain("ghp_notarealtoken");
  });

  test("a failing call is a tool error carrying the core's code", async () => {
    await using env = await TestEnv.create();
    await using mcp = StdioClient.start(env, "mcp");
    await mcp.initialize();

    const invalid = await mcp.request("tools/call", { name: "version", arguments: { verbose: true } });
    expect(errorOf(invalid.result).code).toBe("invalid_input");
    expect(invalid.result._meta["gh-touchid/error"].code).toBe("invalid_input");

    const missing = await mcp.request("tools/call", { name: "app_login", arguments: { owner: "acme" } });
    const error = errorOf(missing.result);
    expect(error.code).toBe("missing_app");
    expect(error.message).toContain("acme");
    expect(missing.result.structuredContent).toBeUndefined();

    const unknown = await mcp.request("tools/call", { name: "no_such_tool", arguments: {} });
    expect(unknown.error.code).toBe(-32602);
  });

  test("cancelling a call ends its core, which revokes gh's token, and answers nothing", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    await using mcp = StdioClient.start(env, "mcp", { env: { FAKE_GH_MODE: "sleep" } });
    await mcp.initialize();

    const id = mcp.begin("tools/call", {
      name: "gh",
      arguments: { argv: ["-R", "acme/widgets", "pr", "list"] },
      _meta: { progressToken: "gh-1" },
    });
    await env.waitForGhCalls(1);
    const [core] = mcp.children();
    expect(core).toBeNumber();
    expect(mcp.auth).toHaveLength(1);
    expect(mcp.auth[0]).toContain(`let ${client} run`);

    mcp.notify("notifications/cancelled", { requestId: id, reason: "test" });
    await waitForExit(core!);
    expect(env.ghRunsAndSignals()).toEqual(["run", "SIGTERM"]);
    const scoped = env.mock.scopedTokens();
    expect(scoped).toHaveLength(1);
    expect(scoped[0]!.revoked).toBe(true);

    // still serving, and the cancelled call got no response
    const after = await mcp.request("tools/call", { name: "version", arguments: {} });
    expect(after.result.isError).toBeFalsy();
    expect(mcp.messages.filter((message) => message.id === id && !("method" in message))).toEqual([]);
  });
});

describe("gh-touchid rpc", () => {
  test("a method is an operation: params in, result out, params._meta taken off", async () => {
    await using env = await TestEnv.create();
    await using rpc = StdioClient.start(env, "rpc");
    const expected = (await env.run(["version"])).stdout.trim();

    const reply = await rpc.request("version", {});
    expect(reply).toEqual({ jsonrpc: "2.0", id: reply.id, result: { version: expected } });

    const withMeta = await rpc.request("version", { _meta: { progressToken: "t1" } });
    expect(withMeta.result).toEqual({ version: expected });

    const noParams = await rpc.request("version");
    expect(noParams.result).toEqual({ version: expected });

    const status = await rpc.request("status", {});
    expect(status.result).toHaveProperty("apps");
    expect(rpc.garbage).toEqual([]);
    expect(await rpc.close()).toBe(0);
  });

  test("a malformed line gets -32700 and the next line is still answered", async () => {
    await using env = await TestEnv.create();
    await using rpc = StdioClient.start(env, "rpc");
    rpc.writeLine("{this is not json");
    const parseError = await rpc.response(null);
    expect(parseError.error.code).toBe(-32700);
    expect(parseError.error.data.code).toBe("parse_error");

    const reply = await rpc.request("version", {});
    expect(reply.result.version).toBeString();
  });

  test("an unknown method gets -32601; bad requests and params are refused without running anything", async () => {
    await using env = await TestEnv.create();
    await using rpc = StdioClient.start(env, "rpc");
    const unknown = await rpc.request("no_such_operation", {});
    expect(unknown.error.code).toBe(-32601);
    expect(unknown.error.data.code).toBe("method_not_found");

    const arrayParams = await rpc.request("version", [] as unknown as Record<string, unknown>);
    expect(arrayParams.error.code).toBe(-32602);

    rpc.send({ id: 41, method: "version" });
    const noVersion = await rpc.response(41);
    expect(noVersion.error.code).toBe(-32600);
    expect(rpc.children()).toEqual([]);
  });

  test("the core's failures carry its code in data.code; invalid input is -32602", async () => {
    await using env = await TestEnv.create();
    await using rpc = StdioClient.start(env, "rpc");
    const invalid = await rpc.request("version", { verbose: true });
    expect(invalid.error.code).toBe(-32602);
    expect(invalid.error.data.code).toBe("invalid_input");

    const missing = await rpc.request("app_login", { owner: "acme" });
    expect(missing.error.code).toBe(-32000);
    expect(missing.error.data.code).toBe("missing_app");
    expect(missing.error.message).toBe(missing.error.data.message);

    const secret = await rpc.request("app_add", { owner: "acme", client_id: "Iv1.abc", client_secret: "s3cr3t" });
    expect(secret.error.data.code).toBe("secret_needs_stdin");
    expect(secret.error.message).toContain("gh-touchid app add");
    expect(rpc.stderr).not.toContain("s3cr3t");
    expect(env.items(services.app)).toEqual([]);
  });

  test("notifications/cancelled ends the call's core, gh's token is still revoked, the call answers -32800", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    await using rpc = StdioClient.start(env, "rpc", { env: { FAKE_GH_MODE: "sleep" } });

    const id = rpc.begin("gh", { argv: ["-R", "acme/widgets", "pr", "list"] }, "long-call");
    await env.waitForGhCalls(1);
    const [core] = rpc.children();
    expect(core).toBeNumber();
    // the dialog names the client that started `gh-touchid rpc`, not the adapter
    expect(rpc.auth).toHaveLength(1);
    expect(rpc.auth[0]).toContain(`let ${client} run`);
    expect(rpc.auth[0]).not.toContain("gh-touchid-adapter");

    rpc.notify("notifications/cancelled", { requestId: id });
    const reply = await rpc.response(id);
    expect(reply.error.code).toBe(-32800);
    expect(reply.error.data.code).toBe("cancelled");
    expect(isRunning(core!)).toBe(false);
    expect(env.ghRunsAndSignals()).toEqual(["run", "SIGTERM"]);
    expect(env.mock.scopedTokens()[0]!.revoked).toBe(true);
  });

  test("notifications/cancelled of an `as` call ends the command it runs, not only its core", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("bob", "ghp_bob");
    await using rpc = StdioClient.start(env, "rpc");
    const pidFile = join(env.dir, "command.pid");
    const id = rpc.begin("as", { login: "bob", argv: ["/bin/sh", "-c", `echo $$ > ${pidFile}; exec /bin/sleep 30`] });
    // the command, a real process, writes its pid: poll for the file (no event to await), up to a deadline
    const deadline = Date.now() + 10_000;
    while (!existsSync(pidFile) || readFileSync(pidFile, "utf8").trim() === "") {
      expect(Date.now()).toBeLessThan(deadline);
      await Bun.sleep(20);
    }
    const command = Number(readFileSync(pidFile, "utf8").trim());
    expect(isRunning(command)).toBe(true);

    rpc.notify("notifications/cancelled", { requestId: id });
    const reply = await rpc.response(id);
    expect(reply.error.code).toBe(-32800);
    await waitForExit(command);
  });

  test("closing standard input answers the calls still running, then exits", async () => {
    await using env = await TestEnv.create();
    await using rpc = StdioClient.start(env, "rpc");
    const id = rpc.begin("version", {});
    expect(await rpc.close()).toBe(0);
    expect((await rpc.response(id)).result.version).toBeString();
  });

  test("a session registered through rpc belongs to the client, not the adapter", async () => {
    await using env = await TestEnv.create();
    await using rpc = StdioClient.start(env, "rpc");
    const reply = await rpc.request("session", { repos: ["acme/widgets"] });
    expect(reply.error).toBeUndefined();
    expect(reply.result.state).toBe("pending");

    const status = await env.agentRequest({ op: "status", protocol: 1 });
    const sessions = (status?.sessions ?? []) as Record<string, unknown>[];
    expect(sessions).toHaveLength(1);
    expect(sessions[0]).toMatchObject({ pid: process.pid, program: client, repos: ["acme/widgets"] });
  });

  test("with an agent of 0.4.2 (protocol 1), a session registered through rpc belongs to the adapter", async () => {
    await using env = await TestEnv.create();
    // 0.4.2's `session` starts 0.4.2's agent at agent.sock
    expect((await env.run(["session", "--repo", "acme/gadgets"], { binary: builds.previous })).status).toBe(0);
    await using rpc = StdioClient.start(env, "rpc");
    const reply = await rpc.request("session", { repos: ["acme/widgets"] });
    expect(reply.error).toBeUndefined();
    expect(reply.result.state).toBe("pending");

    const status = await env.agentRequest({ op: "status", protocol: 1 });
    expect(status?.version).toBe("0.4.2");
    const sessions = (status?.sessions ?? []) as Record<string, unknown>[];
    const widgets = sessions.find((session) => JSON.stringify(session.repos) === '["acme/widgets"]');
    expect(widgets).toMatchObject({ program: "gh-touchid-adapter" });
  });
});

describe("gh-touchid rpc|mcp launching the adapter", () => {
  test("takes no arguments", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["rpc", "--verbose"]);
    expect(result.status).toBe(2);
    expect(result.stdout).toBe("");
  });

  test("a missing adapter is refused, saying how to get one", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["mcp"], { env: { GH_TOUCHID_ADAPTER: `${env.dir}/no-such-adapter` } });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("gh-touchid-adapter");
    expect(result.stderr).toContain(`${env.dir}/no-such-adapter`);

    const json = await env.run(["--json", "mcp"], { env: { GH_TOUCHID_ADAPTER: "relative/adapter" } });
    expect(json.status).toBe(1);
    expect(JSON.parse(json.stderr.trim().split("\n").at(-1)!).error.code).toBe("adapter_missing");
  });
});
