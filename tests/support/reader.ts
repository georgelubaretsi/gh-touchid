// The reader in tests: its Keychain item as test builds keep it, and the mock's App and installation behind it.
//
//   const reader = seedReader(env);            // stored, installed on readerowner with no repository
//   const result = await env.run(["gh", "-R", "someone/project", "issue", "list"]);
//   expect(env.ghCalls()[0]!.ghToken).toBe(env.mock.installationTokens()[0]!.token);

import { createPrivateKey } from "node:crypto";
import type { TestEnv } from "./harness";
import type { App, Installation } from "./mock-github";

export { keyFingerprint, newPrivateKey } from "./mock-github";

/** The reader's Keychain service; its one item's account is `reader`. */
export const readerService = "com.lubaretsi.gh-touchid.reader";
export const readerAccount = "reader";

/** The notice every reader use prints to stderr. */
export function readerNotice(slug: string): string {
  return `gh-touchid: public read-only access as ${slug}[bot]; don't create or change anything with it`;
}

export interface MockReader {
  appId: number;
  slug: string;
  owner: string;
  clientId: string;
  app: App;
  /** undefined when seeded with `installed: false`. */
  installation?: Installation;
}

/**
 * A reader App on the mock (no permissions, its own key), installed on `owner` with no repository unless
 * `installed: false`, and the reader item pointing at it, in format 1 as gh-touchid writes it.
 */
export function seedReader(
  env: TestEnv,
  options: { owner?: string; slug?: string; appId?: number; installed?: boolean } = {},
): MockReader {
  const owner = options.owner ?? "readerowner";
  env.mock.account(owner) ?? env.mock.seedUser(owner);
  const app = env.mock.seedReaderApp(owner, { slug: options.slug });
  if (options.appId !== undefined) {
    app.id = options.appId;
  }
  const installation = options.installed === false ? undefined : env.mock.seedInstallation(app, owner);
  writeReaderItem(env, { appId: app.id, privateKey: app.pem, slug: app.slug, owner });
  return { appId: app.id, slug: app.slug, owner: owner.toLowerCase(), clientId: app.clientId, app, installation };
}

/** Writes the reader item as gh-touchid stores it: secret `{appId, privateKey}`, comment `{"app", "owner"}`. */
export function writeReaderItem(
  env: TestEnv,
  item: { appId: number; privateKey: string; slug: string; owner: string },
): void {
  env.writeItem(
    readerService,
    readerAccount,
    JSON.stringify({ appId: item.appId, privateKey: item.privateKey }),
    JSON.stringify({ app: item.slug, owner: item.owner.toLowerCase() }),
  );
}

/** The stored reader item's secret, or undefined when there is none. */
export function readerItem(env: TestEnv): { appId: number; privateKey: string } | undefined {
  const secret = env.item(readerService, readerAccount);
  return secret === undefined ? undefined : JSON.parse(secret);
}

/** The stored reader item's comment, or undefined when there is none. */
export function readerComment(env: TestEnv): { app: string; owner: string } | undefined {
  const comment = env.comment(readerService, readerAccount);
  return comment === undefined ? undefined : JSON.parse(comment);
}

/** The same key as PKCS#8 (`BEGIN PRIVATE KEY`), which gh-touchid refuses. */
export function pkcs8(pem: string): string {
  return createPrivateKey(pem).export({ type: "pkcs8", format: "pem" }).toString();
}
