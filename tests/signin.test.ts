// Signing in to an owner's App through the browser: `app create` (manifest, then sign-in, in one trip), `app login`
// and `app set`. The browser is the harness's driver; GitHub's pages are the mock's.

import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { browse } from "./support/browser";
import { services, type SignIn, TestEnv } from "./support/harness";

function appItem(env: TestEnv, owner = "acme"): Record<string, unknown> {
  return JSON.parse(env.item(services.app, owner)!);
}

function signInItem(env: TestEnv, owner = "acme"): SignIn {
  return JSON.parse(env.item(services.signIn, owner)!);
}

/** The PKCE pair the mock saw: the authorize request's challenge, and the verifier of the code exchange. */
function expectPKCE(env: TestEnv): void {
  const authorize = env.mock.requestsTo("GET", "/login/oauth/authorize");
  const exchange = env.mock.requestsTo("POST", "/login/oauth/access_token");
  expect(authorize).toHaveLength(1);
  expect(exchange).toHaveLength(1);
  expect(authorize[0]!.query).toMatchObject({ code_challenge_method: "S256", scope: "offline_access" });
  const verifier = String(exchange[0]!.fields?.code_verifier);
  expect(verifier).toMatch(/^[A-Za-z0-9._~-]{43,128}$/);
  expect(createHash("sha256").update(verifier).digest("base64url")).toBe(authorize[0]!.query.code_challenge!);
  expect(exchange[0]!.fields?.redirect_uri).toBe(env.callbackUrl);
}

/** acme, an organization alice belongs to; alice is signed in to the mock's web pages. */
function seedOrganization(env: TestEnv): void {
  env.mock.seedUser("alice");
  env.mock.seedOrganization("acme", ["alice"]);
  env.mock.browserLogin = "alice";
}

/** Runs `args`, follows the browser through its OPEN URL, and returns both outcomes. */
async function withBrowser(env: TestEnv, args: string[], options: { env?: Record<string, string>; stdin?: string } = {}) {
  const running = env.start(args, options);
  const [, url] = await running.waitForStderr(/^OPEN: (\S+)$/m);
  const browser = await browse(url!);
  return { browser, result: await running.finished, url: url! };
}

describe("app create", () => {
  test("one browser trip makes the App, signs in, stores both after one Touch ID and ends at the install page", async () => {
    await using env = await TestEnv.create();
    seedOrganization(env);
    const { browser, result } = await withBrowser(env, ["app", "create", "acme"]);
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);

    const app = env.mock.apps[0]!;
    expect(browser.visits.map((visit) => `${visit.method} ${new URL(visit.url).pathname}`)).toEqual([
      "GET /",
      "POST /organizations/acme/settings/apps/new",
      "GET /created",
      "GET /login/oauth/authorize",
      "GET /callback",
      `GET /apps/${app.slug}/installations/new`,
    ]);
    expect(browser.status).toBe(200);

    expect(app.manifest).toMatchObject({
      callback_urls: [env.callbackUrl],
      request_oauth_on_install: false,
      redirect_url: `http://127.0.0.1:${env.callbackPort}/created`,
      public: false,
    });
    expect(appItem(env)).toEqual({ clientId: app.clientId, clientSecret: app.clientSecret });
    expect(env.comment(services.app, "acme")).toBe(app.slug);
    const token = env.mock.userTokens()[0]!;
    expect(signInItem(env)).toMatchObject({ login: "alice", accessToken: token.token, refreshToken: token.refreshToken });
    expect(env.comment(services.signIn, "acme")).toBe("alice");
    expectPKCE(env);
    expect(env.accessLog().some((line) => line.includes(`stored the acme App ${app.slug} and signed in as alice`))).toBe(
      true,
    );
  });

  test("a denied authorization stores the App alone after one Touch ID, and says to run app login", async () => {
    await using env = await TestEnv.create();
    seedOrganization(env);
    env.mock.authorizeDecision = "deny";
    const { result } = await withBrowser(env, ["app", "create", "acme"]);
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect(result.stderr).toContain("gh-touchid app login acme");
    const app = env.mock.apps[0]!;
    expect(appItem(env)).toEqual({ clientId: app.clientId, clientSecret: app.clientSecret });
    expect(env.items(services.signIn)).toEqual([]);
  });

  test("a denied final Touch ID stores nothing", async () => {
    await using env = await TestEnv.create();
    seedOrganization(env);
    const { browser, result } = await withBrowser(env, ["app", "create", "acme"], {
      env: { GH_TOUCHID_TEST_DENY: "1" },
    });
    expect(result.status).toBe(1);
    expect(result.auth).toHaveLength(1);
    expect(browser.body).toContain("Nothing was stored");
    expect(env.items(services.app)).toEqual([]);
    expect(env.items(services.signIn)).toEqual([]);
  });
});

describe("app login", () => {
  test("turns away a stale callback, then signs in again and replaces the sign-in after one Touch ID", async () => {
    await using env = await TestEnv.create();
    const { app, token: old } = env.seedOwner({ owner: "acme", login: "alice", expiresIn: 60 });
    env.mock.browserLogin = "alice";
    const running = env.start(["app", "login", "acme"]);
    const [, url] = await running.waitForStderr(/^OPEN: (\S+)$/m);
    const authorize = new URL(url!);
    expect(authorize.origin + authorize.pathname).toBe(`${env.mock.url}/login/oauth/authorize`);
    expect(Object.fromEntries(authorize.searchParams)).toMatchObject({
      client_id: app.clientId,
      redirect_uri: env.callbackUrl,
      code_challenge_method: "S256",
    });

    const stale = await fetch(`${env.callbackUrl}?code=abc&state=stale`);
    expect(stale.status).toBe(400);
    expect(running.exited).toBe(false);

    const browser = await browse(url!);
    expect(browser.status).toBe(200);
    const result = await running.finished;
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    const renewed = env.mock.userTokens()[1]!;
    expect(signInItem(env)).toMatchObject({ login: "alice", accessToken: renewed.token });
    expect(signInItem(env).accessToken).not.toBe(old.token);
    expectPKCE(env);
    expect(env.accessLog().some((line) => line.includes("signed in as alice to the acme App"))).toBe(true);
  });

  test("a reply without an expiry or a refresh token is refused, nothing stored", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", signedIn: false });
    env.mock.browserLogin = "alice";
    env.mock.tokenReply = "non-expiring";
    const { browser, result } = await withBrowser(env, ["app", "login", "acme"]);
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(browser.body).toContain("Nothing was stored");
    expect(env.items(services.signIn)).toEqual([]);
  });

  test("an App stored by gh-touchid 0.3 is refused before the browser opens", async () => {
    await using env = await TestEnv.create();
    env.seedLegacyApp("acme", { clientId: "Iv1.legacy", privateKey: "-----BEGIN RSA PRIVATE KEY-----", slug: "acme-bot" });
    const result = await env.run(["app", "login", "acme"]);
    expect(result.status).toBe(1);
    expect(result.open).toEqual([]);
    expect(result.auth).toEqual([]);
    expect(result.stderr).toContain("gh-touchid app create acme");
    expect(env.mock.requests).toEqual([]);
  });

  test("without a stored App it says to create one", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["app", "login", "acme"]);
    expect(result.status).toBe(1);
    expect(result.open).toEqual([]);
    expect(result.stderr).toContain("gh-touchid app create acme");
  });
});

describe("app set", () => {
  function seedHandMadeApp(env: TestEnv) {
    seedOrganization(env);
    const app = env.mock.seedApp("acme", { slug: "acme-tools", callbackUrls: [env.callbackUrl] });
    env.mock.seedInstallation(app, "acme");
    return app;
  }

  test("signs in with the client secret from stdin and stores the App (slug from its installation) and the sign-in", async () => {
    await using env = await TestEnv.create();
    const app = seedHandMadeApp(env);
    const { result } = await withBrowser(env, ["app", "set", "acme", "--client-id", app.clientId], {
      stdin: `${app.clientSecret}\n`,
    });
    expect(result.status).toBe(0);
    expect(result.auth).toHaveLength(1);
    expect(appItem(env)).toEqual({ clientId: app.clientId, clientSecret: app.clientSecret });
    expect(env.comment(services.app, "acme")).toBe("acme-tools");
    expect(signInItem(env)).toMatchObject({ login: "alice", accessToken: env.mock.userTokens()[0]!.token });
    expect(env.comment(services.signIn, "acme")).toBe("alice");
    expectPKCE(env);
  });

  test("a wrong client secret stores nothing", async () => {
    await using env = await TestEnv.create();
    const app = seedHandMadeApp(env);
    const { browser, result } = await withBrowser(env, ["app", "set", "acme", "--client-id", app.clientId], {
      stdin: "not-the-secret\n",
    });
    expect(result.status).toBe(1);
    expect(result.auth).toEqual([]);
    expect(browser.body).toContain("Nothing was stored");
    expect(env.items(services.app)).toEqual([]);
    expect(env.items(services.signIn)).toEqual([]);
    expect(env.mock.userTokens()).toEqual([]);
  });
});

describe("the callback port", () => {
  test("in use: a clear error before any browser is opened", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", signedIn: false });
    const listener = Bun.listen({ hostname: "127.0.0.1", port: env.callbackPort, socket: { data() {} } });
    try {
      for (const args of [["app", "login", "acme"], ["app", "create", "acme"]]) {
        const result = await env.run(args);
        expect(result.status).toBe(1);
        expect(result.open).toEqual([]);
        expect(result.auth).toEqual([]);
        expect(result.stderr).toContain(`127.0.0.1:${env.callbackPort}`);
      }
    } finally {
      listener.stop(true);
    }
    expect(env.items(services.signIn)).toEqual([]);
  });
});
