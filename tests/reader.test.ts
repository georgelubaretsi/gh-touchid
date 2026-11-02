// The reader: a GitHub App of yours with no permissions whose installation tokens let gh read public data without
// Touch ID, for owners without an App and outside any repository. `reader create`, `reader add`, `reader remove`, the
// routing in `gh`, the checks every token passes before gh gets it, the refusal of commands that open issues, and
// the revoke after gh. GitHub is the mock; it verifies every App JWT against the App's keys.

import { describe, expect, test } from "bun:test";
import { browse } from "./support/browser";
import { type RunResult, TestEnv } from "./support/harness";
import {
  keyFingerprint,
  type MockReader,
  pkcs8,
  readerAccount,
  readerComment,
  readerItem,
  readerNotice,
  readerService,
  seedReader,
} from "./support/reader";

/** The `{"error": {...}}` line `--json` ends stderr with. */
function lastError(result: RunResult): { code: string; message: string } | undefined {
  const line = result.stderr.trimEnd().split("\n").at(-1) ?? "";
  try {
    return JSON.parse(line).error;
  } catch {
    return undefined;
  }
}

/** Runs `args`, follows the browser through its OPEN URL, and returns both outcomes. */
async function withBrowser(env: TestEnv, args: string[], options: { env?: Record<string, string> } = {}) {
  const running = env.start(args, options);
  const [, url] = await running.waitForStderr(/^OPEN: (\S+)$/m);
  const browser = await browse(url!);
  return { browser, result: await running.finished };
}

/** octo, a user signed in to the mock's web pages, as the account a reader is made for. */
function seedBrowserUser(env: TestEnv): void {
  env.mock.seedUser("octo");
  env.mock.browserLogin = "octo";
}

/** What the mock was asked of the reader: installation lookups and token mints. */
function readerRequests(env: TestEnv) {
  return {
    installations: env.mock.requestsTo("GET", "/app/installations"),
    mints: env.mock.requestsTo("POST", /^\/app\/installations\/\d+\/access_tokens$/),
  };
}

/** Every installation token the mock made was revoked by gh-touchid with the token itself. */
function expectAllRevoked(env: TestEnv): void {
  const tokens = env.mock.installationTokens();
  expect(tokens.length).toBeGreaterThan(0);
  for (const token of tokens) {
    expect(token.revoked).toBe(true);
    expect(token.revokedBy).toBe("deleted");
    const deletes = env.mock
      .requestsTo("DELETE", "/installation/token")
      .filter((request) => request.headers.authorization === `Bearer ${token.token}`);
    expect(deletes).toHaveLength(1);
  }
}

describe("reader create", () => {
  test("makes an App with no permissions, stores its ID and key after one Touch ID, waits for the install, checks it", async () => {
    await using env = await TestEnv.create();
    seedBrowserUser(env);
    const { browser, result } = await withBrowser(env, ["reader", "create"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);

    const app = env.mock.apps[0]!;
    expect(browser.visits.map((visit) => `${visit.method} ${new URL(visit.url).pathname}`)).toEqual([
      "GET /",
      "POST /settings/apps/new",
      "GET /created",
      `GET /apps/${app.slug}/installations/new`,
      "GET /installed",
    ]);
    expect(browser.status).toBe(200);
    expect(browser.body).toContain("installed");

    const manifest = JSON.parse(String(env.mock.requestsTo("POST", "/settings/apps/new")[0]!.fields?.manifest));
    expect(manifest).toMatchObject({
      url: "https://github.com/georgelubaretsi/gh-touchid",
      public: false,
      request_oauth_on_install: false,
      default_permissions: {},
      default_events: [],
    });
    expect(manifest.name).toMatch(/^gh-touchid-reader-[0-9a-f]{6}$/);
    expect(manifest.redirect_url).toStartWith("http://127.0.0.1:");
    expect(manifest.setup_url).toStartWith("http://127.0.0.1:");
    expect(manifest.callback_urls).toBeUndefined();

    // the ID and key only: the client secret and webhook secret are dropped
    expect(readerItem(env)).toEqual({ appId: app.id, privateKey: app.pem });
    expect(readerComment(env)).toEqual({ app: app.slug, owner: "octo" });
    expect(env.description(readerService, readerAccount)).toBe("gh-touchid format 1");
    expect(env.items("com.lubaretsi.gh-touchid.app")).toEqual([]);

    // one token minted, checked and revoked
    expect(readerRequests(env).mints).toHaveLength(1);
    expect(env.mock.requestsTo("GET", "/installation/repositories")).toHaveLength(1);
    expectAllRevoked(env);
    expect(env.mock.jwts.every((jwt) => jwt.accepted && jwt.header.alg === "RS256")).toBe(true);
    for (const { payload } of env.mock.jwts) {
      expect(String(payload.iss)).toBe(String(app.id));
      expect(Number(payload.exp) - Number(payload.iat)).toBe(600);
    }
    expect(result.stdout).toContain(app.slug);
    expect(env.ghCalls()).toEqual([]);
    expect(env.accessLog().some((line) => line.includes(`stored the reader ${app.slug}`))).toBe(true);
  });

  test("--json prints the App, its owner and its install page", async () => {
    await using env = await TestEnv.create();
    seedBrowserUser(env);
    const { result } = await withBrowser(env, ["--json", "reader", "create", "--name", "Octo Reader"]);
    expect(result.status).toBe(0);
    const app = env.mock.apps[0]!;
    expect(app.name).toBe("Octo Reader");
    expect(JSON.parse(result.stdout)).toEqual({
      app: app.slug,
      app_id: app.id,
      owner: "octo",
      installed: true,
      install_url: `${env.mock.url}/apps/${app.slug}/installations/new`,
    });
  });

  test("an App GitHub made for an organization is refused, storing nothing and naming where to delete it", async () => {
    await using env = await TestEnv.create();
    seedBrowserUser(env);
    env.mock.seedOrganization("acme", ["octo"]);
    env.mock.manifestOwner = "acme";
    const { browser, result } = await withBrowser(env, ["reader", "create"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    const app = env.mock.apps[0]!;
    expect(result.stderr).toContain(`/organizations/acme/settings/apps/${app.slug}/advanced`);
    expect(browser.body).toContain("nothing was stored");
    expect(readerItem(env)).toBeUndefined();
    expect(readerRequests(env).mints).toEqual([]);
  });

  test("an App GitHub gave permissions is refused, storing nothing and naming where to delete it", async () => {
    await using env = await TestEnv.create();
    seedBrowserUser(env);
    env.mock.manifestPermissions = { issues: "write" };
    const { result } = await withBrowser(env, ["reader", "create"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    const app = env.mock.apps[0]!;
    expect(result.stderr).toContain("issues");
    expect(result.stderr).toContain(`/settings/apps/${app.slug}/advanced`);
    expect(readerItem(env)).toBeUndefined();
    expect(readerRequests(env).mints).toEqual([]);
  });

  test("Touch ID denied stores nothing", async () => {
    await using env = await TestEnv.create();
    seedBrowserUser(env);
    const { browser, result } = await withBrowser(env, ["reader", "create"], { env: { GH_TOUCHID_TEST_DENY: "1" } });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect(browser.body).toContain("nothing was stored");
    expect(readerItem(env)).toBeUndefined();
    expect(readerRequests(env).installations).toEqual([]);
    expect(readerRequests(env).mints).toEqual([]);
  });

  test("an installation that does not come in time: the reader stays stored, reader_not_installed names the page", async () => {
    await using env = await TestEnv.create();
    seedBrowserUser(env);
    // the install page does not install
    env.mock.override((_request, url) =>
      url.pathname.endsWith("/installations/new") ? new Response("not installed", { status: 200 }) : undefined,
    );
    const { result } = await withBrowser(env, ["--json", "reader", "create"], {
      env: { GH_TOUCHID_TEST_INSTALL_TIMEOUT: "1" },
    });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    const app = env.mock.apps[0]!;
    expect(lastError(result)?.code).toBe("reader_not_installed");
    expect(lastError(result)?.message).toContain(`/apps/${app.slug}/installations/new`);
    expect(readerItem(env)).toEqual({ appId: app.id, privateKey: app.pem });
    expect(readerRequests(env).installations.length).toBeGreaterThan(0);
    expect(readerRequests(env).mints).toEqual([]);
  });

  test("is refused while a reader is stored, before any browser or request", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env);
    const before = env.mock.requests.length;
    const result = await env.run(["--json", "reader", "create"]);
    expect(result.status).toBe(1);
    expect(result.open).toEqual([]);
    expect(result.auth).toEqual([]);
    expect(lastError(result)?.code).toBe("reader_exists");
    expect(lastError(result)?.message).toContain(reader.slug);
    expect(lastError(result)?.message).toContain("reader add");
    expect(lastError(result)?.message).toContain("reader remove");
    expect(env.mock.requests.length).toBe(before);
  });
});

describe("reader add", () => {
  /** A reader App made by hand on GitHub and installed, but not stored. */
  function seedHandMadeReader(env: TestEnv) {
    const app = env.mock.seedReaderApp("octo");
    const installation = env.mock.seedInstallation(app, "octo");
    return { app, installation };
  }

  test("stores the App after GitHub confirms it and one Touch ID, and prints the key's fingerprint", async () => {
    await using env = await TestEnv.create();
    const { app } = seedHandMadeReader(env);
    const result = await env.run(["reader", "add", "--app-id", String(app.id)], { stdin: app.pem });
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(readerItem(env)).toEqual({ appId: app.id, privateKey: app.pem });
    expect(readerComment(env)).toEqual({ app: app.slug, owner: "octo" });
    expect(result.stdout).toContain(keyFingerprint(app.pem));
    expect(result.stdout).not.toContain("PRIVATE KEY");
    expect(result.stderr).not.toContain("PRIVATE KEY");
    expect(env.mock.requestsTo("GET", "/app")).toHaveLength(1);
    expect(readerRequests(env).mints).toHaveLength(1);
    expectAllRevoked(env);
  });

  test("--json: the App, its owner and the fingerprint as GitHub shows it", async () => {
    await using env = await TestEnv.create();
    const { app } = seedHandMadeReader(env);
    const result = await env.run(["--json", "reader", "add", "--app-id", String(app.id)], { stdin: app.pem });
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      app: app.slug,
      app_id: app.id,
      owner: "octo",
      fingerprint: keyFingerprint(app.pem),
    });
  });

  test("replacing a key prints both fingerprints and where to delete the old one", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env, { owner: "octo" });
    const oldKey = reader.app.pem;
    const newKey = env.mock.addKey(reader.app);
    const text = await env.run(["reader", "add", "--app-id", String(reader.appId)], { stdin: newKey });
    expect(text.status).toBe(0);
    expect(text.auth).toHaveLength(1);
    expect(text.stdout).toContain(keyFingerprint(newKey));
    expect(text.stdout).toContain(keyFingerprint(oldKey));
    expect(text.stdout).toContain(`${env.mock.url}/settings/apps/${reader.slug}`);
    expect(readerItem(env)).toEqual({ appId: reader.appId, privateKey: newKey });

    const json = await env.run(["--json", "reader", "add", "--app-id", String(reader.appId)], { stdin: oldKey });
    expect(json.status).toBe(0);
    expect(JSON.parse(json.stdout).replaced).toEqual({
      fingerprint: keyFingerprint(newKey),
      delete_keys_url: `${env.mock.url}/settings/apps/${reader.slug}`,
    });
  });

  test("a key that is not the App's (wrong ID) is refused before Touch ID, storing nothing", async () => {
    await using env = await TestEnv.create();
    const { app } = seedHandMadeReader(env);
    const other = env.mock.seedReaderApp("octo");
    for (const id of [other.id, 999999]) {
      const result = await env.run(["--json", "reader", "add", "--app-id", String(id)], { stdin: app.pem });
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(lastError(result)?.code).toBe("reader_key_rejected");
      expect(lastError(result)?.message).toContain(String(id));
    }
    expect(readerItem(env)).toBeUndefined();
    expect(readerRequests(env).mints).toEqual([]);
  });

  test("a key that is not PKCS#1 is invalid input, refused before any request", async () => {
    await using env = await TestEnv.create();
    const { app } = seedHandMadeReader(env);
    for (const key of [pkcs8(app.pem), "not a key\n", ""]) {
      const result = await env.run(["--json", "reader", "add", "--app-id", String(app.id)], { stdin: key });
      expect(result.status).toBe(2);
      expect(result.auth).toEqual([]);
      expect(lastError(result)?.code).toBe("invalid_private_key");
    }
    expect(env.mock.requests).toEqual([]);
    expect(readerItem(env)).toBeUndefined();
  });

  test("a key typed at a terminal is refused, saying to pipe it", async () => {
    await using env = await TestEnv.create();
    const { app } = seedHandMadeReader(env);
    const result = await env.run(["reader", "add", "--app-id", String(app.id)], { tty: true });
    expect(result.status).toBe(2);
    expect(result.stdout).toContain(`pipe the key: gh-touchid reader add --app-id ${app.id} < key.pem`);
    expect(result.auth).toEqual([]);
    expect(env.mock.requests).toEqual([]);
  });

  test("an App with permissions, or of an organization, is refused before Touch ID", async () => {
    await using env = await TestEnv.create();
    const withPermissions = env.mock.seedApp("octo", { permissions: { contents: "read" }, ownKey: true });
    env.mock.seedInstallation(withPermissions, "octo");
    const permitted = await env.run(["--json", "reader", "add", "--app-id", String(withPermissions.id)], {
      stdin: withPermissions.pem,
    });
    expect(permitted.status).toBe(1);
    expect(lastError(permitted)?.code).toBe("reader_permissions");
    expect(lastError(permitted)?.message).toContain("contents");

    env.mock.seedOrganization("acme");
    const organization = env.mock.seedReaderApp("acme");
    const owned = await env.run(["reader", "add", "--app-id", String(organization.id)], { stdin: organization.pem });
    expect(owned.status).toBe(1);
    expect(owned.stderr).toContain("user account");

    for (const result of [permitted, owned]) {
      expect(result.auth).toEqual([]);
    }
    expect(readerItem(env)).toBeUndefined();
    expect(readerRequests(env).mints).toEqual([]);
  });

  test("an App not installed yet is refused with its install page, before Touch ID", async () => {
    await using env = await TestEnv.create();
    const app = env.mock.seedReaderApp("octo");
    const result = await env.run(["--json", "reader", "add", "--app-id", String(app.id)], { stdin: app.pem });
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(lastError(result)?.code).toBe("reader_not_installed");
    expect(lastError(result)?.message).toContain(`/apps/${app.slug}/installations/new`);
    expect(readerItem(env)).toBeUndefined();
  });
});

describe("reader remove", () => {
  test("--yes deletes the reader and prints where to delete the App", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env);
    const result = await env.run(["--json", "reader", "remove", "--yes"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(JSON.parse(result.stdout)).toEqual({
      removed: true,
      delete_url: `${env.mock.url}/settings/apps/${reader.slug}/advanced`,
    });
    expect(readerItem(env)).toBeUndefined();
    expect(env.mock.requests).toEqual([]);
    expect(env.accessLog().some((line) => line.includes(`removed the reader ${reader.slug}`))).toBe(true);
  });

  test("without --yes and without a terminal, nothing is removed and the command to confirm is named", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    const result = await env.run(["--json", "reader", "remove"]);
    expect(result.status).toBe(2);
    expect(lastError(result)?.code).toBe("confirmation_needed");
    expect(lastError(result)?.message).toContain("gh-touchid reader remove --yes");
    expect(readerItem(env)).toBeDefined();
  });

  // The harness cannot type into script(1)'s terminal; only the unanswered question is tested (see app.test.ts).
  test("on a terminal, a question left unanswered removes nothing", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    const unanswered = await env.run(["reader", "remove"], { tty: true });
    expect(unanswered.status).not.toBe(0);
    expect(unanswered.stdout).toContain("[y/N]");
    expect(readerItem(env)).toBeDefined();
  });

  test("with no reader stored there is nothing to remove", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["--json", "reader", "remove", "--yes"]);
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({ removed: false });
  });
});

describe("routing gh to the reader", () => {
  test("an owner without an App: gh runs with a checked reader token, no Touch ID, the notice, then the revoke", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env);
    const result = await env.run(["gh", "-R", "someone/project", "issue", "list"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toContain(readerNotice(reader.slug));

    const tokens = env.mock.installationTokens();
    expect(tokens).toHaveLength(1);
    expect(tokens[0]).toMatchObject({ installationId: reader.installation!.id, permissions: {}, repositories: [] });
    const calls = env.ghCalls();
    expect(calls.map((call) => call.ghToken)).toEqual([tokens[0]!.token]);
    expect(calls[0]!.argv).toEqual(["-R", "someone/project", "issue", "list"]);
    expectAllRevoked(env);

    // checked before gh: the installation listed, no repository reachable
    const order = env.mock.requests.map((request) => `${request.method} ${request.path}`);
    expect(order).toEqual([
      "GET /app/installations",
      `POST /app/installations/${reader.installation!.id}/access_tokens`,
      "GET /installation/repositories",
      "DELETE /installation/token",
    ]);
    expect(JSON.parse(env.mock.requests[1]!.body)).toEqual({});
    expect(env.accessLog().some((line) => line.includes(`granted someone/project (reader ${reader.slug})`))).toBe(true);
  });

  test("no repository named or found: the reader too", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env);
    const result = await env.run(["gh", "search", "repos", "touchid"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toContain(readerNotice(reader.slug));
    expect(env.ghCalls()).toHaveLength(1);
    expectAllRevoked(env);
    expect(env.accessLog().some((line) => line.includes(`granted no repository (reader ${reader.slug})`))).toBe(true);
  });

  test("an owner with an App is unchanged: Touch ID and a token from the sign-in, never the reader", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(result.stderr).not.toContain("public read-only access");
    expect(env.mock.scopedTokens()).toHaveLength(1);
    expect(env.mock.installationTokens()).toEqual([]);
    expect(readerRequests(env).installations).toEqual([]);
  });

  test("an owner with an App you are not signed in to is refused as before, not given to the reader", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"], signedIn: false });
    const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("gh-touchid app login acme");
    expect(env.mock.installationTokens()).toEqual([]);
  });

  test("acting as an account comes first: Touch ID and the account's token, never the reader", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    env.seedAccount("alice", "ghp_alice");
    const result = await env.run(["as", "alice", "gh", "-R", "someone/project", "issue", "list"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(env.ghCalls().map((call) => call.ghToken)).toEqual(["ghp_alice"]);
    expect(env.mock.installationTokens()).toEqual([]);
  });

  test("gh's own failure still revokes the token, and its status passes through", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    const result = await env.run(["gh", "-R", "someone/project", "pr", "list"], { env: { FAKE_GH_EXIT: "3" } });
    expect(result.status).toBe(3);
    expectAllRevoked(env);
  });

  for (const [signal, number] of [["SIGTERM", 15], ["SIGINT", 2]] as const) {
    test(`${signal} while gh runs is passed on to gh, and the reader token is still revoked`, async () => {
      await using env = await TestEnv.create();
      seedReader(env);
      const running = env.start(["gh", "-R", "someone/project", "pr", "list"], { env: { FAKE_GH_MODE: "sleep" } });
      await env.waitForGhCalls(1);
      running.kill(signal);
      const result = await running.finished;
      expect(result.status).toBe(128 + number);
      expect(env.ghRunsAndSignals()).toEqual(["run", signal]);
      expectAllRevoked(env);
    });
  }
});

describe("checks on every reader token", () => {
  const faults: [string, (env: TestEnv, reader: MockReader) => void][] = [
    ["the App gained a permission", (_env, reader) => (reader.installation!.permissions = { issues: "write" })],
    [
      "the installation was given a repository",
      (env, reader) => {
        env.mock.seedRepository(`${reader.owner}/project`, { private: true });
        reader.installation!.repositories = [`${reader.owner}/project`];
      },
    ],
    ["the installation covers all repositories", (_env, reader) => (reader.installation!.repositories = "all")],
  ];
  for (const [name, breakIt] of faults) {
    test(`${name}: the token is revoked, the use refused with reader_permissions, gh not run`, async () => {
      await using env = await TestEnv.create();
      const reader = seedReader(env);
      breakIt(env, reader);
      const result = await env.run(["--json", "gh", "-R", "someone/project", "issue", "list"]);
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(lastError(result)?.code).toBe("reader_permissions");
      expect(result.stderr).not.toContain("public read-only access");
      expect(env.ghCalls()).toEqual([]);
      expect(env.mock.installationTokens()).toHaveLength(1);
      expectAllRevoked(env);
      expect(env.accessLog().some((line) => line.includes("refused someone/project"))).toBe(true);
    });
  }

  test("no installation: reader_not_installed with the install page, nothing minted", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env, { installed: false });
    const result = await env.run(["--json", "gh", "-R", "someone/project", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(lastError(result)?.code).toBe("reader_not_installed");
    expect(lastError(result)?.message).toContain(`/apps/${reader.slug}/installations/new`);
    expect(readerRequests(env).mints).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
  });

  test("two installations: reader_installations, nothing minted", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env);
    env.mock.seedInstallation(reader.app, "someone-else");
    const result = await env.run(["--json", "gh", "-R", "someone/project", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(lastError(result)?.code).toBe("reader_installations");
    expect(readerRequests(env).mints).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
  });

  test("one installation on another account than the stored owner: reader_installations, nothing minted", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env, { installed: false });
    env.mock.seedInstallation(reader.app, "someone-else");
    const result = await env.run(["--json", "gh", "-R", "someone/project", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(lastError(result)?.code).toBe("reader_installations");
    expect(readerRequests(env).mints).toEqual([]);
  });

  test("a key GitHub rejects: reader_key_rejected naming reader add, nothing minted", async () => {
    await using env = await TestEnv.create();
    const reader = seedReader(env);
    env.mock.rejectJWTs = true;
    const result = await env.run(["--json", "gh", "-R", "someone/project", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(lastError(result)?.code).toBe("reader_key_rejected");
    expect(lastError(result)?.message).toContain(`gh-touchid reader add --app-id ${reader.appId}`);
    expect(env.mock.installationTokens()).toEqual([]);
    expect(env.ghCalls()).toEqual([]);
  });

  test("GitHub failing to mint: refused with github, gh not run", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    env.mock.override((request, url) =>
      request.method === "POST" && url.pathname.endsWith("/access_tokens")
        ? new Response(JSON.stringify({ message: "Server Error" }), { status: 500 })
        : undefined,
    );
    const result = await env.run(["--json", "gh", "-R", "someone/project", "issue", "list"]);
    expect(result.status).toBe(1);
    expect(lastError(result)?.code).toBe("github");
    expect(env.ghCalls()).toEqual([]);
  });
});

describe("opening issues through the reader", () => {
  const opening: string[][] = [
    ["-R", "someone/project", "issue", "create", "-t", "x", "-b", "y"],
    ["issue", "create", "--title", "x", "--body", "y"],
    ["issue", "new", "-R", "someone/project"],
    ["issue", "-R", "someone/project", "create"],
    ["issue", "--repo=someone/project", "create"],
    ["api", "-X", "POST", "repos/someone/project/issues", "-f", "title=x"],
    ["api", "--method", "post", "/repos/someone/project/issues"],
    ["api", "--method=POST", "repos/someone/project/issues/"],
    ["api", "-XPOST", "repos/{owner}/{repo}/issues"],
    ["api", "repos/someone/project/issues", "-f", "title=x"],
    ["api", "repos/someone/project/issues", "-F", "title=x"],
    ["api", "repos/someone/project/issues", "--raw-field=title=x"],
    ["api", "repos/someone/project/issues", "--input", "issue.json"],
    ["api", "https://api.github.com/repos/someone/project/issues?per_page=1", "-f", "title=x"],
    ["api", "repositories/123456/issues", "-f", "title=x"],
    ["api", "-X", "POST", "repos/someone/project%2Fissues"],
    ["api", "graphql", "-f", "query=mutation { createIssue(input: {repositoryId: \"R\", title: \"x\"}) { clientMutationId } }"],
    ["api", "graphql", "--raw-field", "query=mutation{createIssue(input:{}){clientMutationId}}"],
    ["api", "graphql", "-F", "query=@mutation.graphql"],
    ["api", "graphql", "-f", "query=@-"],
    ["api", "graphql", "--input", "request.json"],
    ["api", "/graphql", "--field=query=mutation{createIssue(input:{}){clientMutationId}}"],
    // Cobra takes a value after any flag it does not know as a switch, and passes the flags before the command on
    ["issue", "--title", "x", "--body", "y", "create", "-R", "someone/project"],
    ["--title", "x", "issue", "create", "-R", "someone/project"],
    ["-X", "POST", "api", "repos/someone/project/issues"],
    // gh fills placeholders from GH_REPO and the repository here, after this check
    ["api", "repos/someone/project/{owner}", "-f", "title=x"],
    ["api", "-X", "POST", "repos/someone/project/:repo"],
    ["api", "graphql", "-F", "query=mutation{create{owner}(input:{}){clientMutationId}}"],
    ["api", "-X", "POST", "repos/someone/project/pulls/../issues"],
  ];
  for (const argv of opening) {
    test(`gh ${argv.join(" ")} is refused before any token is made`, async () => {
      await using env = await TestEnv.create();
      seedReader(env);
      const result = await env.run(["--json", "gh", ...argv]);
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(lastError(result)?.code).toBe("reader_opens_issue");
      expect(lastError(result)?.message).toContain("gh-touchid as <login> -- gh issue create");
      expect(env.mock.requests).toEqual([]);
      expect(env.ghCalls()).toEqual([]);
    });
  }

  const reading: string[][] = [
    ["-R", "someone/project", "issue", "list"],
    ["-R", "someone/project", "issue", "view", "1"],
    ["api", "repos/someone/project/issues"],
    ["api", "-X", "GET", "repos/someone/project/issues", "-f", "state=open"],
    ["api", "repos/someone/project/issues/1/comments"],
    ["api", "graphql", "-f", "query={ viewer { login } }"],
    ["api", "repos/{owner}/{repo}/issues"],
    ["api", "graphql", "-f", "query={ repository(owner: \"{owner}\", name: \"{repo}\") { name } }"],
    ["issue", "--web", "create"],
  ];
  for (const argv of reading) {
    test(`gh ${argv.join(" ")} reads through the reader`, async () => {
      await using env = await TestEnv.create();
      const reader = seedReader(env);
      const result = await env.run(["gh", ...argv]);
      expect(result.status).toBe(0);
      expect(result.stderr).toContain(readerNotice(reader.slug));
      expect(env.ghCalls()).toHaveLength(1);
      expectAllRevoked(env);
    });
  }

  test("an account may open issues: the block is the reader's only", async () => {
    await using env = await TestEnv.create();
    seedReader(env);
    env.seedAccount("alice", "ghp_alice");
    const result = await env.run(["as", "alice", "gh", "-R", "someone/project", "issue", "create", "-t", "x", "-b", "y"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(env.ghCalls()).toHaveLength(1);
  });
});
