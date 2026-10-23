// The tokens gh and Git get from your sign-in to an owner's App: narrowed to one repository, without `workflows`
// unless elevated, issue-only outside a session's repositories, revoked after gh, and the sign-in renewed when it is
// about to end. Every token here is made by the mock; the assertions read what it recorded.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, services, type SignIn, TestEnv } from "./support/harness";
import type { App, Permissions, Token } from "./support/mock-github";

const issueOnly = { issues: "write", metadata: "read", contents: "read" };

function withoutWorkflows(permissions: Permissions): Permissions {
  const { workflows: _, ...rest } = permissions;
  return rest;
}

function basic(app: App): string {
  return `Basic ${Buffer.from(`${app.clientId}:${app.clientSecret}`).toString("base64")}`;
}

/** acme's App installed on all of acme's repositories (widgets, gadgets, other), alice signed in. */
function seedAcme(env: TestEnv, options: { public?: string[]; expiresIn?: number; refreshExpiresIn?: number } = {}) {
  return env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets", "gadgets", "other"], ...options });
}

function signInItem(env: TestEnv): SignIn {
  return JSON.parse(env.item(services.signIn, "acme")!);
}

/** The one scoped token the mock made, checked to have been revoked by gh-touchid with the App's credentials. */
function expectRevoked(env: TestEnv, token: Token, app: App): void {
  expect(token.revoked).toBe(true);
  expect(token.revokedBy).toBe("deleted");
  const deletes = env.mock.requestsTo("DELETE", `/applications/${app.clientId}/token`);
  const revoking = deletes.filter((request) => request.fields?.access_token === token.token);
  expect(revoking).toHaveLength(1);
  expect(revoking[0]!.headers.authorization).toBe(basic(app));
}

describe("one use outside a session", () => {
  test("asks once, gives gh a token narrowed from the sign-in to the repository, then revokes it", async () => {
    await using env = await TestEnv.create();
    const { app, installation, token } = seedAcme(env);
    const repository = env.makeRepository("acme/widgets");
    const result = await env.run(["gh", "issue", "list"], { cwd: repository });
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("acme/widgets");

    const scoped = env.mock.scopedTokens();
    expect(scoped).toHaveLength(1);
    expect(scoped[0]).toMatchObject({
      login: "alice",
      parent: token.token,
      target: "acme",
      repositories: ["acme/widgets"],
      permissions: withoutWorkflows(installation.permissions),
    });
    expect(env.ghCalls().map((call) => call.ghToken)).toEqual([scoped[0]!.token]);
    expectRevoked(env, scoped[0]!, app);
    expect(token.revoked).toBe(false);
    const installations = env.mock.requestsTo("GET", "/user/installations");
    expect(installations.map((request) => request.headers.authorization)).toEqual([`Bearer ${token.token}`]);
    expect(env.accessLog().some((line) => line.includes("granted acme/widgets (once) as alice"))).toBe(true);
  });

  test("revokes the token when gh fails, and passes on gh's status", async () => {
    await using env = await TestEnv.create();
    const { app } = seedAcme(env);
    const result = await env.run(["gh", "-R", "acme/widgets", "pr", "list"], { env: { FAKE_GH_EXIT: "1" } });
    expect(result.status).toBe(1);
    expect(env.ghCalls()).toHaveLength(1);
    expectRevoked(env, env.mock.scopedTokens()[0]!, app);
  });

  for (const [signal, number] of [["SIGTERM", 15], ["SIGINT", 2], ["SIGHUP", 1]] as const) {
    test(`${signal} to gh-touchid while gh runs is passed on to gh, and the token is still revoked`, async () => {
      await using env = await TestEnv.create();
      const { app } = seedAcme(env);
      const running = env.start(["gh", "-R", "acme/widgets", "pr", "list"], { env: { FAKE_GH_MODE: "sleep" } });
      await env.waitForGhCalls(1);
      running.kill(signal);
      const result = await running.finished;
      expect(result.status).toBe(128 + number);
      expect(env.ghEvents().map((event) => event.signal ?? event.kind)).toEqual(["run", signal]);
      expectRevoked(env, env.mock.scopedTokens()[0]!, app);
    });
  }

  test("an App stored without a sign-in is refused before Touch ID, naming app login", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"], signedIn: false });
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toContain("gh-touchid app login acme");
    expect(env.mock.requests).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
    expect(env.accessLog().some((line) => line.includes("refused acme/widgets"))).toBe(true);
  });
});

describe("refusals from GitHub", () => {
  test("no installation on the owner: the error gives the install page, nothing is minted", async () => {
    await using env = await TestEnv.create();
    const { app } = seedAcme(env);
    env.mock.installations.length = 0;
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain(`${env.mock.url}/apps/${app.slug}/installations/new`);
    expect(env.mock.scopedTokens()).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
    expect(env.accessLog().some((line) => line.includes("refused acme/widgets"))).toBe(true);
  });

  test("the owner's installation on a later page of /user/installations is found", async () => {
    await using env = await TestEnv.create();
    const { app, installation } = seedAcme(env);
    // 150 other accounts that alice can see come first, so acme's installation is on page 2 of 100
    for (let index = 0; index < 150; index++) {
      env.mock.seedOrganization(`other-${index}`, ["alice"]);
      env.mock.seedInstallation(app, `other-${index}`);
    }
    env.mock.installations.splice(env.mock.installations.indexOf(installation), 1);
    env.mock.installations.push(installation);
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(result.status).toBe(0);
    expect(env.mock.requestsTo("GET", "/user/installations").map((request) => request.query.page)).toEqual(["1", "2"]);
    expect(env.mock.scopedTokens().map((token) => token.repositories)).toEqual([["acme/widgets"]]);
  });

  test("a repository outside the installation (HTTP 422) is refused, nothing is minted", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets", "secret"], installedOn: ["widgets"] });
    const result = await env.run(["gh", "-R", "acme/secret", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("422");
    expect(env.mock.requestsTo("POST", /\/token\/scoped$/).map((request) => request.status)).toEqual([422]);
    expect(env.mock.scopedTokens()).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
  });

  const signInAgain: [string, (env: TestEnv, seeded: ReturnType<typeof seedAcme>) => void][] = [
    [
      "scoping answers 404",
      (env) =>
        env.mock.override((request, url) =>
          request.method === "POST" && url.pathname.endsWith("/token/scoped") ? new Response("{}", { status: 404 }) : undefined,
        ),
    ],
    [
      "the stored client secret is wrong (HTTP 401)",
      (env, { app }) => env.seedApp("acme", { clientId: app.clientId, clientSecret: "wrong", slug: app.slug }),
    ],
    [
      "GitHub no longer accepts the sign-in",
      (_env, { token }) => {
        token.revoked = true;
      },
    ],
  ];
  for (const [name, breakIt] of signInAgain) {
    test(`${name}: the error says to run app login, nothing is minted`, async () => {
      await using env = await TestEnv.create();
      breakIt(env, seedAcme(env));
      const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("gh-touchid app login acme");
      expect(env.mock.scopedTokens()).toEqual([]);
      expect(env.ghCalls()).toEqual([]);
    });
  }
});

describe("elevation", () => {
  test("an elevated repository's token includes workflows, others' do not, and lock ends it", async () => {
    await using env = await TestEnv.create();
    const { installation } = seedAcme(env);
    expect((await env.run(["elevate", "--for", "30m", "--repo", "acme/widgets"])).status).toBe(0);

    expect((await env.run(["gh", "-R", "acme/widgets", "issue", "list"])).status).toBe(0);
    expect((await env.run(["gh", "-R", "acme/gadgets", "issue", "list"])).status).toBe(0);
    await env.run(["lock"]);
    expect((await env.run(["gh", "-R", "acme/widgets", "issue", "list"])).status).toBe(0);

    const permissions = env.mock.scopedTokens().map((token) => token.permissions);
    expect(permissions).toEqual([
      installation.permissions,
      withoutWorkflows(installation.permissions),
      withoutWorkflows(installation.permissions),
    ]);
    expect(env.accessLog().filter((line) => line.includes("granted acme/widgets (once), elevated as alice"))).toHaveLength(1);
  });
});

describe("inside a session", () => {
  async function approvedSession(env: TestEnv): Promise<void> {
    expect((await env.run(["session", "--repo", "acme/widgets"])).status).toBe(0);
    const first = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(first.status).toBe(0);
    expect(first.auth).toHaveLength(1);
  }

  test("a repository the session lists: no Touch ID once approved, each token revoked after use", async () => {
    await using env = await TestEnv.create();
    const { app, installation } = seedAcme(env);
    await approvedSession(env);
    const second = await env.run(["gh", "-R", "acme/widgets", "pr", "list"]);
    expect(second.status).toBe(0);
    expect(second.auth).toEqual([]);
    const scoped = env.mock.scopedTokens();
    expect(scoped.map((token) => token.permissions)).toEqual([
      withoutWorkflows(installation.permissions),
      withoutWorkflows(installation.permissions),
    ]);
    for (const token of scoped) {
      expectRevoked(env, token, app);
    }
  });

  test("a private repository it does not list gets an issue-only token without asking", async () => {
    await using env = await TestEnv.create();
    const { app } = seedAcme(env);
    await approvedSession(env);
    const result = await env.run(["gh", "-R", "acme/gadgets", "issue", "create", "-t", "x", "-b", "y"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    const token = env.mock.scopedTokens()[1]!;
    expect(token).toMatchObject({ repositories: ["acme/gadgets"], permissions: issueOnly });
    expect(env.ghCalls()[1]!.ghToken).toBe(token.token);
    expectRevoked(env, token, app);
    expect(env.accessLog().some((line) => /granted acme\/gadgets \(issues, session bun\[\d+\]\) as alice/.test(line))).toBe(true);
  });

  test("a public repository it does not list asks once for the issue-only token", async () => {
    await using env = await TestEnv.create();
    seedAcme(env, { public: ["gadgets"] });
    await approvedSession(env);
    const result = await env.run(["gh", "-R", "acme/gadgets", "issue", "comment", "1", "-b", "hi"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.auth[0]).toContain("acme/gadgets");
    expect(env.mock.scopedTokens()[1]).toMatchObject({ repositories: ["acme/gadgets"], permissions: issueOnly });
    expect(env.accessLog().some((line) => line.includes("granted acme/gadgets (issues, public, approved once"))).toBe(true);
  });

  test("declining that public use revokes the token, and gh never runs", async () => {
    await using env = await TestEnv.create();
    const { app } = seedAcme(env, { public: ["gadgets"] });
    await approvedSession(env);
    const result = await env.run(["gh", "-R", "acme/gadgets", "issue", "list"], { env: { GH_TOUCHID_TEST_DENY: "1" } });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect(env.ghCalls()).toHaveLength(1);
    const token = env.mock.scopedTokens()[1]!;
    expect(token.repositories).toEqual(["acme/gadgets"]);
    expectRevoked(env, token, app);
  });
});

describe("gh api names its repository", () => {
  const endpoints = (url: string) => [
    ["api", "repos/acme/widgets/pulls"],
    ["api", "/repos/acme/widgets/pulls?state=all"],
    ["api", `${url}/repos/acme/widgets`],
    ["api", "-X", "GET", "-H", "Accept: application/json", "--paginate", "repos/acme/widgets/pulls"],
    // grouped short flags: the first that takes a value takes the next argument, or the rest of the group
    ["api", "-iH", "Accept: application/json", "repos/acme/widgets/issues"],
    ["api", "-iXGET", "repos/acme/widgets/issues"],
  ];

  test("repos/OWNER/REPO in the endpoint wins over the current repository", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    const folder = env.makeRepository("acme/other");
    for (const args of endpoints(env.mock.url)) {
      const result = await env.run(["gh", ...args], { cwd: folder });
      expect(result.status).toBe(0);
      expect(result.auth[0]).toContain("acme/widgets");
    }
    expect(env.mock.scopedTokens().map((token) => token.repositories)).toEqual(
      endpoints(env.mock.url).map(() => ["acme/widgets"]),
    );
  });

  test("placeholders and graphql take GH_REPO, else the current repository", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    const folder = env.makeRepository("acme/other");
    const uses: [string[], Record<string, string>, string][] = [
      [["api", "repos/{owner}/{repo}/pulls"], {}, "acme/other"],
      [["api", "repos/{owner}/{repo}/pulls"], { GH_REPO: "acme/widgets" }, "acme/widgets"],
      [["api", "graphql", "-f", "query=query{viewer{login}}"], {}, "acme/other"],
      [["api", "user"], { GH_REPO: "acme/gadgets" }, "acme/gadgets"],
    ];
    for (const [args, extra] of uses) {
      expect((await env.run(["gh", ...args], { cwd: folder, env: extra })).status).toBe(0);
    }
    expect(env.mock.scopedTokens().map((token) => token.repositories![0])).toEqual(uses.map((use) => use[2]));
  });
});

describe("renewing the sign-in", () => {
  test("with less than an hour left, it is renewed once and the token is narrowed from the new one", async () => {
    await using env = await TestEnv.create();
    const { app, token } = seedAcme(env, { expiresIn: 30 * 60 });
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(result.status).toBe(0);

    const refreshes = env.mock.requestsTo("POST", "/login/oauth/access_token");
    expect(refreshes).toHaveLength(1);
    expect(refreshes[0]!.fields).toMatchObject({
      client_id: app.clientId,
      client_secret: app.clientSecret,
      grant_type: "refresh_token",
      refresh_token: token.refreshToken,
    });
    const renewed = env.mock.userTokens()[1]!;
    expect(signInItem(env)).toMatchObject({
      login: "alice",
      accessToken: renewed.token,
      refreshToken: renewed.refreshToken,
    });
    expect(Math.abs(signInItem(env).accessExpires - renewed.expiresAt!)).toBeLessThanOrEqual(5);
    expect(env.comment(services.signIn, "acme")).toBe("alice");
    expect(env.mock.scopedTokens()[0]!.parent).toBe(renewed.token);
    expect(env.accessLog().some((line) => line.includes("renewed the sign-in of alice to the acme App"))).toBe(true);
  });

  test("with more than an hour left, it is used as it is", async () => {
    await using env = await TestEnv.create();
    const { token } = seedAcme(env, { expiresIn: 2 * 60 * 60 });
    expect((await env.run(["gh", "-R", "acme/widgets", "issue", "list"])).status).toBe(0);
    expect(env.mock.requestsTo("POST", "/login/oauth/access_token")).toEqual([]);
    expect(env.mock.scopedTokens()[0]!.parent).toBe(token.token);
  });

  test("concurrent uses renew it exactly once, and all of them get a token", async () => {
    await using env = await TestEnv.create();
    seedAcme(env, { expiresIn: 10 * 60 });
    const results = await Promise.all(
      Array.from({ length: 6 }, () => env.run(["gh", "-R", "acme/widgets", "issue", "list"])),
    );
    expect(results.map((result) => result.status)).toEqual(results.map(() => 0));
    expect(env.mock.requestsTo("POST", "/login/oauth/access_token")).toHaveLength(1);
    const renewed = env.mock.userTokens()[1]!.token;
    expect(env.mock.scopedTokens().map((token) => token.parent)).toEqual(results.map(() => renewed));
  });

  const ended: [string, { expiresIn: number; refreshExpiresIn?: number }, (token: Token) => void, number][] = [
    ["an expired refresh token", { expiresIn: 60, refreshExpiresIn: 30 }, () => {}, 0],
    ["a refresh token GitHub refuses (bad_refresh_token)", { expiresIn: 60 }, (token) => {
      token.refreshUsed = true;
    }, 1],
  ];
  for (const [name, lifetimes, breakIt, refreshes] of ended) {
    test(`${name}: not signed in, nothing minted, the sign-in left as it was`, async () => {
      await using env = await TestEnv.create();
      const { token } = seedAcme(env, lifetimes);
      breakIt(token);
      const before = env.item(services.signIn, "acme");
      const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("gh-touchid app login acme");
      expect(env.mock.requestsTo("POST", "/login/oauth/access_token")).toHaveLength(refreshes);
      expect(env.mock.scopedTokens()).toEqual([]);
      expect(env.ghCalls()).toEqual([]);
      expect(env.item(services.signIn, "acme")).toBe(before);
    });
  }
});

describe("Git", () => {
  /** Git's configuration: only the test build as credential helper, its answers to `get` copied to helper.log. */
  async function configureGit(env: TestEnv): Promise<{ git: string; log: string }> {
    const git = join(env.dir, "bin", "git");
    const log = join(env.dir, "helper.log");
    const helper = `!f() { '${binary}' git credential "$@" | tee -a '${log}'; }; f`;
    for (const args of [
      ["config", "--global", "credential.helper", ""],
      ["config", "--global", "--add", "credential.helper", helper],
      ["config", "--global", "credential.useHttpPath", "true"],
    ]) {
      expect((await env.exec([git, ...args])).status).toBe(0);
    }
    return { git, log };
  }

  test("Git's transport gets the login and a narrowed token with its expiry, which is not revoked", async () => {
    await using env = await TestEnv.create();
    const { git, log } = await configureGit(env);
    seedAcme(env);
    const result = await env.exec([git, "ls-remote", `${env.mock.url}/acme/widgets.git`]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);

    const scoped = env.mock.scopedTokens();
    expect(scoped).toHaveLength(1);
    expect(scoped[0]!.repositories).toEqual(["acme/widgets"]);
    expect(env.mock.gitLogins.map((login) => [login.status, login.username, login.password])).toEqual([
      [401, undefined, undefined],
      [200, "alice", scoped[0]!.token],
    ]);
    const answer = readFileSync(log, "utf8");
    expect(answer).toContain("username=alice\n");
    expect(answer).toContain(`password=${scoped[0]!.token}\n`);
    expect(Number(answer.match(/^password_expiry_utc=(\d+)$/m)![1])).toBe(scoped[0]!.expiresAt);
    expect(scoped[0]!.revoked).toBe(false);
    expect(env.mock.revocations).toEqual([]);
  });

  test("inside a session, Git gets an issue-only token for a private repository it does not list", async () => {
    await using env = await TestEnv.create();
    const { git } = await configureGit(env);
    seedAcme(env);
    await env.run(["session", "--repo", "acme/widgets"]);
    expect((await env.run(["gh", "-R", "acme/widgets", "issue", "list"])).auth).toHaveLength(1);
    const result = await env.exec([git, "ls-remote", `${env.mock.url}/acme/gadgets.git`]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(env.mock.scopedTokens()[1]).toMatchObject({ repositories: ["acme/gadgets"], permissions: issueOnly });
  });

  test("inside a session, Git gets nothing for a public repository it does not list", async () => {
    await using env = await TestEnv.create();
    const { git } = await configureGit(env);
    const { app } = seedAcme(env, { public: ["gadgets"] });
    await env.run(["session", "--repo", "acme/widgets"]);
    expect((await env.run(["gh", "-R", "acme/widgets", "issue", "list"])).auth).toHaveLength(1);
    const result = await env.exec([git, "ls-remote", `${env.mock.url}/acme/gadgets.git`]);
    expect(result.status).not.toBe(0);
    expect(result.auth).toEqual([]);
    expect(env.mock.gitLogins.filter((login) => login.password !== undefined)).toEqual([]);
    const token = env.mock.scopedTokens()[1]!;
    expect(token.repositories).toEqual(["acme/gadgets"]);
    expectRevoked(env, token, app);
    expect(env.accessLog().some((line) => line.includes("refused acme/gadgets"))).toBe(true);
  });
});
