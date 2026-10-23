// Help: `help`, `--help` and `-h` print every command; `help <command>` and `<command> --help|-h` print that command's
// usage alone; a wrong use of a known command prints its usage on stderr (exit 2), an unknown command everything.
// Everything after `gh` is GitHub CLI's, its `--help` included.

import { describe, expect, test } from "bun:test";
import { TestEnv } from "./support/harness";

const commands = ["app", "account", "gh", "git", "as", "session", "elevate", "status", "lock", "version", "help"];

/** The command words of the synopsis lines (`  gh-touchid <command> …`) in a usage text. */
function synopsisCommands(text: string): string[] {
  return [...text.matchAll(/^ {2}gh-touchid (\S+)/gm)].map((match) => match[1]!);
}

describe("help", () => {
  test("help, --help and -h print every command on stdout", async () => {
    await using env = await TestEnv.create();
    for (const flag of ["help", "--help", "-h"]) {
      const result = await env.run([flag]);
      expect(result.status).toBe(0);
      expect(result.stderr).toBe("");
      expect(new Set(synopsisCommands(result.stdout))).toEqual(new Set(commands));
    }
  });

  for (const command of commands) {
    test(`help ${command} and ${command} --help print only ${command}'s usage`, async () => {
      await using env = await TestEnv.create();
      const forms = [["help", command]];
      if (command !== "gh" && command !== "help") {
        forms.push([command, "--help"], [command, "-h"]);
      }
      const outputs = new Set<string>();
      for (const args of forms) {
        const result = await env.run(args);
        expect(result.status).toBe(0);
        expect(result.stderr).toBe("");
        const listed = synopsisCommands(result.stdout);
        expect(listed.length).toBeGreaterThan(0);
        expect(new Set(listed)).toEqual(new Set([command]));
        outputs.add(result.stdout);
      }
      expect(outputs.size).toBe(1);
      expect(env.ghEvents()).toEqual([]);
    });
  }

  test("--help counts only as the first argument after the command", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["status", "now", "--help"]);
    expect(result.status).toBe(2);
    expect(result.stdout).toBe("");
    expect(synopsisCommands(result.stderr)).toEqual(["status"]);
  });

  test("help with an unknown command, or more than one, is a usage error", async () => {
    await using env = await TestEnv.create();
    for (const args of [["help", "nosuch"], ["help", "app", "git"], ["--help", "user"]]) {
      const result = await env.run(args);
      expect(result.status).toBe(2);
      expect(result.stdout).toBe("");
      expect(new Set(synopsisCommands(result.stderr))).toEqual(new Set(commands));
    }
  });

  const misuses: [string, string[]][] = [
    ["app", ["app", "delete", "acme"]],
    ["account", ["account", "list"]],
    ["git", ["git", "push"]],
    ["git", ["git", "credential", "fill"]],
    ["git", ["git", "setup"]],
    ["as", ["as", "alice"]],
    ["session", ["session", "--for", "1h"]],
    ["elevate", ["elevate", "--until", "1h"]],
    ["status", ["status", "now"]],
    ["lock", ["lock", "all"]],
    ["version", ["version", "2"]],
  ];
  for (const [command, args] of misuses) {
    test(`a wrong use (${args.join(" ")}) prints only ${command}'s usage on stderr`, async () => {
      await using env = await TestEnv.create();
      const result = await env.run(args);
      expect(result.status).toBe(2);
      expect(result.stdout).toBe("");
      expect(new Set(synopsisCommands(result.stderr))).toEqual(new Set([command]));
      expect(result.auth).toEqual([]);
    });
  }

  test("an unknown command, or none, prints every command on stderr", async () => {
    await using env = await TestEnv.create();
    for (const args of [["frobnicate"], [], ["user", "add", "alice"], ["git-credential", "get"], ["git-setup", "acme"]]) {
      const result = await env.run(args);
      expect(result.status).toBe(2);
      expect(result.stdout).toBe("");
      expect(new Set(synopsisCommands(result.stderr))).toEqual(new Set(commands));
    }
  });

  test("gh --help and gh -h go to GitHub CLI, with a token as any gh use", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "alice", repositories: ["widgets"] });
    for (const flag of ["--help", "-h"]) {
      const result = await env.run(["gh", flag], {
        env: { GH_REPO: "acme/widgets", FAKE_GH_STDOUT: "GitHub CLI's help\n" },
      });
      expect(result.status).toBe(0);
      expect(result.stdout).toBe("GitHub CLI's help\n");
      expect(result.auth).toHaveLength(1);
    }
    expect(env.ghCalls().map((call) => call.argv)).toEqual([["--help"], ["-h"]]);
  });
});
