// Property tests of how gh-touchid reads a gh command line, judged by the real gh that release/gh.json pins
// (build/test/pinned-gh): command lines are made from gh's own commands, aliases and flags, with flags and values put
// anywhere, and the real gh says what it does with each. It runs offline: a dummy token, every proxy pointing at a
// closed port, and throwaway configuration and data folders. A fixed seed makes every run try the same command lines.

import { describe, expect, test } from "bun:test";
import fc from "fast-check";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { repositoryRoot, TestEnv, type RunResult } from "./support/harness";

const realGh = resolve(repositoryRoot, "build/test/pinned-gh");
const marker = "DUMMY-NOT-A-TOKEN-7c1f";
const seed = 20261102;

/** gh's commands as release/gh-reference.md lists them: the words that name each, and every flag. */
function readReference(): { paths: Set<string>; names: string[]; flags: { name: string; value: boolean }[] } {
  const paths = new Set<string>();
  const names: string[] = [];
  const flags = new Map<string, boolean>();
  let current: string | undefined;
  let inAliases = false;
  for (const line of readFileSync(join(repositoryRoot, "release/gh-reference.md"), "utf8").split("\n")) {
    const heading = /^(#+) gh (.*)$/.exec(line);
    if (heading) {
      const depth = heading[1]!.length - 1;
      current = depth >= 1 ? heading[2]!.split(" ").slice(0, depth).join(" ") : undefined;
      inAliases = false;
      if (current) {
        paths.add(current);
        names.push(current);
      }
      continue;
    }
    if (current === undefined) {
      continue;
    }
    if (line === "Aliases") {
      inAliases = true;
    } else if (inAliases && line.startsWith("gh ")) {
      names.push(...line.split(", ").map((alias) => alias.replace(/^gh /, "")));
    }
    const flag = /^ +(?:-(\w), )?--([\w-]+)( [^ ])?/.exec(line);
    if (flag) {
      const takesValue = flag[3] !== undefined && !line.includes('[="');
      flags.set(`--${flag[2]}`, takesValue);
      if (flag[1]) {
        flags.set(`-${flag[1]}`, takesValue);
      }
    }
  }
  return { paths, names, flags: [...flags].map(([name, value]) => ({ name, value })) };
}

const reference = readReference();

/** Runs the real gh offline with the dummy token: its stdout and stderr together. */
function runRealGh(argv: string[]): string {
  const home = mkdtempSync(join(tmpdir(), "gh-touchid-judge-"));
  try {
    const result = Bun.spawnSync([realGh, ...argv], {
      cwd: home,
      stdin: "ignore",
      timeout: 15_000,
      env: {
        PATH: "/usr/bin:/bin",
        HOME: home,
        GH_CONFIG_DIR: home,
        XDG_CONFIG_HOME: home,
        XDG_DATA_HOME: home,
        XDG_STATE_HOME: home,
        XDG_CACHE_HOME: home,
        GH_TOKEN: marker,
        GH_PAGER: "cat",
        GH_PROMPT_DISABLED: "1",
        GH_NO_UPDATE_NOTIFIER: "1",
        GH_NO_EXTENSION_UPDATE_NOTIFIER: "1",
        GH_BROWSER: "/usr/bin/true",
        BROWSER: "/usr/bin/true",
        GH_EDITOR: "/usr/bin/true",
        GIT_TERMINAL_PROMPT: "0",
        HTTPS_PROXY: "http://127.0.0.1:9",
        HTTP_PROXY: "http://127.0.0.1:9",
        https_proxy: "http://127.0.0.1:9",
        http_proxy: "http://127.0.0.1:9",
        ALL_PROXY: "http://127.0.0.1:9",
      },
    });
    return `${result.stdout.toString()}${result.stderr.toString()}`;
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

/** The command the real gh runs for `argv`, from the USAGE line of its help: `pr checkout`, `` for gh itself; null
 * when it names none, "unknown" when gh says no command has that name. */
function commandOfRealGh(argv: string[]): string | null | "unknown" {
  const output = runRealGh([...argv, "--help"]);
  const usage = /^USAGE\n {2}gh((?: [^ \n]+)*)/m.exec(output);
  if (!usage) {
    return /unknown command/.test(output) ? "unknown" : null;
  }
  const words = usage[1]!.trim().split(" ");
  for (let length = words.length; length > 0; length--) {
    const path = words.slice(0, length).join(" ");
    if (reference.paths.has(path)) {
      return path;
    }
  }
  return "";
}

/** The command a refusal was for, by its code; or the headline of the dialog gh-touchid showed. */
function outcome(result: RunResult): { refused: string } | { headline: string } {
  const line = result.stderr.trimEnd().split("\n").at(-1) ?? "";
  try {
    const error = JSON.parse(line).error;
    if (error) {
      return { refused: error.code };
    }
  } catch {}
  const headline = /“([^”]*)”/.exec(result.auth[0] ?? "")?.[1];
  if (headline === undefined) {
    throw new Error(`neither refused nor asked: ${result.stderr}`);
  }
  return { headline };
}

/** Whether gh-touchid must refuse `command` (a path, as the real gh reads it) with `argv`. */
function banned(command: string, argv: string[]): boolean {
  const shortFlagWithT = argv.some((argument) => /^-[^-]*t/.test(argument));
  return (
    /^(alias|extension)( |$)/.test(command) ||
    (/^auth( |$)/.test(command) && (command !== "auth status" || shortFlagWithT)) ||
    argv.some((argument) => argument === "--show-token" || argument.startsWith("--show-token="))
  );
}

const values = ["github.com", "x", "acme/widgets", "-", "auth", "token", "status", "pr", "list", "5"];

/** A flag of gh's, or a flag and its value in one argument, or a lone value. */
const noise = fc.oneof(
  fc.constantFrom(...reference.flags.map((flag) => flag.name)),
  fc
    .tuple(fc.constantFrom(...reference.flags.filter((flag) => flag.name.startsWith("--"))), fc.constantFrom(...values))
    .map(([flag, value]) => `${flag.name}=${value}`),
  fc.constantFrom("-at", "-ht", "-ta", "-R", "--repo", "-h"),
  fc.constantFrom(...values),
);

/** `words` with up to `count` pieces of `noise` put anywhere, before the first word included. */
function withNoise(words: fc.Arbitrary<string[]>, count: number): fc.Arbitrary<string[]> {
  return fc.tuple(words, fc.array(fc.tuple(fc.nat(), noise), { maxLength: count })).map(([base, inserts]) => {
    const argv = [...base];
    for (const [position, piece] of inserts) {
      argv.splice(position % (argv.length + 1), 0, piece);
    }
    return argv;
  });
}

/** A command that reveals the token with up to three pieces (one or two arguments each) put anywhere, before its first
 * word too: mostly the hostname flag that `auth token` and `auth status` both take, so that the real gh still prints
 * the token, sometimes something gh refuses. Mostly `auth token`: offline, `auth status -t` fails before it prints. */
const revealing = fc
  .tuple(
    fc.oneof(
      { weight: 3, arbitrary: fc.constant(["auth", "token"]) },
      { weight: 1, arbitrary: fc.constantFrom(["auth", "status", "-t"], ["auth", "status", "--show-token"]) },
    ),
    fc.array(
      fc.tuple(
        fc.nat(),
        fc.oneof(
          {
            weight: 4,
            arbitrary: fc.constantFrom(
              ["--hostname", "github.com"],
              ["--hostname=github.com"],
              ["-h", "github.com"],
              ["-hgithub.com"],
              ["-h=github.com"],
            ),
          },
          { weight: 1, arbitrary: fc.constantFrom(["-a"], ["--title", "x"], ["-R", "acme/widgets"], ["--help"]) },
        ),
      ),
      { maxLength: 3 },
    ),
  )
  .map(([core, inserts]) => {
    const argv = [...core];
    for (const [position, piece] of inserts) {
      argv.splice(position % (argv.length + 1), 0, ...piece);
    }
    return argv;
  });

const anyCommand = withNoise(
  fc.constantFrom(...reference.names).map((name) => name.split(" ")),
  3,
);

describe("command lines judged by the real gh", () => {
  test("whatever the real gh would print the token for, gh-touchid refuses before Touch ID", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", "ghp_alice0000000000000000000000000000");
    let printed = 0;
    await fc.assert(
      fc.asyncProperty(revealing, async (argv) => {
        if (!runRealGh(argv).includes(marker)) {
          return;
        }
        printed++;
        const calls = env.ghCalls().length;
        const result = await env.run(["--json", "as", "alice", "gh", ...argv]);
        expect(result.auth).toEqual([]);
        expect(result.status).not.toBe(0);
        expect(env.ghCalls()).toHaveLength(calls);
      }),
      { seed, numRuns: 120 },
    );
    // the property says nothing unless enough of the command lines did reveal the token in the real gh
    expect(printed).toBeGreaterThan(30);
  }, 240_000);

  test("gh-touchid runs the command the real gh runs, names it in the dialog, or refuses one gh would not run", async () => {
    await using env = await TestEnv.create();
    env.seedAccount("alice", "ghp_alice0000000000000000000000000000");
    let compared = 0;
    await fc.assert(
      fc.asyncProperty(anyCommand, async (argv) => {
        const command = commandOfRealGh(argv);
        fc.pre(command !== null);
        compared++;
        const result = await env.run(["--json", "as", "alice", "gh", ...argv]);
        const read = outcome(result);
        if ("headline" in read) {
          // the dialog's headline is the command, then its first arguments up to two words
          expect(command).not.toBe("unknown");
          const expected = `gh ${command}`.trimEnd();
          expect(read.headline === expected || read.headline.startsWith(`${expected} `)).toBe(true);
          expect(banned(command as string, argv)).toBe(false);
        } else if (read.refused === "unknown_command") {
          // gh would not run a command either: no such name, or a group of commands, which only prints its help
          const group = command !== "unknown" && [...reference.paths].some((path) => path.startsWith(`${command} `));
          expect(command === "unknown" || command === "" || group).toBe(true);
        } else if (read.refused === "forbidden_command") {
          expect(banned(command as string, argv)).toBe(true);
        }
      }),
      { seed, numRuns: 150 },
    );
    expect(compared).toBeGreaterThan(75);
  }, 240_000);

  test("a NUL anywhere in a JSON argument is refused before anything runs", async () => {
    await using env = await TestEnv.create();
    const nul = fc.tuple(anyCommand, fc.nat(), fc.nat()).map(([argv, which, at]) => {
      const index = which % argv.length;
      const argument = argv[index]!;
      const position = at % (argument.length + 1);
      return argv.with(index, `${argument.slice(0, position)}\u0000${argument.slice(position)}`);
    });
    await fc.assert(
      fc.asyncProperty(nul, async (argv) => {
        const result = await env.run(["--json", "--input", "-", "gh"], { stdin: JSON.stringify({ argv }) });
        expect(result.status).toBe(2);
        expect(result.auth).toEqual([]);
        expect(outcome(result)).toEqual({ refused: "invalid_input" });
      }),
      { seed, numRuns: 40 },
    );
    expect(env.ghEvents()).toEqual([]);
  }, 120_000);
});
