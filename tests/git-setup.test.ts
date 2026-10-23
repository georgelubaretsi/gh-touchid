// `git setup <owner>` in the test's own global Git configuration (HOME and GIT_CONFIG_GLOBAL inside its folder, never
// the user's ~/.gitconfig), and what `status` says of Git afterwards.

import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { binary, TestEnv } from "./support/harness";

const section = "credential.https://github.com/acme";

/** The helper `git setup` writes: this test build by its real path, quoted as gh-touchid quotes it for the shell. */
function expectedHelper(): string {
  const path = realpathSync(binary);
  const quoted = /^[A-Za-z0-9/._+\-@%:,=]+$/.test(path) ? path : `'${path.replaceAll("'", `'\\''`)}'`;
  return `!${quoted} git credential`;
}

async function git(env: TestEnv, ...args: string[]): Promise<string> {
  const result = await env.exec([join(env.dir, "bin", "git"), ...args]);
  return result.stdout;
}

async function getAll(env: TestEnv, key: string): Promise<string[]> {
  const output = await git(env, "config", "--global", "--get-all", key);
  return output === "" ? [] : output.replace(/\n$/, "").split("\n");
}

describe("git setup", () => {
  test("Git in the tests reads and writes only the test's own global configuration", async () => {
    await using env = await TestEnv.create();
    const environment = env.environment();
    expect(environment.HOME).toStartWith(env.dir);
    expect(environment.GIT_CONFIG_GLOBAL).toStartWith(env.dir);
    expect(environment.GIT_CONFIG_NOSYSTEM).toBe("1");
    await git(env, "config", "--global", "test.marker", "yes");
    const origin = await git(env, "config", "--global", "--show-origin", "--get", "test.marker");
    expect(origin).toBe(`file:${environment.GIT_CONFIG_GLOBAL}\tyes\n`);
  });

  test("writes the empty helper, this gh-touchid's helper and useHttpPath, keeping the section's other settings", async () => {
    await using env = await TestEnv.create();
    const realConfig = join(homedir(), ".gitconfig");
    const before = existsSync(realConfig) ? readFileSync(realConfig, "utf8") : undefined;

    await git(env, "config", "--global", `${section}.username`, "alice");
    await git(env, "config", "--global", "--add", `${section}.helper`, "osxkeychain");
    await git(env, "config", "--global", `${section}.useHttpPath`, "false");
    await git(env, "config", "--global", "credential.helper", "cache");

    const result = await env.run(["git", "setup", "acme"]);
    expect(result.status).toBe(0);
    expect(result.auth).toEqual([]);
    expect(await getAll(env, `${section}.helper`)).toEqual(["", expectedHelper()]);
    expect(await getAll(env, `${section}.usehttppath`)).toEqual(["true"]);
    expect(await getAll(env, `${section}.username`)).toEqual(["alice"]);
    expect(await getAll(env, "credential.helper")).toEqual(["cache"]);

    // running it again changes nothing
    expect((await env.run(["git", "setup", "acme"])).status).toBe(0);
    expect(await getAll(env, `${section}.helper`)).toEqual(["", expectedHelper()]);
    expect(await getAll(env, `${section}.username`)).toEqual(["alice"]);

    expect(existsSync(realConfig) ? readFileSync(realConfig, "utf8") : undefined).toBe(before);
  });

  test("replaces the helper of gh-touchid 0.3 (`git-credential`)", async () => {
    await using env = await TestEnv.create();
    const old = expectedHelper().replace(/ git credential$/, " git-credential");
    await git(env, "config", "--global", "--add", `${section}.helper`, "");
    await git(env, "config", "--global", "--add", `${section}.helper`, old);
    await git(env, "config", "--global", `${section}.useHttpPath`, "true");
    expect((await env.run(["git", "setup", "acme"])).status).toBe(0);
    expect(await getAll(env, `${section}.helper`)).toEqual(["", expectedHelper()]);
  });

  test("keeps the owner as written, since Git compares URL paths case-sensitively", async () => {
    await using env = await TestEnv.create();
    expect((await env.run(["git", "setup", "Acme"])).status).toBe(0);
    expect(await getAll(env, "credential.https://github.com/Acme.helper")).toEqual(["", expectedHelper()]);
  });

  test("takes exactly one owner", async () => {
    await using env = await TestEnv.create();
    for (const args of [["git", "setup"], ["git", "setup", "a", "b"], ["git", "setup", "not an owner"]]) {
      expect((await env.run(args)).status).toBe(2);
    }
    expect(await git(env, "config", "--global", "--list")).toBe("");
  });
});

describe("status of Git", () => {
  function seedAcme(env: TestEnv): void {
    env.seedOwner({ owner: "acme", login: "alice" });
  }

  test("after git setup: this gh-touchid only", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    expect((await env.run(["status"])).stdout).toMatch(
      /^Git for acme asks: no credential helper; fix: gh-touchid git setup acme$/m,
    );
    expect((await env.run(["git", "setup", "acme"])).status).toBe(0);
    expect((await env.run(["status"])).stdout).toMatch(/^Git for acme asks: this gh-touchid only$/m);
  });

  test("with only the helper of gh-touchid 0.3: another gh-touchid, and the git setup fix", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    const old = expectedHelper().replace(/ git credential$/, " git-credential");
    await git(env, "config", "--global", "--add", `${section}.helper`, "");
    await git(env, "config", "--global", "--add", `${section}.helper`, old);
    await git(env, "config", "--global", `${section}.useHttpPath`, "true");
    expect((await env.run(["status"])).stdout).toMatch(
      /^Git for acme asks: another gh-touchid; fix: gh-touchid git setup acme$/m,
    );
  });

  test("with another helper before this one: both named, and the fix", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    await git(env, "config", "--global", "--add", `${section}.helper`, "osxkeychain");
    await git(env, "config", "--global", "--add", `${section}.helper`, expectedHelper());
    expect((await env.run(["status"])).stdout).toMatch(
      /^Git for acme asks: osxkeychain, this gh-touchid; fix: gh-touchid git setup acme$/m,
    );
  });
});
