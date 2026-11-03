// What gh-touchid tells its caller besides the result (the reader's notice, a token it could not revoke, how to
// approve a session): on stderr without --json; with --json in the result's `notices`, which is what an agent reads,
// through rpc and mcp too, since the adapter passes on the result and not the core's other stderr lines.

import { describe, expect, test } from "bun:test";
import { StdioClient } from "./support/adapter";
import { TestEnv } from "./support/harness";
import { readerNotice, readerNoticeText, seedReader } from "./support/reader";

const sessionHint = "to approve this whole session once, run: gh-touchid session";

describe("notices", () => {
  test("the reader's: on stderr without --json; in `notices` with it, through rpc and mcp, and nowhere else", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env);
    const argv = ["-R", "someone/project", "issue", "list"];

    const text = await env.run(["gh", ...argv]);
    expect(text.status).toBe(0);
    expect(text.stderr).toContain(readerNotice(reader.slug));

    const json = await env.run(["--json", "gh", ...argv]);
    expect(json.status).toBe(0);
    expect(JSON.parse(json.stdout).notices).toEqual([readerNoticeText(reader.slug)]);
    expect(json.stderr).not.toContain(readerNoticeText(reader.slug));

    await using rpc = StdioClient.start(env, "rpc");
    const reply = await rpc.request("gh", { argv });
    expect(reply.result.notices).toEqual([readerNoticeText(reader.slug)]);

    await using mcp = StdioClient.start(env, "mcp");
    await mcp.initialize();
    const call = await mcp.request("tools/call", { name: "gh", arguments: { argv } });
    expect(call.result.isError).toBeFalsy();
    expect(call.result.structuredContent.notices).toEqual([readerNoticeText(reader.slug)]);
    expect(JSON.parse(call.result.content[0].text).notices).toEqual([readerNoticeText(reader.slug)]);
  });

  test("a result with nothing to tell has no `notices`", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", "ghp_alice0000000000000000000000000000");
    const result = await env.run(["--json", "as", "alice", "gh", "api", "user"]);
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout)).not.toHaveProperty("notices");
  });

  test("a token that could not be revoked, and the session hint: told either way, in order", async () => {
    await using env = await TestEnv.create();
    const { app } = env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    env.mock.override((request, url) =>
      request.method === "DELETE" && url.pathname === `/applications/${app.clientId}/token`
        ? new Response(JSON.stringify({ message: "Server Error" }), { status: 500 })
        : undefined,
    );
    const argv = ["gh", "-R", "acme/widgets", "issue", "list"];

    const text = await env.run(argv);
    expect(text.status).toBe(0);
    expect(text.stderr).toContain(`gh-touchid: ${sessionHint}`);
    expect(text.stderr).toContain("gh-touchid: could not revoke the token for acme/widgets; it expires at");

    const json = await env.run(["--json", ...argv]);
    expect(json.status).toBe(0);
    const notices: string[] = JSON.parse(json.stdout).notices;
    expect(notices).toHaveLength(2);
    expect(notices[0]).toBe(sessionHint);
    expect(notices[1]).toStartWith("could not revoke the token for acme/widgets; it expires at");
    expect(json.stderr).not.toContain("could not revoke");
  });

  test("notices kept for a result that fails go to stderr, before the error line", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    const result = await env.run(["--json", "gh", "-R", "acme/widgets", "issue", "list"], {
      env: { GH_TOUCHID_TEST_DENY: "1" },
    });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    const lines = result.stderr.trimEnd().split("\n");
    expect(JSON.parse(lines.at(-1)!).error.code).toBe("authentication_failed");
    expect(lines).toContain(`gh-touchid: ${sessionHint}`);
    expect(lines.indexOf(`gh-touchid: ${sessionHint}`)).toBeLessThan(lines.length - 1);
  });
});
