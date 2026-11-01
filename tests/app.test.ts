// `app create` and `app add`: the refusals that come before any App is stored or any Touch ID is asked; `app set`'s
// removal; and `app remove`.

import { describe, expect, test } from "bun:test";
import { browse } from "./support/browser";
import { lastError, services, TestEnv } from "./support/harness";

describe("app create", () => {
  test("an owner GitHub does not know is refused before the browser opens", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["app", "create", "nobody"]);
    expect(result.status).toBe(1);
    expect(result.open).toEqual([]);
    expect(result.auth).toEqual([]);
    expect(env.items(services.app)).toEqual([]);
  });

  for (const kind of ["User", "Organization"] as const) {
    test(`an App GitHub made for another account than the ${kind} asked for is refused, storing nothing`, async () => {
      await using env = await TestEnv.create();
      env.mock.seedUser("alice");
      if (kind === "Organization") {
        env.mock.seedOrganization("acme", ["alice"]);
      } else {
        env.mock.seedUser("acme");
      }
      env.mock.browserLogin = kind === "User" ? "acme" : "alice";
      env.mock.manifestOwner = "someone-else";

      const running = env.start(["app", "create", "acme"]);
      const [, url] = await running.waitForStderr(/^OPEN: (\S+)$/m);
      await browse(url!);
      const result = await running.finished;

      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
      expect(result.stderr).toContain("someone-else");
      expect(env.items(services.app)).toEqual([]);
      expect(env.items(services.signIn)).toEqual([]);

      // the manifest page posted the manifest to the owner's settings, coming back to gh-touchid on 127.0.0.1
      const settings = kind === "User" ? "/settings/apps/new" : "/organizations/acme/settings/apps/new";
      const posted = env.mock.requestsTo("POST", settings);
      expect(posted).toHaveLength(1);
      expect(posted[0]!.query.state).toMatch(/\S/);
      const manifest = JSON.parse(String(posted[0]!.fields?.manifest));
      expect(manifest.public).toBe(false);
      expect(manifest.redirect_url).toStartWith("http://127.0.0.1:");
      expect(manifest.name).toBe("acme-touchid");
    });
  }

  test("--no-open prints the address instead of opening it", async () => {
    await using env = await TestEnv.create();
    env.mock.seedUser("acme");
    const running = env.start(["app", "create", "acme", "--no-open", "--name", "Acme Bot"]);
    await running.waitForStderr(/http:\/\/127\.0\.0\.1:\d+\//);
    running.kill("SIGTERM");
    const result = await running.finished;
    expect(result.open).toEqual([]);
    expect(result.auth).toEqual([]);
    expect(env.items(services.app)).toEqual([]);
  });

  test("takes one non-empty --name", async () => {
    await using env = await TestEnv.create();
    env.mock.seedUser("acme");
    const empty = await env.run(["app", "create", "acme", "--name", ""]);
    expect(empty.status).toBe(2);
    const twice = await env.run(["app", "create", "acme", "--name", "a", "--name", "b"]);
    expect(twice.status).toBe(2);
    const unknown = await env.run(["app", "create", "acme", "--private"]);
    expect(unknown.status).toBe(2);
    for (const result of [empty, twice, unknown]) {
      expect(result.open).toEqual([]);
    }
    expect(env.mock.requests).toEqual([]);
  });
});

describe("app add", () => {
  test("needs --client-id, before reading anything or asking", async () => {
    await using env = await TestEnv.create();
    for (const args of [["app", "add", "acme"], ["app", "add", "acme", "--client-id", ""]]) {
      const result = await env.run(args, { stdin: "secret\n" });
      expect(result.status).toBe(2);
      expect(result.auth).toEqual([]);
      expect(result.stderr).toContain("client_id");
    }
    expect(env.mock.requests).toEqual([]);
    expect(env.items(services.app)).toEqual([]);
  });

  test("--no-input with a terminal for stdin names the stdin form instead of asking for the secret", async () => {
    await using env = await TestEnv.create();
    const result = await env.run(["--json", "--no-input", "app", "add", "acme", "--client-id", "Iv1abc"], {
      tty: true,
    });
    expect(result.status).toBe(2);
    expect(result.stdout).toContain('"code":"input_needed"');
    expect(result.stdout).toContain("gh-touchid app add acme < client-secret-file");
    expect(result.auth).toEqual([]);
    expect(env.mock.requests).toEqual([]);
  });
});

test("app set is gone: a usage error naming app add, with nothing read or asked", async () => {
  await using env = await TestEnv.create();
  const result = await env.run(["app", "set", "acme", "--client-id", "Iv1abc"], { stdin: "secret\n" });
  expect(result.status).toBe(2);
  expect(result.stdout).toBe("");
  expect(result.stderr).toContain("gh-touchid app add <owner> --client-id <client-id>");
  expect(result.stderr).not.toContain("app set");
  expect(result.auth).toEqual([]);
  expect(env.mock.requests).toEqual([]);
  const json = await env.run(["--json", "app", "set", "acme"]);
  expect(json.status).toBe(2);
  expect(lastError(json.stderr).code).toBe("usage");
});

describe("app remove", () => {
  test("without a terminal, needs --yes, removing nothing", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "acme" });
    const result = await env.run(["app", "remove", "acme"]);
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("gh-touchid app remove acme --yes");
    const json = await env.run(["--json", "app", "remove", "acme"]);
    expect(json.status).toBe(2);
    expect(lastError(json.stderr).code).toBe("confirmation_needed");
    expect(env.items(services.app)).toEqual(["acme"]);
    expect(env.items(services.signIn)).toEqual(["acme"]);
    expect(env.mock.requestsTo("DELETE", /grant$/)).toEqual([]);
  });

  test("--yes deletes the App, the sign-in and the owner's Git entries, ends the grant and names the delete page",
    async () => {
      await using env = await TestEnv.create();
      const { app } = env.seedOwner({ owner: "acme", login: "acme" });
      env.seedOwner({ owner: "beta", login: "beta" });
      expect((await env.run(["git", "setup", "acme"])).status).toBe(0);
      await env.exec(["git", "config", "--global", "credential.https://github.com/acme.username", "acme"]);

      const result = await env.run(["--json", "app", "remove", "acme", "--yes"]);
      expect(result.status).toBe(0);
      expect(result.auth).toEqual([]);
      const output = JSON.parse(result.stdout);
      expect(output).toEqual({
        owner: "acme",
        removed: { app: true, sign_in: true, git: true },
        delete_url: `${env.mock.url}/settings/apps/${app.slug}/advanced`,
      });
      expect(env.items(services.app)).toEqual(["beta"]);
      expect(env.items(services.signIn)).toEqual(["beta"]);
      expect(env.mock.requestsTo("DELETE", `/applications/${app.clientId}/grant`)).toHaveLength(1);
      const section = "credential.https://github.com/acme";
      const helpers = await env.exec(["git", "config", "--global", "--get-all", `${section}.helper`]);
      expect(helpers.stdout).toBe("");
      // the section's other settings stay
      const kept = await env.exec(["git", "config", "--global", "credential.https://github.com/acme.username"]);
      expect(kept.stdout.trim()).toBe("acme");
      expect(env.accessLog().some((line) => line.includes("removed the acme App"))).toBe(true);

      const again = await env.run(["--json", "app", "remove", "acme", "--yes"]);
      expect(again.status).toBe(1);
      expect(lastError(again.stderr).code).toBe("missing_app");
    });

  // The harness cannot type into script(1)'s terminal (a socket for stdin is refused; a file arrives before the
  // question), so only the unanswered question is tested here; without a terminal, --yes is (above).
  test("on a terminal, a question left unanswered removes nothing", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "acme" });
    const unanswered = await env.run(["app", "remove", "acme"], { tty: true });
    expect(unanswered.status).not.toBe(0);
    expect(unanswered.stdout).toContain("[y/N]");
    expect(env.items(services.app)).toEqual(["acme"]);
    expect(env.mock.requests).toEqual([]);
  });

  test("a grant GitHub does not end is reported, and the items are still removed", async () => {
    await using env = await TestEnv.create();
    env.seedOwner({ owner: "acme", login: "acme" });
    env.mock.override((request, url) =>
      request.method === "DELETE" && url.pathname.endsWith("/grant") ? new Response(null, { status: 500 }) : undefined,
    );
    const result = await env.run(["app", "remove", "acme", "--yes"]);
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("could not end your sign-in's grant");
    expect(env.items(services.app)).toEqual([]);
  });
});

test("app takes create, add, login or remove and an owner", async () => {
  await using env = await TestEnv.create();
  for (const args of [["app"], ["app", "create"], ["app", "delete", "acme"], ["app", "create", "not an owner"]]) {
    expect((await env.run(args)).status).toBe(2);
  }
});
