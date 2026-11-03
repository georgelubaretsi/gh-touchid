// The interfaces contract: every operation is declared once and listed by `--help --json` as an MCP tool with valid
// schemas; wrong input (missing, unknown, mistyped, outside the enum, too large) is refused with exit 2 and a JSON
// `invalid_input` error before anything happens; `--json` output fits the declared output schema; `--input -` and
// `--input <file>` are the same input; exit statuses are 0, 2 and 1, and gh's own passes through.

import { describe, expect, test } from "bun:test";
import { existsSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { lastError, TestEnv } from "./support/harness";
import { type JsonSchema, schemaProblems, valueProblems } from "./support/schema";

interface Tool {
  name: string;
  title: string;
  description: string;
  inputSchema: JsonSchema;
  outputSchema: JsonSchema;
  annotations: Record<string, unknown>;
  _meta?: Record<string, string>;
}

const operations = [
  "app_create", "app_add", "app_login", "app_remove", "account_add", "account_remove", "gh", "git_setup",
  "git_credential", "as", "session", "elevate", "status", "setup", "lock", "version", "reader_create", "reader_add",
  "reader_remove",
];

/** The command words of an operation, as the adapter makes them. */
function words(name: string): string[] {
  if (name === "git_credential") {
    return ["git", "credential"];
  }
  return ["gh", "as"].includes(name) ? [name] : name.split("_");
}

/** An input each operation takes, so that one changed field is the only thing wrong. */
const validInputs: Record<string, Record<string, unknown>> = {
  app_create: { owner: "acme" },
  app_add: { owner: "acme", client_id: "Iv1abc", client_secret: "secret" },
  app_login: { owner: "acme" },
  app_remove: { owner: "acme" },
  account_add: { login: "alice", token: "ghp_x" },
  account_remove: { login: "alice" },
  gh: { argv: [] },
  git_setup: { owner: "acme" },
  git_credential: { action: "store", protocol: "https", host: "github.com" },
  as: { login: "alice", argv: ["true"] },
  session: {},
  elevate: { for: "30m" },
  status: {},
  setup: {},
  lock: {},
  version: {},
  reader_create: {},
  reader_add: { app_id: 1 },
  reader_remove: {},
};

async function tools(env: TestEnv): Promise<Tool[]> {
  const result = await env.run(["--help", "--json"]);
  expect(result.status).toBe(0);
  expect(result.stderr).toBe("");
  return JSON.parse(result.stdout).tools;
}

/** A value of the wrong type for `schema`, and one more that is close but still wrong (a boolean for a number). */
function wrongValues(schema: JsonSchema): unknown[] {
  const type = Array.isArray(schema.type) ? schema.type[0] : schema.type;
  switch (type) {
    case "string":
      return [12, true, ["x"]];
    case "integer":
      return ["1", 1.5, true];
    case "boolean":
      return ["true", 1, null];
    case "array":
      return ["x", { a: 1 }];
    default:
      return [[], "x"];
  }
}

describe("--help --json", () => {
  test("lists every operation as an MCP tool with valid schemas and annotations", async () => {
    await using env = await TestEnv.create();
    const listed = await tools(env);
    expect(listed.map((tool) => tool.name).sort()).toEqual([...operations].sort());
    for (const tool of listed) {
      expect(tool.title.length).toBeGreaterThan(0);
      expect(tool.description.length).toBeGreaterThan(0);
      expect(tool.inputSchema.type).toBe("object");
      expect(tool.outputSchema.type).toBe("object");
      expect(schemaProblems(tool.inputSchema)).toEqual([]);
      expect(schemaProblems(tool.outputSchema)).toEqual([]);
      for (const hint of ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"]) {
        expect(typeof tool.annotations[hint]).toBe("boolean");
      }
    }
    // secrets are marked, in the schema and on the tool
    const secret = Object.fromEntries(listed.map((tool) => [tool.name, tool._meta?.["gh-touchid/secret"]]));
    expect(secret).toMatchObject({
      app_add: "input",
      account_add: "input",
      reader_add: "input",
      git_credential: "output",
      version: undefined,
      gh: undefined,
    });
    const byName = Object.fromEntries(listed.map((tool) => [tool.name, tool]));
    const properties = (tool: string) => byName[tool]!.inputSchema.properties as Record<string, JsonSchema>;
    expect(properties("account_add").token!.writeOnly).toBe(true);
    expect(properties("app_add").client_secret!.writeOnly).toBe(true);
    expect((byName.git_credential!.outputSchema.properties as Record<string, JsonSchema>).password!.writeOnly).toBe(
      true,
    );
    // `help --json` is the same
    expect(JSON.parse((await env.run(["help", "--json"])).stdout).tools).toEqual(listed);
  });

  test("the operations' words reach each operation, as `help` shows them", async () => {
    await using env = await TestEnv.create();
    const help = await env.run(["help"]);
    for (const name of operations) {
      expect(help.stdout).toContain(`gh-touchid ${words(name).join(" ")}`);
    }
  });
});

describe("wrong input", () => {
  for (const name of operations) {
    test(`${name}: missing, unknown, mistyped and out-of-enum fields are refused with exit 2, doing nothing`, async () => {
      await using env = await TestEnv.create();
      const tool = (await tools(env)).find((candidate) => candidate.name === name)!;
      const schema = tool.inputSchema;
      const properties = schema.properties as Record<string, JsonSchema>;
      const valid = validInputs[name]!;
      const cases: [string, Record<string, unknown>][] = [
        ["unknown_field_x", { ...valid, unknown_field_x: 1 }],
      ];
      for (const required of (schema.required as string[] | undefined) ?? []) {
        const { [required]: _, ...rest } = valid;
        cases.push([required, rest]);
      }
      for (const [field, property] of Object.entries(properties)) {
        for (const value of wrongValues(property)) {
          cases.push([field, { ...valid, [field]: value }]);
        }
        if (Array.isArray(property.enum)) {
          cases.push([field, { ...valid, [field]: "not-one-of-them" }]);
        }
        if (property.type === "array") {
          cases.push([field, { ...valid, [field]: [12] }]);
        }
      }
      for (const [field, input] of cases) {
        const result = await env.run(["--json", "--input", "-", ...words(name)], { stdin: JSON.stringify(input) });
        expect(result.status, `${name} ${JSON.stringify(input)}`).toBe(2);
        expect(result.stdout).toBe("");
        const error = lastError(result.stderr);
        expect(error.code).toBe("invalid_input");
        expect(error.message).toContain(field);
        expect(result.auth).toEqual([]);
        expect(result.open).toEqual([]);
      }
      // nothing happened: no request, no gh, no item, no log, no Git setting, no agent
      expect(env.mock.requests).toEqual([]);
      expect(env.ghEvents()).toEqual([]);
      expect(existsSync(join(env.dir, "secrets"))).toBe(false);
      expect(env.accessLog()).toEqual([]);
      expect(await Bun.file(join(env.home, ".gitconfig")).text()).toBe("");
      expect(env.agentSockets()).toEqual([]);
    });
  }

  test("a secret's value never appears in an error", async () => {
    await using env = await TestEnv.create();
    const input = { login: "alice", token: "ghp_SECRETVALUE", extra: 1 };
    const result = await env.run(["--json", "--input", "-", "account", "add"], { stdin: JSON.stringify(input) });
    expect(result.status).toBe(2);
    expect(result.stderr).not.toContain("SECRETVALUE");
  });

  test("input over 1 MiB, input that is not one JSON object, and --input with arguments are refused", async () => {
    await using env = await TestEnv.create();
    const large = JSON.stringify({ argv: ["x".repeat((1 << 20) + 10)] });
    const tooLarge = await env.run(["--json", "--input", "-", "gh"], { stdin: large });
    expect(tooLarge.status).toBe(2);
    expect(lastError(tooLarge.stderr)).toMatchObject({ code: "invalid_input" });
    expect(lastError(tooLarge.stderr).message).toContain("1 MiB");
    for (const stdin of ["[]", "12", "not json", ""]) {
      const result = await env.run(["--json", "--input", "-", "version"], { stdin });
      expect(result.status).toBe(2);
      expect(lastError(result.stderr).code).toBe("invalid_input");
    }
    const withArguments = await env.run(["--json", "--input", "-", "git", "setup", "acme"], { stdin: "{}" });
    expect(withArguments.status).toBe(2);
    expect(lastError(withArguments.stderr).code).toBe("usage");
    const missingFile = await env.run(["--json", "--input", join(env.dir, "nothing.json"), "version"]);
    expect(missingFile.status).toBe(2);
    expect(env.ghEvents()).toEqual([]);
    expect(env.mock.requests).toEqual([]);
  });

  test("the command line goes through the same checks", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["--json", "git", "setup", "not an owner"]);
    expect(result.status).toBe(2);
    expect(lastError(result.stderr)).toMatchObject({ code: "invalid_input" });
    const text = await env.run(["git", "setup", "not an owner"]);
    expect(text.status).toBe(2);
    expect(text.stderr).toStartWith("gh-touchid: input error: owner:");
    expect(await Bun.file(join(env.home, ".gitconfig")).text()).toBe("");
  });
});

describe("--json output", () => {
  test("fits each operation's output schema", async () => {
    await using env = await TestEnv.create();
    const byName = Object.fromEntries((await tools(env)).map((tool) => [tool.name, tool]));
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    env.seedAccount("bob", "ghp_bob");
    const repository = env.makeRepository("acme/widgets");
    const runs: [string, string[], { stdin?: string; cwd?: string }][] = [
      ["version", ["version"], {}],
      ["status", ["status"], {}],
      ["git_setup", ["git", "setup", "acme"], {}],
      ["session", ["session"], { cwd: repository }],
      ["elevate", ["elevate", "--for", "30m", "--repo", "acme/widgets"], {}],
      ["status", ["status"], {}],
      ["lock", ["lock"], {}],
      ["gh", ["gh", "-R", "acme/widgets", "issue", "list"], {}],
      ["as", ["as", "bob", "--", "/bin/echo", "hello"], {}],
      ["account_remove", ["account", "remove", "bob"], {}],
      ["app_remove", ["app", "remove", "acme", "--yes"], {}],
    ];
    for (const [name, args, options] of runs) {
      const result = await env.run(["--json", ...args], options);
      expect(result.status, `${name}: ${result.stderr}`).toBe(0);
      const output = JSON.parse(result.stdout);
      expect(valueProblems(byName[name]!.outputSchema, output), name).toEqual([]);
    }
  });

  test("status --json and status say the same", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice" });
    const json = JSON.parse((await env.run(["--json", "status"])).stdout);
    const text = (await env.run(["status"])).stdout;
    expect(json.apps).toEqual([{ owner: "acme", login: "alice", problem: null }]);
    expect(text).toContain("Apps (owners): acme (signed in as alice)");
    expect(json.git).toEqual([{ owner: "acme", asked: [], fixes: ["gh-touchid git setup acme"] }]);
    expect(text).toContain("Git for acme asks: no credential helper; fix: gh-touchid git setup acme");
  });

  test("version: one JSON value on stdout, keys sorted, no trailing text", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["version", "--json"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/^\{"version":"[^"]+"\}\n$/);
    expect(result.stderr).toBe("");
  });

  test("gh: captured output, gh's exit status in the output and exit 0; without --json gh's status passes", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    const extra = { FAKE_GH_STDOUT: "issues\n", FAKE_GH_EXIT: "3" };
    const json = await env.run(["--json", "gh", "-R", "acme/widgets", "issue", "list"], { env: extra });
    expect(json.status).toBe(0);
    expect(JSON.parse(json.stdout)).toEqual({
      exit_code: 3,
      stdout: "issues\n",
      stderr: "",
      notices: ["to approve this whole session once, run: gh-touchid session"],
    });
    const text = await env.run(["gh", "-R", "acme/widgets", "issue", "list"], { env: extra });
    expect(text.status).toBe(3);
    expect(text.stdout).toBe("issues\n");
  });

  test("as: stdin from the input, and output over 1 MiB in a 0600 file in a 0700 folder", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("bob", "ghp_bob");
    const piped = await env.run(["--json", "--input", "-", "as"], {
      stdin: JSON.stringify({ login: "bob", argv: ["/bin/cat"], stdin: "hello" }),
    });
    expect(piped.status).toBe(0);
    expect(JSON.parse(piped.stdout)).toEqual({ exit_code: 0, stdout: "hello", stderr: "" });

    const script = "head -c 1100000 /dev/zero | tr '\\0' x; echo oops >&2; exit 4";
    const large = await env.run(["--json", "as", "bob", "--", "/bin/sh", "-c", script]);
    expect(large.status).toBe(0);
    const output = JSON.parse(large.stdout);
    expect(output.exit_code).toBe(4);
    expect(output.stderr).toBe("oops\n");
    expect(output.stdout).toBeUndefined();
    // in the user's own temporary folder, which is not $TMPDIR (as for gh's configuration folder)
    const file = output.stdout_file as string;
    try {
      expect(statSync(file).size).toBe(1100000);
      expect(statSync(file).mode & 0o777).toBe(0o600);
      expect(statSync(dirname(file)).mode & 0o777).toBe(0o700);
    } finally {
      rmSync(dirname(file), { recursive: true, force: true });
    }
  });
});

describe("--input", () => {
  test("- and a file are the same input, and the same as the command line", async () => {
    await using env = await TestEnv.create();
    const file = join(env.dir, "input.json");
    writeFileSync(file, JSON.stringify({ owner: "acme" }));
    const fromFile = await env.run(["--json", "--input", file, "git", "setup"]);
    const fromStdin = await env.run(["git", "setup", "--input", "-", "--json"], { stdin: '{"owner":"acme"}' });
    const fromWords = await env.run(["--json", "git", "setup", "acme"]);
    expect(fromFile.status).toBe(0);
    expect(fromStdin.stdout).toBe(fromFile.stdout);
    expect(fromWords.stdout).toBe(fromFile.stdout);
  });

  test("global flags after gh, as and git credential belong to that program", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    const result = await env.run(["gh", "-R", "acme/widgets", "pr", "list", "--json", "number"]);
    expect(result.status).toBe(0);
    expect(env.ghCalls().map((call) => call.argv)).toEqual([["-R", "acme/widgets", "pr", "list", "--json", "number"]]);
  });

  test("a secret in a file named by --input is refused before anything is read or asked",
    async () => {
      await using env = await TestEnv.create();
      const file = join(env.dir, "input.json");
      const document = { owner: "acme", client_id: "Iv1abc", client_secret: "s3cret", open_browser: false };
      writeFileSync(file, JSON.stringify(document));
      const fromFile = await env.run(["--json", "--input", file, "app", "add"]);
      expect(fromFile.status).toBe(2);
      const error = lastError(fromFile.stderr);
      expect(error.code).toBe("invalid_input");
      expect(error.message).toContain("--input -");
      expect(fromFile.stderr).not.toContain("s3cret");
      expect(fromFile.auth).toEqual([]);
      expect(env.mock.requests).toEqual([]);
      for (const args of [["account", "add", "alice"], ["reader", "add", "--app-id", "1"]]) {
        writeFileSync(file, JSON.stringify(args[0] === "account" ? { login: "alice", token: "ghp_x" } : {
          app_id: 1,
          private_key: "-----BEGIN RSA PRIVATE KEY-----",
        }));
        const refused = await env.run(["--json", "--input", file, ...args.slice(0, 2)]);
        expect(refused.status).toBe(2);
        expect(lastError(refused.stderr).code).toBe("invalid_input");
      }
    });
});

describe("exit statuses and errors", () => {
  test("0 on success, 2 for wrong use, 1 when the command fails; with --json the error is the last stderr line",
    async () => {
      await using env = await TestEnv.create();
      expect((await env.run(["version"])).status).toBe(0);
      const usage = await env.run(["--json", "frobnicate"]);
      expect(usage.status).toBe(2);
      expect(usage.stdout).toBe("");
      expect(lastError(usage.stderr).code).toBe("usage");
      const failed = await env.run(["--json", "account", "remove", "alice"]);
      expect(failed.status).toBe(1);
      expect(lastError(failed.stderr)).toEqual({
        code: "missing_account",
        message: "no token is stored for the account alice; run `gh-touchid account add alice` first",
      });
      const text = await env.run(["account", "remove", "alice"]);
      expect(text.stderr).toBe(
        "gh-touchid: no token is stored for the account alice; run `gh-touchid account add alice` first\n",
      );
    });

  test("git credential get answers only Git's pipe: --json and --input are refused", async () => {
    await using env = await TestEnv.create();
    const json = await env.run(["--json", "git", "credential", "get"], { stdin: "protocol=https\nhost=github.com\n\n" });
    expect(json.status).toBe(1);
    expect(json.stdout).toBe("");
    expect(lastError(json.stderr).code).toBe("credential_pipe_only");
    const input = await env.run(["--input", "-", "git", "credential"], {
      stdin: JSON.stringify({ action: "get", protocol: "https", host: "github.com" }),
    });
    expect(input.status).toBe(1);
    expect(input.stdout).toBe("");
    expect(env.mock.requests).toEqual([]);
  });

  test("--no-input never asks: a hidden prompt names the stdin form instead", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["--no-input", "account", "add", "alice"], { tty: true });
    expect(result.status).toBe(2);
    expect(result.stdout).toContain("gh-touchid account add alice < token-file");
    expect(result.stdout).not.toContain("GitHub token:");
    expect(env.mock.requests).toEqual([]);
  });
});
