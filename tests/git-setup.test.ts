// `git setup <owner>` in the test's own global Git configuration (HOME and GIT_CONFIG_GLOBAL inside its folder, never
// the user's ~/.gitconfig), what `status` says of Git afterwards, and what `session` warns of.

import { describe, expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
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

  test("a global helper after the section: both named, and the git setup fix", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    expect((await env.run(["git", "setup", "acme"])).status).toBe(0);
    await git(env, "config", "--global", "--add", "credential.helper", "osxkeychain");
    expect((await env.run(["status"])).stdout).toMatch(
      /^Git for acme asks: this gh-touchid, osxkeychain; fix: gh-touchid git setup acme$/m,
    );
  });

  test("overridden in the repository's own configuration: its file and the command that removes it", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    expect((await env.run(["git", "setup", "acme"])).status).toBe(0);
    const repository = env.makeRepository("acme/widgets");
    const old = expectedHelper().replace(/ git credential$/, " git-credential");
    await git(env, "-C", repository, "config", "--local", "--add", "credential.helper", "");
    await git(env, "-C", repository, "config", "--local", "--add", "credential.helper", old);

    const status = await env.run(["status"], { cwd: repository });
    expect(status.status).toBe(0);
    const line = status.stdout.split("\n").find((text) => text.startsWith("Git for acme"));
    expect(line).toBe(
      "Git for acme asks: another gh-touchid; fix: git config --local --unset-all credential.helper "
        + `(set in ${repository}/.git/config)`,
    );
    // outside the repository Git is as git setup left it
    expect((await env.run(["status"])).stdout).toMatch(/^Git for acme asks: this gh-touchid only$/m);

    // the command as printed fixes it
    const command = /fix: (git config [^(]+) \(set in /.exec(line!)![1].split(" ");
    const removed = await env.exec([join(env.dir, "bin", "git"), ...command.slice(1)], { cwd: repository });
    expect(removed.status).toBe(0);
    expect((await env.run(["status"], { cwd: repository })).stdout).toMatch(
      /^Git for acme asks: this gh-touchid only$/m,
    );
  });

  test("overridden in the repository with Git not set up: the repository's fix, then git setup", async () => {
    await using env = await TestEnv.create();
    seedAcme(env);
    const repository = env.makeRepository("acme/widgets");
    await git(env, "-C", repository, "config", "--local", "credential.helper", "osxkeychain");
    expect((await env.run(["status"], { cwd: repository })).stdout).toContain(
      "Git for acme asks: osxkeychain; fix: git config --local --unset-all credential.helper "
        + `(set in ${repository}/.git/config), then gh-touchid git setup acme\n`,
    );
  });
});

describe("session warnings", () => {
  /**
   * A copy of the test build laid out as a release installs it: bin/gh-touchid and the gh wrapper libexec/bin/gh,
   * with Git set up for acme by that copy. PATH has the wrapper's folder first unless `foreignGh`, which puts the
   * fake gh's folder before it.
   */
  async function install(env: TestEnv, options: { foreignGh?: boolean } = {}) {
    const root = join(env.dir, "inst");
    const installed = join(root, "bin", "gh-touchid");
    const wrapperFolder = join(root, "libexec", "bin");
    mkdirSync(join(root, "bin"), { recursive: true });
    mkdirSync(wrapperFolder, { recursive: true });
    copyFileSync(binary, installed);
    chmodSync(installed, 0o755);
    writeFileSync(join(wrapperFolder, "gh"), `#!/bin/sh\nexec '${installed}' gh "$@"\n`);
    chmodSync(join(wrapperFolder, "gh"), 0o755);
    const folders = [wrapperFolder, join(root, "bin"), join(env.dir, "bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
    const path = (options.foreignGh ? [join(env.dir, "fake"), ...folders] : folders).join(":");
    const run = (args: string[]) => env.exec([installed, ...args], { env: { PATH: path } });
    expect((await run(["git", "setup", "acme"])).status).toBe(0);
    return { run, wrapperFolder };
  }

  function warnings(stderr: string): string[] {
    return stderr.split("\n").filter((line) => line.startsWith("Warning: "));
  }

  test("none when Git asks this gh-touchid only and gh on PATH is its wrapper", async () => {
    await using env = await TestEnv.create();
    const { run } = await install(env);
    const result = await run(["session", "--repo", "acme/widgets"]);
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("for acme/widgets: pending");
    expect(warnings(result.stderr)).toEqual([]);
  });

  test("an owner whose Git asks another helper: what it asks and the fix; the session still registers", async () => {
    await using env = await TestEnv.create();
    const { run } = await install(env);
    await git(env, "config", "--global", "--add", "credential.helper", "osxkeychain");
    const result = await run(["session", "--repo", "acme/widgets", "--repo", "acme/gadgets"]);
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("pending");
    expect(warnings(result.stderr)).toEqual([
      "Warning: Git for acme asks: this gh-touchid, osxkeychain; fix: gh-touchid git setup acme",
    ]);
  });

  test("another gh first on PATH: which one and the fix", async () => {
    await using env = await TestEnv.create();
    const { run, wrapperFolder } = await install(env, { foreignGh: true });
    const result = await run(["session", "--repo", "acme/widgets"]);
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("pending");
    expect(warnings(result.stderr)).toEqual([
      `Warning: gh on PATH: ${join(env.dir, "fake", "gh")}, another gh; `
        + `fix: add \`export PATH="${wrapperFolder}:$PATH"\` to your shell's profile, `
        + "or `alias gh='gh-touchid gh'` for your own shell only",
    ]);
  });
});
