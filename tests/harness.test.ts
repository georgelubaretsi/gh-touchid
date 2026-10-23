// The harness itself: the mock GitHub's plan B endpoints behave as the contract in local://plan-b.md says, the browser
// driver follows a manifest flow, and the fake gh records what it gets. These run without gh-touchid, except the fake
// gh tests, which need a TestEnv.

import { describe, expect, test } from "bun:test";
import { createHash, randomBytes } from "node:crypto";
import { browse, parseForm } from "./support/browser";
import { TestEnv } from "./support/harness";
import { MockGitHub } from "./support/mock-github";

async function withMock(body: (mock: MockGitHub) => Promise<void>): Promise<void> {
  const mock = new MockGitHub();
  try {
    await body(mock);
  } finally {
    await mock.stop();
  }
}

function basic(clientId: string, secret: string): string {
  return `Basic ${Buffer.from(`${clientId}:${secret}`).toString("base64")}`;
}

async function post(mock: MockGitHub, path: string, body: unknown, authorization?: string): Promise<Response> {
  return fetch(`${mock.url}${path}`, {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      ...(authorization ? { authorization } : {}),
    },
    body: JSON.stringify(body),
  });
}

/** The authorize step as a browser takes it; returns the code from the redirect. */
async function authorizeCode(mock: MockGitHub, clientId: string, redirectUri: string, challenge: string) {
  const url = new URL(`${mock.url}/login/oauth/authorize`);
  for (const [name, value] of Object.entries({
    client_id: clientId,
    redirect_uri: redirectUri,
    state: "s1",
    code_challenge: challenge,
    code_challenge_method: "S256",
    scope: "offline_access",
  })) {
    url.searchParams.set(name, value);
  }
  const response = await fetch(url, { redirect: "manual" });
  expect(response.status).toBe(302);
  const location = new URL(response.headers.get("location")!);
  expect(location.origin + location.pathname).toBe(redirectUri);
  expect(location.searchParams.get("state")).toBe("s1");
  return location.searchParams.get("code")!;
}

describe("mock GitHub: sign-in", () => {
  test("authorization code with PKCE, single use, then GET /user", () =>
    withMock(async (mock) => {
      const callback = "http://127.0.0.1:47911/callback";
      const app = mock.seedApp("acme", { callbackUrls: [callback] });
      mock.seedUser("alice");
      mock.browserLogin = "alice";
      const verifier = randomBytes(32).toString("base64url");
      const challenge = createHash("sha256").update(verifier).digest("base64url");
      const code = await authorizeCode(mock, app.clientId, callback, challenge);

      const exchange = (fields: Record<string, string>) =>
        post(mock, "/login/oauth/access_token", {
          client_id: app.clientId,
          client_secret: app.clientSecret,
          code,
          redirect_uri: callback,
          ...fields,
        }).then((response) => response.json());

      expect((await exchange({ code_verifier: "wrong" })).error).toBe("bad_verification_code");
      expect((await exchange({ code_verifier: verifier, client_secret: "nope" })).error).toBe(
        "incorrect_client_credentials",
      );
      const tokens = await exchange({ code_verifier: verifier });
      expect(tokens).toMatchObject({ token_type: "bearer", expires_in: 28800 });
      expect(tokens.access_token).toStartWith("ghu_");
      expect(tokens.refresh_token).toStartWith("ghr_");
      expect((await exchange({ code_verifier: verifier })).error).toBe("bad_verification_code");

      const user = await fetch(`${mock.url}/user`, { headers: { authorization: `Bearer ${tokens.access_token}` } });
      expect(await user.json()).toMatchObject({ login: "alice", type: "User" });
      expect(mock.userTokens().map((token) => token.login)).toEqual(["alice"]);
    }));

  test("authorize refuses an unknown redirect_uri or a missing challenge, and can be denied", () =>
    withMock(async (mock) => {
      const callback = "http://127.0.0.1:47911/callback";
      const app = mock.seedApp("acme", { callbackUrls: [callback] });
      mock.browserLogin = "acme";
      const authorize = (parameters: Record<string, string>) =>
        fetch(`${mock.url}/login/oauth/authorize?${new URLSearchParams({ client_id: app.clientId, ...parameters })}`, {
          redirect: "manual",
        });
      expect((await authorize({ redirect_uri: "http://127.0.0.1:1/callback", code_challenge: "x", code_challenge_method: "S256" })).status).toBe(400);
      expect((await authorize({ redirect_uri: callback })).status).toBe(400);
      mock.authorizeDecision = "deny";
      const denied = await authorize({ redirect_uri: callback, state: "s", code_challenge: "x", code_challenge_method: "S256" });
      const location = new URL(denied.headers.get("location")!);
      expect(location.searchParams.get("error")).toBe("access_denied");
      expect(location.searchParams.get("state")).toBe("s");
    }));

  test("a refresh token works once and replaces the access token", () =>
    withMock(async (mock) => {
      const app = mock.seedApp("acme");
      const token = mock.issueUserToken(app, "alice");
      const refresh = () =>
        fetch(`${mock.url}/login/oauth/access_token`, {
          method: "POST",
          headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            client_id: app.clientId,
            client_secret: app.clientSecret,
            grant_type: "refresh_token",
            refresh_token: token.refreshToken!,
          }).toString(),
        }).then((response) => response.json());
      const renewed = await refresh();
      expect(renewed.access_token).toStartWith("ghu_");
      expect(renewed.refresh_token).not.toBe(token.refreshToken);
      expect(await refresh()).toMatchObject({ error: "bad_refresh_token" });
      expect(token.revokedBy).toBe("refreshed");
      const old = await fetch(`${mock.url}/user`, { headers: { authorization: `Bearer ${token.token}` } });
      expect(old.status).toBe(401);
    }));

  test("a non-expiring reply has no expiry and no refresh token", () =>
    withMock(async (mock) => {
      const callback = "http://127.0.0.1:47911/callback";
      const app = mock.seedApp("acme", { callbackUrls: [callback] });
      mock.browserLogin = "acme";
      mock.tokenReply = "non-expiring";
      const verifier = "v".repeat(43);
      const code = await authorizeCode(
        mock,
        app.clientId,
        callback,
        createHash("sha256").update(verifier).digest("base64url"),
      );
      const reply = await post(mock, "/login/oauth/access_token", {
        client_id: app.clientId,
        client_secret: app.clientSecret,
        code,
        redirect_uri: callback,
        code_verifier: verifier,
      }).then((response) => response.json());
      expect(reply.access_token).toStartWith("ghu_");
      expect(reply.expires_in).toBeUndefined();
      expect(reply.refresh_token).toBeUndefined();
    }));
});

describe("mock GitHub: scoped tokens", () => {
  test("installations, scoping, repository access and revocation", () =>
    withMock(async (mock) => {
      mock.seedOrganization("acme", ["alice"]);
      const app = mock.seedApp("acme", { permissions: { contents: "write", issues: "write", metadata: "read" } });
      mock.seedInstallation(app, "acme", { repositories: ["acme/widgets"] });
      mock.seedRepository("acme/widgets");
      mock.seedRepository("acme/secret");
      const base = mock.issueUserToken(app, "alice");
      const auth = basic(app.clientId, app.clientSecret);

      const installations = await fetch(`${mock.url}/user/installations?per_page=100`, {
        headers: { authorization: `Bearer ${base.token}` },
      }).then((response) => response.json());
      expect(installations.total_count).toBe(1);
      expect(installations.installations[0]).toMatchObject({ account: { login: "acme", type: "Organization" } });

      const scope = (body: Record<string, unknown>, authorization = auth) =>
        post(mock, `/applications/${app.clientId}/token/scoped`, { access_token: base.token, target: "acme", ...body }, authorization);
      expect((await scope({ repositories: ["widgets"] }, basic(app.clientId, "wrong"))).status).toBe(401);
      expect((await scope({ access_token: "ghu_unknown", repositories: ["widgets"] })).status).toBe(404);
      expect((await scope({ repositories: ["secret"] })).status).toBe(422);
      expect((await scope({ repositories: ["widgets"], permissions: { workflows: "write" } })).status).toBe(422);
      expect((await scope({ repositories: ["widgets"], permissions: { metadata: "write" } })).status).toBe(422);
      expect((await scope({ target: "elsewhere", repositories: ["widgets"] })).status).toBe(422);

      const response = await scope({ repositories: ["widgets"], permissions: { issues: "write", metadata: "read" } });
      expect(response.status).toBe(200);
      const scoped = await response.json();
      expect(scoped.user.login).toBe("alice");
      expect(scoped.expires_at).toBe(new Date(base.expiresAt! * 1000).toISOString());
      expect(mock.scopedTokens()).toEqual([
        expect.objectContaining({
          token: scoped.token,
          repositories: ["acme/widgets"],
          permissions: { issues: "write", metadata: "read" },
          parent: base.token,
        }),
      ]);

      const read = (path: string) =>
        fetch(`${mock.url}${path}`, { headers: { authorization: `Bearer ${scoped.token}` } });
      expect(await (await read("/repos/acme/widgets")).json()).toMatchObject({ full_name: "acme/widgets", private: true });
      expect((await read("/repos/acme/secret")).status).toBe(404);

      const revoke = await fetch(`${mock.url}/applications/${app.clientId}/token`, {
        method: "DELETE",
        headers: { authorization: auth, "content-type": "application/json" },
        body: JSON.stringify({ access_token: scoped.token }),
      });
      expect(revoke.status).toBe(204);
      expect(mock.revocations).toEqual([expect.objectContaining({ token: scoped.token, kind: "scoped", status: 204 })]);
      expect(mock.liveScopedTokens()).toEqual([]);
      expect((await read("/user")).status).toBe(401);
    }));

  test("overrides answer before the routes", () =>
    withMock(async (mock) => {
      mock.override((request, url) =>
        request.method === "DELETE" && url.pathname.endsWith("/token") ? new Response(null, { status: 500 }) : undefined,
      );
      const response = await fetch(`${mock.url}/applications/x/token`, { method: "DELETE" });
      expect(response.status).toBe(500);
      expect(mock.requests.map((request) => request.status)).toEqual([500]);
      expect((await fetch(`${mock.url}/nowhere`)).status).toBe(404);
      expect(mock.unmatchedRequests().map((request) => request.path)).toEqual(["/nowhere"]);
    }));
});

describe("browser driver", () => {
  test("follows a manifest page through creation, sign-in and installation", () =>
    withMock(async (mock) => {
      mock.seedUser("alice");
      mock.browserLogin = "alice";
      // a stand-in for gh-touchid's listener: /, /created and /callback as plan B describes them
      let created: { slug: string; clientId: string } | undefined;
      let signedIn: string | undefined;
      const local = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        fetch: async (request) => {
          const url = new URL(request.url);
          const origin = `http://127.0.0.1:${local.port}`;
          if (url.pathname === "/") {
            const manifest = JSON.stringify({
              name: "acme <agent> & co",
              url: "https://example.com",
              public: false,
              redirect_url: `${origin}/created`,
              callback_urls: [`${origin}/callback`],
              default_permissions: { issues: "write", metadata: "read" },
            }).replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
            return new Response(
              `<form method="post" action="${mock.url}/settings/apps/new?state=st"><input type="hidden" name="manifest" value="${manifest}"></form>`,
              { headers: { "content-type": "text/html" } },
            );
          }
          if (url.pathname === "/created") {
            expect(url.searchParams.get("state")).toBe("st");
            const app = await post(mock, `/app-manifests/${url.searchParams.get("code")}/conversions`, {}).then((r) => r.json());
            created = { slug: app.slug, clientId: app.client_id };
            expect(app.pem).toContain("BEGIN RSA PRIVATE KEY");
            const authorize = new URL(`${mock.url}/login/oauth/authorize`);
            authorize.search = new URLSearchParams({
              client_id: app.client_id,
              redirect_uri: `${origin}/callback`,
              state: "st2",
              code_challenge: createHash("sha256").update("v".repeat(43)).digest("base64url"),
              code_challenge_method: "S256",
            }).toString();
            return Response.redirect(authorize.toString(), 302);
          }
          if (url.pathname === "/callback") {
            signedIn = url.searchParams.get("code") ?? undefined;
            return Response.redirect(`${mock.url}/apps/${created!.slug}/installations/new`, 302);
          }
          return new Response("not found", { status: 404 });
        },
      });
      try {
        const result = await browse(`http://127.0.0.1:${local.port}/`);
        expect(result.status).toBe(200);
        expect(result.body).toContain("Installed");
        expect(result.visits.map((visit) => `${visit.method} ${new URL(visit.url).pathname}`)).toEqual([
          "GET /",
          "POST /settings/apps/new",
          "GET /created",
          "GET /login/oauth/authorize",
          "GET /callback",
          `GET /apps/${created!.slug}/installations/new`,
        ]);
        expect(created!.slug).toBe("acme-agent-co");
        expect(signedIn).toMatch(/\S/);
        expect(mock.app(created!.clientId)!.callbackUrls).toEqual([`http://127.0.0.1:${local.port}/callback`]);
        expect(mock.installations.map((installation) => installation.account.login)).toEqual(["alice"]);
      } finally {
        await local.stop(true);
      }
    }));

  test("parseForm unescapes attribute values", () => {
    const form = parseForm(
      `<form method="POST" action="https://x/a?b=1&amp;c=2"><input type="hidden" name="manifest" value="{&quot;a&quot;:&#39;&lt;&gt;&#x26;&#39;}"></form>`,
    );
    expect(form).toEqual({ method: "post", action: "https://x/a?b=1&c=2", fields: { manifest: `{"a":'<>&'}` } });
  });
});

describe("fake gh", () => {
  test("records each command and exits as told", async () => {
    await using env = await TestEnv.create();
    const result = await env.exec([env.gh, "pr", "list"], {
      env: { GH_TOKEN: "ghu_x", GH_CONFIG_DIR: env.home, FAKE_GH_EXIT: "4", FAKE_GH_STDOUT: "out" },
    });
    expect(result).toMatchObject({ status: 4, stdout: "out" });
    const reference = await env.exec([env.gh, "help", "reference"]);
    expect(reference.stdout).toContain("### gh issue list");
    expect(env.ghEvents().map((event) => event.kind)).toEqual(["run", "reference"]);
    expect(env.ghCalls()[0]).toMatchObject({ argv: ["pr", "list"], ghToken: "ghu_x", configDir: env.home });
  });

  test("sleeps until a signal, and records it", async () => {
    await using env = await TestEnv.create();
    const running = env.startCommand([env.gh, "api", "user"], { env: { FAKE_GH_MODE: "sleep" } });
    await env.waitForGhCalls(1);
    running.kill("SIGINT");
    const result = await running.finished;
    expect(result.status).toBe(130);
    expect(env.ghEvents().map((event) => event.signal ?? event.kind)).toEqual(["run", "SIGINT"]);
  });
});
