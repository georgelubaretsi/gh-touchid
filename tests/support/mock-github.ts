// A stateful stand-in for GitHub's REST API and the web pages gh-touchid's flows go through (local://plan-b.md, "Test
// contract"). One instance per test: it listens on 127.0.0.1 and a random port, records every request, and keeps
// every token it issues or revokes so that tests can assert on them. Nothing here talks to github.com.
//
// Deliberate strictness beyond GitHub: the OAuth authorize page refuses a request without a PKCE challenge (gh-touchid
// always sends one), and refreshing a user token revokes the access token it replaces.

import { createHash, generateKeyPairSync, randomBytes } from "node:crypto";

export type Permissions = Record<string, string>;

export interface Account {
  login: string;
  type: "User" | "Organization";
  id: number;
  /** For an organization: the logins of its members, who can use its installations. */
  members: string[];
}

export interface App {
  id: number;
  slug: string;
  name: string;
  clientId: string;
  clientSecret: string;
  pem: string;
  owner: Account;
  /** What the App asks for when installed (the manifest's `default_permissions`). */
  permissions: Permissions;
  /** The OAuth callback URLs an authorize request's `redirect_uri` must equal. */
  callbackUrls: string[];
  /** The manifest's `redirect_url`, kept for inspection. */
  redirectUrl?: string;
  manifest?: Record<string, unknown>;
}

export interface Installation {
  id: number;
  app: App;
  account: Account;
  permissions: Permissions;
  /** `all`, or the full names (`owner/name`) of the repositories it was given. */
  repositories: "all" | string[];
}

export interface Repository {
  id: number;
  owner: string;
  name: string;
  fullName: string;
  private: boolean;
}

export type TokenKind = "personal" | "user" | "scoped";

export interface Token {
  token: string;
  kind: TokenKind;
  login: string;
  /** The App a `user` or `scoped` token belongs to. */
  clientId?: string;
  /** Unix seconds; undefined for a token that does not expire. */
  expiresAt?: number;
  /** A personal token's classic scopes, sent back as X-OAuth-Scopes. */
  scopes?: string;
  /** For a `user` token: its refresh token. */
  refreshToken?: string;
  refreshExpiresAt?: number;
  /** For a `scoped` token: the user token it was made from, its target, repositories (`owner/name`) and permissions. */
  parent?: string;
  target?: string;
  repositories?: string[];
  permissions?: Permissions;
  issuedAt: number;
  revoked: boolean;
  revokedAt?: number;
  /** Why it was revoked: `deleted` (DELETE /applications/{client_id}/token) or `refreshed`. */
  revokedBy?: "deleted" | "refreshed";
  /** For a `user` token: whether its refresh token was spent. */
  refreshUsed?: boolean;
}

export interface RecordedRequest {
  method: string;
  /** The path without the query. */
  path: string;
  query: Record<string, string>;
  headers: Record<string, string>;
  body: string;
  /** The body parsed as JSON or as a form, when it is one. */
  fields?: Record<string, unknown>;
  status: number;
  /** True when no route matched. */
  unmatched: boolean;
  at: number;
}

export interface Revocation {
  token: string;
  kind: TokenKind | "unknown";
  clientId: string;
  status: number;
  at: number;
}

interface AuthorizationCode {
  code: string;
  clientId: string;
  redirectUri: string;
  challenge?: string;
  challengeMethod?: string;
  scope?: string;
  login: string;
  used: boolean;
  expiresAt: number;
}

/** Answers a request before the routes do; return undefined to let the routes answer. */
export type Override = (request: Request, url: URL) => Response | undefined | Promise<Response | undefined>;

const levels: Record<string, number> = { read: 1, write: 2, admin: 3 };

export const defaultAppPermissions: Permissions = {
  actions: "write",
  checks: "read",
  contents: "write",
  issues: "write",
  metadata: "read",
  pull_requests: "write",
  statuses: "read",
  workflows: "write",
};

function now(): number {
  return Math.floor(Date.now() / 1000);
}

function random(prefix: string, bytes = 18): string {
  return prefix + randomBytes(bytes).toString("hex");
}

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

function html(status: number, text: string): Response {
  return new Response(`<!doctype html><meta charset="utf-8"><p>${text}</p>`, {
    status,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function redirect(location: string): Response {
  return new Response(null, { status: 302, headers: { location } });
}

function notFound(): Response {
  return json(404, { message: "Not Found", documentation_url: "https://docs.github.com/rest" });
}

function badCredentials(): Response {
  return json(401, { message: "Bad credentials", documentation_url: "https://docs.github.com/rest" });
}

function withQuery(base: string, parameters: Record<string, string>): string {
  const url = new URL(base);
  for (const [name, value] of Object.entries(parameters)) {
    url.searchParams.set(name, value);
  }
  return url.toString();
}

function parseFields(body: string, contentType: string): Record<string, unknown> | undefined {
  if (!body) {
    return undefined;
  }
  if (contentType.includes("json") || body.trimStart().startsWith("{")) {
    try {
      const value = JSON.parse(body);
      return value && typeof value === "object" ? value : undefined;
    } catch {
      return undefined;
    }
  }
  return Object.fromEntries(new URLSearchParams(body));
}

let rsaKey: string | undefined;

/** A real PKCS#1 RSA key, made once per test process: a manifest conversion hands it out as the App's `pem`. */
function appPrivateKey(): string {
  rsaKey ??= generateKeyPairSync("rsa", {
    modulusLength: 2048,
    privateKeyEncoding: { type: "pkcs1", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  }).privateKey;
  return rsaKey;
}

export class MockGitHub {
  /** Every request, in order of arrival. */
  readonly requests: RecordedRequest[] = [];
  /** Every token issued: personal tokens seeded by tests, user (`ghu_`) tokens, scoped tokens. */
  readonly tokens: Token[] = [];
  /** Every DELETE /applications/{client_id}/token, with what it named. */
  readonly revocations: Revocation[] = [];
  readonly accounts = new Map<string, Account>();
  readonly apps: App[] = [];
  readonly installations: Installation[] = [];
  readonly repositories = new Map<string, Repository>();

  /** Who is signed in to the mock's web pages (manifest form, authorize page, install page). */
  browserLogin?: string;
  /** What the authorize page answers: a code, or `error=access_denied`. */
  authorizeDecision: "approve" | "deny" = "approve";
  /** Lifetimes of user tokens and their refresh tokens (GitHub: 8 hours, about 6 months). */
  userTokenLifetime = 8 * 60 * 60;
  refreshTokenLifetime = 184 * 24 * 60 * 60;
  /** `non-expiring` answers a code exchange or refresh without `expires_in` and `refresh_token`. */
  tokenReply: "expiring" | "non-expiring" = "expiring";
  /** The owner a manifest's App is made for, instead of the account whose settings page got the form. */
  manifestOwner?: string;

  private readonly overrides: Override[] = [];
  private readonly manifestCodes = new Map<string, { app: App; used: boolean }>();
  private readonly codes = new Map<string, AuthorizationCode>();
  private nextId = 1000;
  private server: Bun.Server<undefined>;

  constructor() {
    this.server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch: (request) => this.handle(request),
    });
  }

  /** The base URL: GH_TOUCHID_API_URL, the API and the web pages alike. */
  get url(): string {
    return `http://127.0.0.1:${this.server.port}`;
  }

  /** `127.0.0.1:<port>`, what Git sends as the host of a credential request. */
  get host(): string {
    return `127.0.0.1:${this.server.port}`;
  }

  async stop(): Promise<void> {
    await this.server.stop(true);
  }

  // Seeding

  seedUser(login: string): Account {
    return this.seedAccount(login, "User");
  }

  seedOrganization(login: string, members: string[] = []): Account {
    const account = this.seedAccount(login, "Organization");
    account.members.push(...members.filter((member) => !account.members.includes(member)));
    return account;
  }

  /** A personal token of `login` (made a User when unknown), which GET /user accepts. */
  seedPersonalToken(login: string, options: { token?: string; scopes?: string } = {}): Token {
    this.account(login) ?? this.seedUser(login);
    const token: Token = {
      token: options.token ?? random("ghp_", 18),
      kind: "personal",
      login,
      scopes: options.scopes,
      issuedAt: now(),
      revoked: false,
    };
    this.tokens.push(token);
    return token;
  }

  seedRepository(fullName: string, options: { private?: boolean } = {}): Repository {
    const [owner, name] = fullName.split("/");
    if (!owner || !name) {
      throw new Error(`seedRepository takes owner/name, not ${fullName}`);
    }
    this.account(owner) ?? this.seedUser(owner);
    const repository: Repository = {
      id: this.nextId++,
      owner,
      name,
      fullName,
      private: options.private ?? true,
    };
    this.repositories.set(fullName.toLowerCase(), repository);
    return repository;
  }

  /** An App of `owner` (made a User when unknown), as if made from a manifest. */
  seedApp(
    owner: string,
    options: { slug?: string; name?: string; permissions?: Permissions; callbackUrls?: string[] } = {},
  ): App {
    const account = this.account(owner) ?? this.seedUser(owner);
    const name = options.name ?? `${owner}-agent`;
    const app: App = {
      id: this.nextId++,
      slug: options.slug ?? slugify(name),
      name,
      clientId: random("Iv23li", 7),
      clientSecret: random("", 20),
      pem: appPrivateKey(),
      owner: account,
      permissions: { ...(options.permissions ?? defaultAppPermissions) },
      callbackUrls: options.callbackUrls ?? [],
    };
    this.apps.push(app);
    return app;
  }

  /** Installs `app` on `account` (made a User when unknown): all its repositories unless `repositories` names some. */
  seedInstallation(
    app: App,
    account: string,
    options: { permissions?: Permissions; repositories?: string[] } = {},
  ): Installation {
    const installation: Installation = {
      id: this.nextId++,
      app,
      account: this.account(account) ?? this.seedUser(account),
      permissions: { ...(options.permissions ?? app.permissions) },
      repositories: options.repositories ?? "all",
    };
    this.installations.push(installation);
    return installation;
  }

  /** A user token of `app` for `login`, as a finished sign-in would get it. */
  issueUserToken(app: App, login: string, options: { expiresIn?: number; refreshExpiresIn?: number } = {}): Token {
    this.account(login) ?? this.seedUser(login);
    const issued = now();
    const token: Token = {
      token: random("ghu_", 18),
      kind: "user",
      login,
      clientId: app.clientId,
      expiresAt: issued + (options.expiresIn ?? this.userTokenLifetime),
      refreshToken: random("ghr_", 30),
      refreshExpiresAt: issued + (options.refreshExpiresIn ?? this.refreshTokenLifetime),
      issuedAt: issued,
      revoked: false,
    };
    this.tokens.push(token);
    return token;
  }

  /** Answers matching requests before the routes; for faults such as a failing revoke. */
  override(handler: Override): void {
    this.overrides.push(handler);
  }

  // Inspection

  /** Requests whose method matches and whose path matches `path` (a string is compared exactly). */
  requestsTo(method: string, path: string | RegExp): RecordedRequest[] {
    return this.requests.filter(
      (request) =>
        request.method === method && (typeof path === "string" ? request.path === path : path.test(request.path)),
    );
  }

  unmatchedRequests(): RecordedRequest[] {
    return this.requests.filter((request) => request.unmatched);
  }

  userTokens(): Token[] {
    return this.tokens.filter((token) => token.kind === "user");
  }

  scopedTokens(): Token[] {
    return this.tokens.filter((token) => token.kind === "scoped");
  }

  /** Scoped tokens neither revoked nor expired. */
  liveScopedTokens(): Token[] {
    return this.scopedTokens().filter((token) => this.isLive(token));
  }

  findToken(value: string): Token | undefined {
    return this.tokens.find((token) => token.token === value);
  }

  account(login: string): Account | undefined {
    return this.accounts.get(login.toLowerCase());
  }

  app(slugOrClientId: string): App | undefined {
    return this.apps.find((app) => app.slug === slugOrClientId || app.clientId === slugOrClientId);
  }

  // Serving

  private async handle(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const body = request.method === "GET" || request.method === "HEAD" ? "" : await request.text();
    const headers = Object.fromEntries(request.headers);
    const record: RecordedRequest = {
      method: request.method,
      path: url.pathname,
      query: Object.fromEntries(url.searchParams),
      headers,
      body,
      fields: parseFields(body, headers["content-type"] ?? ""),
      status: 0,
      unmatched: false,
      at: Date.now(),
    };
    this.requests.push(record);
    const replay = new Request(request.url, { method: request.method, headers: request.headers, body: body || null });
    let response: Response | undefined;
    for (const override of this.overrides) {
      response = await override(replay.clone(), url);
      if (response) {
        break;
      }
    }
    if (!response) {
      response = this.route(record, url);
      if (!response) {
        record.unmatched = true;
        response = notFound();
      }
    }
    record.status = response.status;
    return response;
  }

  private route(request: RecordedRequest, url: URL): Response | undefined {
    const { method, path } = request;
    let match: RegExpMatchArray | null;
    if (method === "GET" && path === "/user") {
      return this.getUser(request);
    }
    if (method === "GET" && (match = path.match(/^\/users\/([^/]+)$/))) {
      const account = this.account(decodeURIComponent(match[1]!));
      return account ? json(200, accountJSON(account)) : notFound();
    }
    if (method === "POST" && (match = path.match(/^\/(?:settings|organizations\/([^/]+)\/settings)\/apps\/new$/))) {
      return this.newAppFromManifest(request, match[1] ? decodeURIComponent(match[1]) : undefined);
    }
    if (method === "POST" && (match = path.match(/^\/app-manifests\/([^/]+)\/conversions$/))) {
      return this.convertManifest(decodeURIComponent(match[1]!));
    }
    if (method === "GET" && path === "/login/oauth/authorize") {
      return this.authorize(request);
    }
    if (method === "POST" && path === "/login/oauth/access_token") {
      return this.accessToken(request);
    }
    if (method === "GET" && path === "/user/installations") {
      return this.userInstallations(request);
    }
    if (method === "POST" && (match = path.match(/^\/applications\/([^/]+)\/token\/scoped$/))) {
      return this.scopedToken(request, decodeURIComponent(match[1]!));
    }
    if (method === "DELETE" && (match = path.match(/^\/applications\/([^/]+)\/token$/))) {
      return this.deleteToken(request, decodeURIComponent(match[1]!));
    }
    if (method === "GET" && (match = path.match(/^\/repos\/([^/]+)\/([^/]+)$/))) {
      return this.getRepository(request, `${decodeURIComponent(match[1]!)}/${decodeURIComponent(match[2]!)}`);
    }
    if (method === "GET" && (match = path.match(/^\/apps\/([^/]+)\/installations\/new$/))) {
      return this.installPage(decodeURIComponent(match[1]!), url);
    }
    return undefined;
  }

  private seedAccount(login: string, type: Account["type"]): Account {
    const existing = this.account(login);
    if (existing) {
      existing.type = type;
      return existing;
    }
    const account: Account = { login, type, id: this.nextId++, members: [] };
    this.accounts.set(login.toLowerCase(), account);
    return account;
  }

  private isLive(token: Token): boolean {
    return !token.revoked && (token.expiresAt === undefined || token.expiresAt > now());
  }

  /** The live token a `Bearer` (or `token`) Authorization header carries. */
  private bearer(request: RecordedRequest): Token | undefined {
    const match = (request.headers.authorization ?? "").match(/^(?:Bearer|token)\s+(\S+)$/i);
    const token = match ? this.findToken(match[1]!) : undefined;
    return token && this.isLive(token) ? token : undefined;
  }

  /** The App whose client ID and secret a `Basic` Authorization header carries. */
  private basicApp(request: RecordedRequest): App | undefined {
    const match = (request.headers.authorization ?? "").match(/^Basic\s+(\S+)$/i);
    if (!match) {
      return undefined;
    }
    const decoded = Buffer.from(match[1]!, "base64").toString("utf8");
    const separator = decoded.indexOf(":");
    const app = this.app(decoded.slice(0, separator));
    return app && app.clientSecret === decoded.slice(separator + 1) ? app : undefined;
  }

  private canUse(installation: Installation, login: string): boolean {
    const account = installation.account;
    return account.login.toLowerCase() === login.toLowerCase() || account.members.includes(login);
  }

  private getUser(request: RecordedRequest): Response {
    const token = this.bearer(request);
    if (!token) {
      return badCredentials();
    }
    const account = this.account(token.login)!;
    const headers: Record<string, string> = token.scopes === undefined ? {} : { "x-oauth-scopes": token.scopes };
    return json(200, accountJSON(account), headers);
  }

  private newAppFromManifest(request: RecordedRequest, organization: string | undefined): Response {
    if (!this.browserLogin) {
      return html(401, "Sign in to GitHub to continue.");
    }
    const raw = request.fields?.manifest;
    let manifest: Record<string, unknown>;
    try {
      manifest = JSON.parse(String(raw));
    } catch {
      return html(422, "The manifest is not valid JSON.");
    }
    const name = manifest.name;
    const redirectUrl = manifest.redirect_url;
    if (typeof name !== "string" || !name || typeof redirectUrl !== "string" || !redirectUrl) {
      return html(422, "The manifest needs a name and a redirect_url.");
    }
    const slug = slugify(name);
    if (this.apps.some((app) => app.slug === slug)) {
      return html(422, `The name ${name} is already taken.`);
    }
    const ownerLogin = this.manifestOwner ?? organization ?? this.browserLogin;
    const app = this.seedApp(ownerLogin, {
      name,
      slug,
      permissions: (manifest.default_permissions as Permissions | undefined) ?? {},
      callbackUrls: Array.isArray(manifest.callback_urls) ? manifest.callback_urls.map(String) : [],
    });
    if (organization && !this.manifestOwner) {
      this.seedOrganization(organization, [this.browserLogin]);
    }
    app.redirectUrl = redirectUrl;
    app.manifest = manifest;
    const code = random("", 10);
    this.manifestCodes.set(code, { app, used: false });
    const parameters: Record<string, string> = { code };
    if (request.query.state !== undefined) {
      parameters.state = request.query.state;
    }
    return redirect(withQuery(redirectUrl, parameters));
  }

  private convertManifest(code: string): Response {
    const entry = this.manifestCodes.get(code);
    if (!entry || entry.used) {
      return notFound();
    }
    entry.used = true;
    const { app } = entry;
    return json(201, {
      id: app.id,
      slug: app.slug,
      node_id: `A_${app.id}`,
      name: app.name,
      owner: accountJSON(app.owner),
      client_id: app.clientId,
      client_secret: app.clientSecret,
      webhook_secret: null,
      pem: app.pem,
      permissions: app.permissions,
      events: [],
    });
  }

  private authorize(request: RecordedRequest): Response {
    const query = request.query;
    const app = query.client_id ? this.app(query.client_id) : undefined;
    if (!app || app.clientId !== query.client_id) {
      return html(404, "No such application.");
    }
    if (!query.redirect_uri || !app.callbackUrls.includes(query.redirect_uri)) {
      return html(400, "The redirect_uri is not associated with this application.");
    }
    if (!this.browserLogin) {
      return html(401, "Sign in to GitHub to continue.");
    }
    if (!query.code_challenge || query.code_challenge_method !== "S256") {
      return html(400, "This mock requires a PKCE code_challenge with code_challenge_method=S256.");
    }
    const state: Record<string, string> = query.state === undefined ? {} : { state: query.state };
    if (this.authorizeDecision === "deny") {
      return redirect(
        withQuery(query.redirect_uri, {
          error: "access_denied",
          error_description: "The user has denied your application access.",
          ...state,
        }),
      );
    }
    const code = random("", 10);
    this.codes.set(code, {
      code,
      clientId: app.clientId,
      redirectUri: query.redirect_uri,
      challenge: query.code_challenge,
      challengeMethod: query.code_challenge_method,
      scope: query.scope,
      login: this.browserLogin,
      used: false,
      expiresAt: now() + 600,
    });
    return redirect(withQuery(query.redirect_uri, { code, ...state }));
  }

  private accessToken(request: RecordedRequest): Response {
    const fields: Record<string, string> = { ...request.query };
    for (const [name, value] of Object.entries(request.fields ?? {})) {
      fields[name] = String(value);
    }
    const asJSON = (request.headers.accept ?? "").includes("application/json");
    const reply = (body: Record<string, unknown>): Response =>
      asJSON
        ? json(200, body)
        : new Response(new URLSearchParams(Object.entries(body).map(([k, v]) => [k, String(v)])).toString(), {
            status: 200,
            headers: { "content-type": "application/x-www-form-urlencoded; charset=utf-8" },
          });
    const failure = (error: string, description: string): Response =>
      reply({ error, error_description: description, error_uri: "https://docs.github.com" });

    const app = fields.client_id ? this.app(fields.client_id) : undefined;
    if (!app || app.clientId !== fields.client_id || app.clientSecret !== fields.client_secret) {
      return failure("incorrect_client_credentials", "The client_id and/or client_secret passed are incorrect.");
    }

    let login: string;
    if (fields.grant_type === "refresh_token") {
      const previous = this.tokens.find(
        (token) => token.kind === "user" && token.refreshToken !== undefined && token.refreshToken === fields.refresh_token,
      );
      const usable =
        previous &&
        previous.clientId === app.clientId &&
        !previous.refreshUsed &&
        (previous.refreshExpiresAt ?? 0) > now();
      if (!previous || !usable) {
        return failure("bad_refresh_token", "The refresh token passed is incorrect or expired.");
      }
      previous.refreshUsed = true;
      if (!previous.revoked) {
        previous.revoked = true;
        previous.revokedAt = now();
        previous.revokedBy = "refreshed";
      }
      login = previous.login;
    } else {
      if (fields.grant_type !== undefined && fields.grant_type !== "authorization_code") {
        return failure("unsupported_grant_type", `The grant type ${fields.grant_type} is not supported.`);
      }
      const code = fields.code ? this.codes.get(fields.code) : undefined;
      if (!code || code.used || code.expiresAt <= now() || code.clientId !== app.clientId) {
        return failure("bad_verification_code", "The code passed is incorrect or expired.");
      }
      if (fields.redirect_uri !== undefined && fields.redirect_uri !== code.redirectUri) {
        return failure("redirect_uri_mismatch", "The redirect_uri MUST match the registered callback URL.");
      }
      const challenge = fields.code_verifier && createHash("sha256").update(fields.code_verifier).digest("base64url");
      if (code.challenge && challenge !== code.challenge) {
        return failure("bad_verification_code", "The code_verifier does not match the code_challenge.");
      }
      code.used = true;
      login = code.login;
    }

    const token = this.issueUserToken(app, login);
    if (this.tokenReply === "non-expiring") {
      token.expiresAt = undefined;
      token.refreshToken = undefined;
      token.refreshExpiresAt = undefined;
      return reply({ access_token: token.token, token_type: "bearer", scope: "" });
    }
    return reply({
      access_token: token.token,
      expires_in: token.expiresAt! - token.issuedAt,
      refresh_token: token.refreshToken,
      refresh_token_expires_in: token.refreshExpiresAt! - token.issuedAt,
      token_type: "bearer",
      scope: "",
    });
  }

  private userInstallations(request: RecordedRequest): Response {
    const token = this.bearer(request);
    if (!token || token.kind !== "user") {
      return badCredentials();
    }
    const installations = this.installations.filter(
      (installation) => installation.app.clientId === token.clientId && this.canUse(installation, token.login),
    );
    return json(200, {
      total_count: installations.length,
      installations: installations.map((installation) => ({
        id: installation.id,
        account: accountJSON(installation.account),
        app_id: installation.app.id,
        app_slug: installation.app.slug,
        target_type: installation.account.type,
        permissions: installation.permissions,
        repository_selection: installation.repositories === "all" ? "all" : "selected",
      })),
    });
  }

  private scopedToken(request: RecordedRequest, clientId: string): Response {
    const app = this.basicApp(request);
    if (!app || app.clientId !== clientId) {
      return badCredentials();
    }
    const fields = request.fields ?? {};
    const base = this.findToken(String(fields.access_token ?? ""));
    if (!base || base.kind !== "user" || base.clientId !== app.clientId || !this.isLive(base)) {
      return notFound();
    }
    const unprocessable = (message: string): Response =>
      json(422, { message, documentation_url: "https://docs.github.com/rest" });
    const target = typeof fields.target === "string" ? fields.target : undefined;
    const installation = target
      ? this.installations.find(
          (candidate) =>
            candidate.app.clientId === app.clientId &&
            candidate.account.login.toLowerCase() === target.toLowerCase() &&
            this.canUse(candidate, base.login),
        )
      : undefined;
    if (!target || !installation) {
      return unprocessable(`The App is not installed on ${target ?? "the target"} for this user.`);
    }
    const names = Array.isArray(fields.repositories) ? fields.repositories.map(String) : [];
    const repositories: string[] = [];
    for (const name of names) {
      const repository = this.repositories.get(`${installation.account.login}/${name}`.toLowerCase());
      const included =
        repository &&
        (installation.repositories === "all" ||
          installation.repositories.some((full) => full.toLowerCase() === repository.fullName.toLowerCase()));
      if (!repository || !included) {
        return unprocessable(`The repository ${name} is not part of the installation.`);
      }
      repositories.push(repository.fullName);
    }
    const requested =
      fields.permissions && typeof fields.permissions === "object"
        ? Object.fromEntries(Object.entries(fields.permissions as Record<string, unknown>).map(([k, v]) => [k, String(v)]))
        : { ...installation.permissions };
    for (const [permission, level] of Object.entries(requested)) {
      const granted = installation.permissions[permission];
      if (!levels[level] || !granted || levels[granted]! < levels[level]!) {
        return unprocessable(`The permission ${permission}: ${level} is not granted to the installation.`);
      }
    }
    const scoped: Token = {
      token: random("ghu_", 18),
      kind: "scoped",
      login: base.login,
      clientId: app.clientId,
      expiresAt: base.expiresAt,
      parent: base.token,
      target: installation.account.login,
      repositories,
      permissions: requested,
      issuedAt: now(),
      revoked: false,
    };
    this.tokens.push(scoped);
    return json(200, {
      id: this.nextId++,
      token: scoped.token,
      token_last_eight: scoped.token.slice(-8),
      hashed_token: createHash("sha256").update(scoped.token).digest("base64"),
      app: { client_id: app.clientId, name: app.name, url: `${this.url}/apps/${app.slug}` },
      expires_at: scoped.expiresAt === undefined ? null : new Date(scoped.expiresAt * 1000).toISOString(),
      user: accountJSON(this.account(base.login)!),
      scopes: [],
      note: null,
      created_at: new Date(scoped.issuedAt * 1000).toISOString(),
    });
  }

  private deleteToken(request: RecordedRequest, clientId: string): Response {
    const app = this.basicApp(request);
    if (!app || app.clientId !== clientId) {
      return badCredentials();
    }
    const value = String(request.fields?.access_token ?? "");
    const token = this.findToken(value);
    const known = token !== undefined && token.clientId === app.clientId;
    const status = known ? 204 : 404;
    this.revocations.push({ token: value, kind: token?.kind ?? "unknown", clientId, status, at: Date.now() });
    if (!known) {
      return notFound();
    }
    if (!token.revoked) {
      token.revoked = true;
      token.revokedAt = now();
      token.revokedBy = "deleted";
    }
    return new Response(null, { status: 204 });
  }

  private getRepository(request: RecordedRequest, fullName: string): Response {
    const token = this.bearer(request);
    if (!token) {
      return badCredentials();
    }
    const repository = this.repositories.get(fullName.toLowerCase());
    if (!repository) {
      return notFound();
    }
    let visible: boolean;
    if (token.kind === "scoped") {
      visible = (token.repositories ?? []).some((name) => name.toLowerCase() === repository.fullName.toLowerCase());
    } else if (token.kind === "user") {
      visible = this.installations.some(
        (installation) =>
          installation.app.clientId === token.clientId &&
          installation.account.login.toLowerCase() === repository.owner.toLowerCase() &&
          this.canUse(installation, token.login) &&
          (installation.repositories === "all" ||
            installation.repositories.some((name) => name.toLowerCase() === repository.fullName.toLowerCase())),
      );
    } else {
      visible = true;
    }
    if (!visible && repository.private) {
      return notFound();
    }
    return json(200, {
      id: repository.id,
      name: repository.name,
      full_name: repository.fullName,
      private: repository.private,
      owner: accountJSON(this.account(repository.owner)!),
    });
  }

  /** "Installs" the App on `?target=<login>` (default: the browser's account), on `?repositories=a,b` or all. */
  private installPage(slug: string, url: URL): Response {
    const app = this.apps.find((candidate) => candidate.slug === slug);
    if (!app) {
      return html(404, "No such GitHub App.");
    }
    const target = url.searchParams.get("target") ?? this.browserLogin;
    if (!target) {
      return html(401, "Sign in to GitHub to continue.");
    }
    const repositories = url.searchParams.get("repositories");
    const installation = this.seedInstallation(app, target, {
      repositories: repositories ? repositories.split(",").map((name) => `${target}/${name}`) : undefined,
    });
    return html(200, `Installed ${app.slug} on ${installation.account.login}.`);
  }
}

function accountJSON(account: Account): Record<string, unknown> {
  return { login: account.login, id: account.id, type: account.type };
}

function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}
