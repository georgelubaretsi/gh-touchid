// `app create` and `app set`: the refusals that come before any App is stored or any Touch ID is asked.

import { describe, expect, test } from "bun:test";
import { browse } from "./support/browser";
import { services, TestEnv } from "./support/harness";

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
    expect(empty.status).toBe(1);
    const twice = await env.run(["app", "create", "acme", "--name", "a", "--name", "b"]);
    expect(twice.status).toBe(1);
    const unknown = await env.run(["app", "create", "acme", "--private"]);
    expect(unknown.status).toBe(2);
    for (const result of [empty, twice, unknown]) {
      expect(result.open).toEqual([]);
    }
    expect(env.mock.requestsTo("POST", /apps\/new$/)).toEqual([]);
  });
});

describe("app set", () => {
  test("needs --client-id, before reading anything or asking", async () => {
    await using env = await TestEnv.create();
    for (const args of [["app", "set", "acme"], ["app", "set", "acme", "--client-id", ""]]) {
      const result = await env.run(args, { stdin: "secret\n" });
      expect(result.status).toBe(1);
      expect(result.auth).toEqual([]);
    }
    expect(env.mock.requests).toEqual([]);
    expect(env.items(services.app)).toEqual([]);
  });
});

test("app takes create or set and an owner", async () => {
  await using env = await TestEnv.create();
  for (const args of [["app"], ["app", "create"], ["app", "delete", "acme"], ["app", "create", "not an owner"]]) {
    expect((await env.run(args)).status).toBe(2);
  }
});
