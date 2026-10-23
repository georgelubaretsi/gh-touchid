// One isolated world per test: a temporary folder for all of gh-touchid's state (GH_TOUCHID_TEST_DIR), its own mock
// GitHub, its own fake gh and callback port, and a clean environment, so tests can run in parallel. Use it as
//
//   await using env = await TestEnv.create();
//   const result = await env.run(["gh", "-R", "acme/widgets", "issue", "list"]);
//
// Disposing it stops the gh-touchid agents it started, kills processes left running, stops the mock and deletes the
// folder. Only the test build runs here: it never shows Touch ID, never reads the Keychain and never writes the
// user's access log.

import { createConnection } from "node:net";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import type { Subprocess } from "bun";
import { type App, type Installation, MockGitHub, type Permissions, type Token } from "./mock-github";

export const repositoryRoot = resolve(import.meta.dir, "../..");

/** The test build (`scripts/build.sh --testing`): GH_TOUCHID_BINARY, else build/test/gh-touchid. */
export const binary = resolve(repositoryRoot, process.env.GH_TOUCHID_BINARY ?? "build/test/gh-touchid");

/** Keychain services, which test builds keep as folders under secrets/ and comments/. */
export const services = {
  app: "com.lubaretsi.gh-touchid.app",
  signIn: "com.lubaretsi.gh-touchid.signin",
  user: "com.lubaretsi.gh-touchid.user",
} as const;

const fakeGitHubCLI = join(import.meta.dir, "fake-gh.ts");
const helpReference = join(import.meta.dir, "help-reference.md");

export interface RunOptions {
  /** The folder to run in; by default a folder that is not in a Git repository. */
  cwd?: string;
  /** Variables added to the clean environment; `undefined` removes one. */
  env?: Record<string, string | undefined>;
  /** Standard input; by default /dev/null. */
  stdin?: string;
  /** Runs under script(1), so that standard input and output are a terminal. */
  tty?: boolean;
}

export interface RunResult {
  /** The exit status, or null when a signal ended the process. */
  status: number | null;
  signal: string | null;
  stdout: string;
  stderr: string;
  /** The `AUTH: <fallback>` lines: one per Touch ID prompt. */
  auth: string[];
  /** The `OPEN: <url>` lines: the URLs gh-touchid would open in a browser. */
  open: string[];
}

/** What the fake gh received for one command (not `help reference`). */
export interface GhCall {
  kind: "run";
  argv: string[];
  hasGhToken: boolean;
  ghToken: string | null;
  githubToken: string | null;
  ghEnterpriseToken: string | null;
  configDir: string | null;
  configDirExists: boolean;
  /** The entries of GH_CONFIG_DIR when gh started. */
  configDirEntries: string[] | null;
  ghPager: string | null;
  ghRepo: string | null;
  cwd: string;
  pid: number;
  at: number;
}

export interface GhEvent {
  kind: "run" | "reference" | "signal";
  pid: number;
  at: number;
  signal?: string;
  [field: string]: unknown;
}

export interface SignIn {
  login: string;
  accessToken: string;
  /** Unix seconds. */
  accessExpires: number;
  refreshToken: string;
  refreshExpires: number;
}

/** A process started with `TestEnv.start`, whose output can be watched while it runs. */
export class Running {
  stdout = "";
  stderr = "";
  readonly finished: Promise<RunResult>;

  constructor(readonly process: Subprocess<"ignore" | "pipe", "pipe", "pipe">) {
    const collect = async (stream: ReadableStream<Uint8Array>, field: "stdout" | "stderr") => {
      const decoder = new TextDecoder();
      for await (const chunk of stream) {
        this[field] += decoder.decode(chunk, { stream: true });
      }
    };
    this.finished = Promise.all([
      collect(process.stdout, "stdout"),
      collect(process.stderr, "stderr"),
      process.exited,
    ]).then(() => ({
      status: process.signalCode ? null : process.exitCode,
      signal: process.signalCode,
      stdout: this.stdout,
      stderr: this.stderr,
      auth: prefixedLines(this.stderr, "AUTH: "),
      open: prefixedLines(this.stderr, "OPEN: "),
    }));
  }

  get exited(): boolean {
    return this.process.exitCode !== null || this.process.signalCode !== null;
  }

  /** Waits until standard error matches `pattern`; fails when the process exits first or after `timeout` ms. */
  async waitForStderr(pattern: RegExp, timeout = 15_000): Promise<RegExpMatchArray> {
    const deadline = Date.now() + timeout;
    for (;;) {
      const match = this.stderr.match(pattern);
      if (match) {
        return match;
      }
      if (this.exited) {
        await this.finished;
        const late = this.stderr.match(pattern);
        if (late) {
          return late;
        }
        throw new Error(`exited before stderr matched ${pattern}:\n${this.stderr}`);
      }
      if (Date.now() > deadline) {
        throw new Error(`stderr did not match ${pattern} within ${timeout} ms:\n${this.stderr}`);
      }
      await Bun.sleep(20);
    }
  }

  kill(signal: NodeJS.Signals = "SIGKILL"): void {
    if (!this.exited) {
      this.process.kill(signal);
    }
  }
}

export class TestEnv {
  /** GH_TOUCHID_TEST_DIR. */
  readonly dir: string;
  /** A folder outside any Git repository, where commands run by default. */
  readonly workDir: string;
  readonly home: string;
  readonly ghLog: string;
  /** The fake gh's wrapper, GH_TOUCHID_GH. */
  readonly gh: string;
  private readonly started: Running[] = [];

  private constructor(
    readonly mock: MockGitHub,
    /** GH_TOUCHID_TEST_CALLBACK_PORT, free when the test started. */
    readonly callbackPort: number,
  ) {
    // short: the agent's socket path in it must fit in sockaddr_un (104 bytes)
    this.dir = realpathSync(mkdtempSync("/tmp/gh-touchid-test-"));
    this.workDir = join(this.dir, "work");
    this.home = join(this.dir, "home");
    this.ghLog = join(this.dir, "gh.jsonl");
    this.gh = join(this.dir, "fake", "gh");
    for (const folder of [this.workDir, this.home, join(this.dir, "tmp"), join(this.dir, "bin"), join(this.dir, "fake")]) {
      mkdirSync(folder, { recursive: true });
    }
    writeFileSync(join(this.home, ".gitconfig"), "");
    const git = Bun.which("git");
    if (!git) {
      throw new Error("the tests need git on PATH");
    }
    symlinkSync(git, join(this.dir, "bin", "git"));
    writeFileSync(this.gh, `#!/bin/sh\nexec ${shellQuote(process.execPath)} ${shellQuote(fakeGitHubCLI)} "$@"\n`);
    chmodSync(this.gh, 0o755);
  }

  static async create(): Promise<TestEnv> {
    if (!existsSync(binary)) {
      throw new Error(`no test build at ${binary}; run \`just test\`, or scripts/build.sh --output ${binary} --testing`);
    }
    return new TestEnv(new MockGitHub(), freePort());
  }

  /** The OAuth callback URL a test build listens on (plan B). */
  get callbackUrl(): string {
    return `http://127.0.0.1:${this.callbackPort}/callback`;
  }

  /** The clean environment gh-touchid runs with, plus `extra`. */
  environment(extra: Record<string, string | undefined> = {}): Record<string, string> {
    const environment: Record<string, string | undefined> = {
      PATH: `${join(this.dir, "bin")}:/usr/bin:/bin:/usr/sbin:/sbin`,
      HOME: this.home,
      TMPDIR: `${join(this.dir, "tmp")}/`,
      XDG_CONFIG_HOME: join(this.home, ".config"),
      GIT_CONFIG_GLOBAL: join(this.home, ".gitconfig"),
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_TERMINAL_PROMPT: "0",
      LANG: "en_US.UTF-8",
      GH_TOUCHID_TEST_DIR: this.dir,
      GH_TOUCHID_API_URL: this.mock.url,
      GH_TOUCHID_GH: this.gh,
      GH_TOUCHID_TEST_CALLBACK_PORT: String(this.callbackPort),
      FAKE_GH_LOG: this.ghLog,
      FAKE_GH_REFERENCE: helpReference,
      ...extra,
    };
    return Object.fromEntries(
      Object.entries(environment).filter((entry): entry is [string, string] => entry[1] !== undefined),
    );
  }

  /** Starts the test build with `args`; watch it with the returned `Running`. */
  start(args: string[], options: RunOptions = {}): Running {
    return this.startCommand([binary, ...args], options);
  }

  /** Runs the test build with `args` to the end. */
  run(args: string[], options: RunOptions = {}): Promise<RunResult> {
    return this.start(args, options).finished;
  }

  /** Starts any command (such as `git`) in the same clean environment. */
  startCommand(command: string[], options: RunOptions = {}): Running {
    const running = new Running(
      Bun.spawn(options.tty ? ["/usr/bin/script", "-q", "/dev/null", ...command] : command, {
        cwd: options.cwd ?? this.workDir,
        env: this.environment(options.env),
        stdin: options.stdin === undefined ? "ignore" : Buffer.from(options.stdin),
        stdout: "pipe",
        stderr: "pipe",
      }) as Subprocess<"ignore" | "pipe", "pipe", "pipe">,
    );
    this.started.push(running);
    return running;
  }

  /** Runs any command in the same clean environment to the end. */
  exec(command: string[], options: RunOptions = {}): Promise<RunResult> {
    return this.startCommand(command, options).finished;
  }

  // Stored items, as test builds keep them: secrets/<service>/<account>, comments/<service>/<account>, and
  // descriptions/<service>/<account> (the item's format, `gh-touchid format N`; none for items 0.4.0 wrote)

  writeItem(service: string, account: string, secret: string, comment?: string): void {
    const write = (kind: "secrets" | "comments", contents: string) => {
      const folder = join(this.dir, kind, service);
      mkdirSync(folder, { recursive: true, mode: 0o700 });
      writeFileSync(join(folder, account), contents, { mode: 0o600 });
    };
    write("secrets", secret);
    if (comment !== undefined) {
      write("comments", comment);
    }
  }

  /** The secret of an item, or undefined when there is none. */
  item(service: string, account: string): string | undefined {
    const path = join(this.dir, "secrets", service, account);
    return existsSync(path) ? readFileSync(path, "utf8") : undefined;
  }

  comment(service: string, account: string): string | undefined {
    const path = join(this.dir, "comments", service, account);
    return existsSync(path) ? readFileSync(path, "utf8") : undefined;
  }

  /** An item's description, which says its format, or undefined when it has none. */
  description(service: string, account: string): string | undefined {
    const path = join(this.dir, "descriptions", service, account);
    return existsSync(path) ? readFileSync(path, "utf8") : undefined;
  }

  /** Marks an item as written in `format`, as a gh-touchid of that format would. */
  writeFormat(service: string, account: string, format: number): void {
    const folder = join(this.dir, "descriptions", service);
    mkdirSync(folder, { recursive: true, mode: 0o700 });
    writeFileSync(join(folder, account), `gh-touchid format ${format}`, { mode: 0o600 });
  }

  /** The accounts with an item of `service`. */
  items(service: string): string[] {
    const folder = join(this.dir, "secrets", service);
    return existsSync(folder) ? readdirSync(folder).sort() : [];
  }

  /** An owner's App as plan B stores it: `{clientId, clientSecret}`, the slug as its comment. */
  seedApp(owner: string, app: { clientId: string; clientSecret: string; slug?: string }): void {
    const secret = JSON.stringify({ clientId: app.clientId, clientSecret: app.clientSecret });
    this.writeItem(services.app, owner.toLowerCase(), secret, app.slug);
  }

  /** An owner's sign-in (plan B); the login is its comment. */
  seedSignIn(owner: string, signIn: SignIn): void {
    this.writeItem(services.signIn, owner.toLowerCase(), JSON.stringify(signIn), signIn.login);
  }

  /** A token of one of your accounts (`user add`). */
  seedAccount(login: string, token: string): void {
    this.writeItem(services.user, login.toLowerCase(), token);
  }

  /**
   * Plan B in one call: the owner's App on the mock (with this test's callback URL), installed on the owner, the
   * repositories, a signed-in user token of `login`, and the App and sign-in items that point at them.
   */
  seedOwner(options: {
    owner: string;
    login: string;
    /** Repository names under the owner; private unless listed in `public`. */
    repositories?: string[];
    public?: string[];
    permissions?: Permissions;
    /** The repositories the installation covers (names under the owner); all by default. */
    installedOn?: string[];
    /** The user token's remaining lifetime in seconds, and its refresh token's. */
    expiresIn?: number;
    refreshExpiresIn?: number;
    /** false: the App is stored, but nobody is signed in to it. */
    signedIn?: boolean;
  }): { app: App; installation: Installation; token: Token } {
    const { owner, login } = options;
    if (owner.toLowerCase() !== login.toLowerCase()) {
      this.mock.seedOrganization(owner, [login]);
    }
    this.mock.seedUser(login);
    const app = this.mock.seedApp(owner, { callbackUrls: [this.callbackUrl], permissions: options.permissions });
    const installation = this.mock.seedInstallation(app, owner, {
      repositories: options.installedOn?.map((name) => `${owner}/${name}`),
    });
    for (const name of options.repositories ?? []) {
      this.mock.seedRepository(`${owner}/${name}`, { private: !(options.public ?? []).includes(name) });
    }
    const token = this.mock.issueUserToken(app, login, {
      expiresIn: options.expiresIn,
      refreshExpiresIn: options.refreshExpiresIn,
    });
    this.seedApp(owner, { clientId: app.clientId, clientSecret: app.clientSecret, slug: app.slug });
    if (options.signedIn !== false) {
      this.seedSignIn(owner, {
        login,
        accessToken: token.token,
        accessExpires: token.expiresAt!,
        refreshToken: token.refreshToken!,
        refreshExpires: token.refreshExpiresAt!,
      });
    }
    return { app, installation, token };
  }

  // Observations

  /** The test build's access log, one entry per line. */
  accessLog(): string[] {
    const path = join(this.dir, "access.log");
    return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter(Boolean) : [];
  }

  /** Everything the fake gh recorded, in order. */
  ghEvents(): GhEvent[] {
    return existsSync(this.ghLog)
      ? readFileSync(this.ghLog, "utf8")
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line))
      : [];
  }

  /** The commands gh ran with (not `help reference`). */
  ghCalls(): GhCall[] {
    return this.ghEvents().filter((event): event is GhEvent & GhCall => event.kind === "run");
  }

  /** Waits until the fake gh has recorded `count` commands; for gh left running (FAKE_GH_MODE=sleep). */
  async waitForGhCalls(count = 1, timeout = 15_000): Promise<GhCall[]> {
    const deadline = Date.now() + timeout;
    while (this.ghCalls().length < count) {
      if (Date.now() > deadline) {
        throw new Error(`gh ran ${this.ghCalls().length} times, not ${count}, within ${timeout} ms`);
      }
      await Bun.sleep(20);
    }
    return this.ghCalls();
  }

  /** A Git repository under the work folder whose `origin` is `owner/name` on the mock's host. */
  makeRepository(fullName: string, folder = join(this.workDir, fullName.replace("/", "-"))): string {
    mkdirSync(folder, { recursive: true });
    const git = (...args: string[]) => {
      const result = Bun.spawnSync(["git", ...args], { cwd: folder, env: this.environment() });
      if (result.exitCode !== 0) {
        throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString()}`);
      }
    };
    git("init", "-q");
    git("remote", "add", "origin", `${this.mock.url}/${fullName}.git`);
    return folder;
  }

  // The agent (`gh-touchid agent`), which keeps sessions and elevations; its socket is run/agent-<hash>.sock

  agentSockets(): string[] {
    const folder = join(this.dir, "run");
    return existsSync(folder)
      ? readdirSync(folder)
          .filter((name) => name.startsWith("agent-") && name.endsWith(".sock"))
          .map((name) => join(folder, name))
      : [];
  }

  /** One request to this test's agent, as gh-touchid sends it; undefined when no agent answers. */
  async agentRequest(request: Record<string, unknown>): Promise<Record<string, unknown> | undefined> {
    const socket = this.agentSockets()[0];
    return socket ? agentRequest(socket, request) : undefined;
  }

  /** Ends every agent this test started: `lock` over its socket, then SIGKILL to whatever still holds it. */
  async stopAgents(): Promise<void> {
    for (const socket of this.agentSockets()) {
      await agentRequest(socket, { op: "lock" });
      for (let attempt = 0; attempt < 100 && existsSync(socket); attempt++) {
        await Bun.sleep(20);
      }
      if (existsSync(socket)) {
        const holders = Bun.spawnSync(["/usr/sbin/lsof", "-t", socket]).stdout.toString().split(/\s+/).filter(Boolean);
        for (const pid of holders) {
          process.kill(Number(pid), "SIGKILL");
        }
        unlinkSync(socket);
      }
    }
  }

  async [Symbol.asyncDispose](): Promise<void> {
    for (const running of this.started) {
      running.kill("SIGKILL");
    }
    await Promise.all(this.started.map((running) => running.finished.catch(() => undefined)));
    await this.stopAgents();
    await this.mock.stop();
    rmSync(this.dir, { recursive: true, force: true });
  }
}

/** One newline-terminated JSON request to an agent's socket and its reply; undefined on any failure. */
function agentRequest(socket: string, request: Record<string, unknown>): Promise<Record<string, unknown> | undefined> {
  const { promise, resolve } = Promise.withResolvers<Record<string, unknown> | undefined>();
  let reply = "";
  const connection = createConnection(socket);
  const finish = (value: Record<string, unknown> | undefined) => {
    connection.destroy();
    resolve(value);
  };
  connection.setTimeout(5000, () => finish(undefined));
  connection.on("error", () => finish(undefined));
  connection.on("connect", () => connection.write(`${JSON.stringify(request)}\n`));
  connection.on("data", (data) => {
    reply += data.toString();
    const end = reply.indexOf("\n");
    if (end >= 0) {
      try {
        finish(JSON.parse(reply.slice(0, end)));
      } catch {
        finish(undefined);
      }
    }
  });
  connection.on("end", () => finish(undefined));
  return promise;
}

function prefixedLines(text: string, prefix: string): string[] {
  return text
    .split("\n")
    .filter((line) => line.startsWith(prefix))
    .map((line) => line.slice(prefix.length));
}

function shellQuote(text: string): string {
  return `'${text.replaceAll("'", `'\\''`)}'`;
}

/** A TCP port on 127.0.0.1 that was free a moment ago. */
function freePort(): number {
  const listener = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
  const port = listener.port;
  listener.stop(true);
  return port;
}
