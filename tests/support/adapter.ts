// A client for `gh-touchid rpc` and `gh-touchid mcp` over stdio, written by hand: one JSON-RPC message per line each
// way, no npm packages. The test build execs gh-touchid-adapter (GH_TOUCHID_ADAPTER, else build/test/), which runs
// the test build once per call. Use it as
//
//   await using env = await TestEnv.create();
//   await using rpc = StdioClient.start(env, "rpc");
//   const reply = await rpc.request("version", {});
//
// Disposing it closes standard input and kills whatever is still running.

import { resolve } from "node:path";
import type { Subprocess } from "bun";
import { binary, repositoryRoot, type TestEnv } from "./harness";

/** The adapter the test build execs: GH_TOUCHID_ADAPTER, else build/test/gh-touchid-adapter. */
export const adapter = resolve(repositoryRoot, process.env.GH_TOUCHID_ADAPTER ?? "build/test/gh-touchid-adapter");

export type Message = Record<string, any>;

export class StdioClient {
  /** Every message the server wrote, in order, parsed. */
  readonly messages: Message[] = [];
  /** Lines on standard output that were not JSON (none are expected). */
  readonly garbage: string[] = [];
  stderr = "";
  private nextId = 1;
  readonly exited: Promise<number | null>;

  private constructor(readonly process: Subprocess<"pipe", "pipe", "pipe">) {
    const lines = async (stream: ReadableStream<Uint8Array>, take: (line: string) => void) => {
      const decoder = new TextDecoder();
      let pending = "";
      for await (const chunk of stream) {
        pending += decoder.decode(chunk, { stream: true });
        let newline = pending.indexOf("\n");
        while (newline >= 0) {
          take(pending.slice(0, newline));
          pending = pending.slice(newline + 1);
          newline = pending.indexOf("\n");
        }
      }
      if (pending) {
        take(pending);
      }
    };
    const stdout = lines(process.stdout, (line) => {
      if (!line.trim()) {
        return;
      }
      try {
        this.messages.push(JSON.parse(line));
      } catch {
        this.garbage.push(line);
      }
    });
    const stderr = lines(process.stderr, (line) => {
      this.stderr += `${line}\n`;
    });
    this.exited = Promise.all([stdout, stderr, process.exited]).then(() => process.exitCode);
  }

  /** `gh-touchid <mode>` in the test's clean environment, with `env` added (GH_TOUCHID_ADAPTER is set). */
  static start(env: TestEnv, mode: "rpc" | "mcp", options: { env?: Record<string, string | undefined> } = {}) {
    const process = Bun.spawn([binary, mode], {
      cwd: env.workDir,
      env: env.environment({ GH_TOUCHID_ADAPTER: adapter, ...options.env }),
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    }) as Subprocess<"pipe", "pipe", "pipe">;
    return new StdioClient(process);
  }

  /** The adapter's pid: `gh-touchid rpc|mcp` execs it, so it is the pid that was started. */
  get pid(): number {
    return this.process.pid;
  }

  /** The `AUTH: <fallback>` lines the core wrote, which the adapter passes on to its standard error. */
  get auth(): string[] {
    return this.stderr
      .split("\n")
      .filter((line) => line.startsWith("AUTH: "))
      .map((line) => line.slice("AUTH: ".length));
  }

  /** Writes one line as it is (for malformed input). */
  writeLine(line: string): void {
    this.process.stdin.write(`${line}\n`);
    this.process.stdin.flush();
  }

  send(message: Message): void {
    this.writeLine(JSON.stringify(message));
  }

  notify(method: string, params?: Message): void {
    this.send(params === undefined ? { jsonrpc: "2.0", method } : { jsonrpc: "2.0", method, params });
  }

  /** Sends a request and returns its id without waiting. */
  begin(method: string, params?: Message, id: number | string = this.nextId++): number | string {
    this.send(params === undefined ? { jsonrpc: "2.0", id, method } : { jsonrpc: "2.0", id, method, params });
    return id;
  }

  /** Sends a request and waits for its response. */
  async request(method: string, params?: Message, timeout = 15_000): Promise<Message> {
    const id = this.begin(method, params);
    return this.response(id, timeout);
  }

  /** The response to `id`, waiting for it. */
  response(id: number | string | null, timeout = 15_000): Promise<Message> {
    return this.waitFor((message) => "id" in message && message.id === id && !("method" in message), timeout);
  }

  /** The first message (in order) that satisfies `test`, waiting up to `timeout` ms. */
  async waitFor(test: (message: Message) => boolean, timeout = 15_000): Promise<Message> {
    const deadline = Date.now() + timeout;
    for (;;) {
      const found = this.messages.find(test);
      if (found) {
        return found;
      }
      if (this.process.exitCode !== null || this.process.signalCode !== null) {
        await this.exited;
        const late = this.messages.find(test);
        if (late) {
          return late;
        }
        throw new Error(`the adapter exited (${this.process.exitCode}) first:\n${this.stderr}`);
      }
      if (Date.now() > deadline) {
        throw new Error(`no such message within ${timeout} ms; got ${JSON.stringify(this.messages)}\n${this.stderr}`);
      }
      await Bun.sleep(20);
    }
  }

  /** MCP's handshake: initialize, then notifications/initialized; the initialize result. */
  async initialize(): Promise<Message> {
    const reply = await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "gh-touchid-tests", version: "1" },
    });
    this.notify("notifications/initialized");
    return reply;
  }

  /** The adapter's child processes: the calls of the core still running. */
  children(): number[] {
    const result = Bun.spawnSync(["/usr/bin/pgrep", "-P", String(this.pid)]);
    return result.stdout.toString().split(/\s+/).filter(Boolean).map(Number);
  }

  /** Closes standard input, as a client that is done does, and waits for the adapter to exit. */
  async close(): Promise<number | null> {
    this.process.stdin.end();
    return this.exited;
  }

  async [Symbol.asyncDispose](): Promise<void> {
    for (const child of this.children()) {
      try {
        process.kill(child, "SIGKILL");
      } catch {
        // already gone
      }
    }
    if (this.process.exitCode === null && this.process.signalCode === null) {
      this.process.kill("SIGKILL");
    }
    await this.exited.catch(() => undefined);
  }
}

/** Whether a process with `pid` exists. */
export function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Waits until `pid` has exited; fails after `timeout` ms. */
export async function waitForExit(pid: number, timeout = 10_000): Promise<void> {
  const deadline = Date.now() + timeout;
  while (isRunning(pid)) {
    if (Date.now() > deadline) {
      throw new Error(`process ${pid} still runs after ${timeout} ms`);
    }
    await Bun.sleep(20);
  }
}
