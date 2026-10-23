// `git credential <get|store|erase>`, Git's credential helper. A credential goes only to Git's HTTPS transport and
// never to a terminal; these tests cover the refusals, which come before any token is looked up or minted.

import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { binary, TestEnv } from "./support/harness";

function credentialRequest(env: TestEnv): string {
  return `protocol=http\nhost=${env.mock.host}\npath=acme/widgets.git\n\n`;
}

function seedOwnerAndAccount(env: TestEnv): void {
  env.seedApp("acme", { clientId: "Iv23liacme", clientSecret: "secret", slug: "acme-agent" });
  env.seedAccount("alice", "ghp_alice");
}

describe("git credential get", () => {
  test("refuses to write a credential to a terminal", async () => {
    await using env = await TestEnv.create();
    seedOwnerAndAccount(env);
    for (const extra of [{}, { GH_TOUCHID_AS: "alice" }]) {
      const result = await env.run(["git", "credential", "get"], { tty: true, env: extra });
      expect(result.status).toBe(1);
      expect(result.stdout).toContain("terminal");
      expect(result.stdout).not.toContain("password=");
      expect(result.auth).toEqual([]);
    }
    expect(env.mock.requests).toEqual([]);
  });

  test("refuses a caller that is not Git's HTTPS transport, and logs it", async () => {
    await using env = await TestEnv.create();
    seedOwnerAndAccount(env);
    for (const extra of [{}, { GH_TOUCHID_AS: "alice" }]) {
      const result = await env.run(["git", "credential", "get"], { stdin: credentialRequest(env), env: extra });
      expect(result.status).toBe(1);
      expect(result.stdout).toBe("");
      expect(result.stderr).toContain("git-remote-https");
      expect(result.auth).toEqual([]);
    }
    expect(env.accessLog().filter((line) => line.includes("refused a Git credential"))).toHaveLength(2);
    expect(env.mock.requests).toEqual([]);
  });

  test("refuses `git credential fill`, which is Git but not its transport", async () => {
    await using env = await TestEnv.create();
    seedOwnerAndAccount(env);
    const git = join(env.dir, "bin", "git");
    const helper = `!'${binary}' git credential`;
    const configured = await env.exec([git, "config", "--global", "credential.helper", helper]);
    expect(configured.status).toBe(0);

    const result = await env.exec([git, "credential", "fill"], {
      stdin: credentialRequest(env),
      env: { GH_TOUCHID_AS: "alice" },
    });
    expect(result.status).not.toBe(0);
    expect(result.stdout).not.toContain("password=");
    expect(result.auth).toEqual([]);
    expect(env.accessLog().some((line) => line.includes("refused a Git credential"))).toBe(true);
    expect(env.mock.requests).toEqual([]);
  });
});

describe("git credential store and erase", () => {
  for (const operation of ["store", "erase"]) {
    test(`${operation} reads its input and succeeds silently`, async () => {
      await using env = await TestEnv.create();
      seedOwnerAndAccount(env);
      const result = await env.run(["git", "credential", operation], {
        stdin: `${credentialRequest(env).trimEnd()}\nusername=x-access-token\npassword=ghs_old\n\n`,
      });
      expect(result).toMatchObject({ status: 0, stdout: "", stderr: "" });
      expect(env.accessLog()).toEqual([]);
      expect(env.mock.requests).toEqual([]);
    });
  }

  test("anything else is a usage error", async () => {
    await using env = await TestEnv.create();
    for (const args of [["git", "credential"], ["git", "credential", "fill"], ["git", "credential", "get", "extra"]]) {
      const result = await env.run(args);
      expect(result.status).toBe(2);
      expect(result.stdout).toBe("");
    }
  });
});
