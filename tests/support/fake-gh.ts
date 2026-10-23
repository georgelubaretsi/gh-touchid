// The gh that test builds run (GH_TOUCHID_GH points at a wrapper that runs this file with Bun). It appends one JSON
// line per event to $FAKE_GH_LOG:
//   {"kind":"reference", ...}  `gh help reference`: prints $FAKE_GH_REFERENCE and exits with $FAKE_GH_REFERENCE_EXIT
//   {"kind":"run", ...}        any other command: what it got (see GhCall in harness.ts)
//   {"kind":"signal", ...}     a signal that ended it in sleep mode
// Then it prints $FAKE_GH_STDOUT and exits with $FAKE_GH_EXIT (default 0), or with FAKE_GH_MODE=sleep waits until
// SIGINT, SIGQUIT, SIGHUP or SIGTERM and exits with 128 + the signal's number.

import { appendFileSync, existsSync, readdirSync, readFileSync } from "node:fs";
import { constants } from "node:os";

const environment = process.env;
const argv = process.argv.slice(2);

function record(event: Record<string, unknown>): void {
  if (environment.FAKE_GH_LOG) {
    appendFileSync(environment.FAKE_GH_LOG, `${JSON.stringify({ ...event, pid: process.pid, at: Date.now() })}\n`);
  }
}

const configDir = environment.GH_CONFIG_DIR ?? null;
const common = {
  argv,
  hasGhToken: "GH_TOKEN" in environment,
  ghToken: environment.GH_TOKEN ?? null,
  githubToken: environment.GITHUB_TOKEN ?? null,
  ghEnterpriseToken: environment.GH_ENTERPRISE_TOKEN ?? null,
  configDir,
  configDirExists: configDir !== null && existsSync(configDir),
  configDirEntries: configDir !== null && existsSync(configDir) ? readdirSync(configDir) : null,
  ghPager: environment.GH_PAGER ?? null,
  ghRepo: environment.GH_REPO ?? null,
  cwd: process.cwd(),
};

if (argv[0] === "help" && argv[1] === "reference") {
  record({ kind: "reference", ...common });
  if (environment.FAKE_GH_REFERENCE) {
    process.stdout.write(readFileSync(environment.FAKE_GH_REFERENCE));
  }
  process.exit(Number(environment.FAKE_GH_REFERENCE_EXIT ?? 0));
}

// in sleep mode the handlers come first: a test signals gh as soon as it sees the `run` record
if (environment.FAKE_GH_MODE === "sleep") {
  for (const name of ["SIGINT", "SIGQUIT", "SIGHUP", "SIGTERM"] as const) {
    process.on(name, () => {
      record({ kind: "signal", signal: name });
      process.exit(128 + constants.signals[name]);
    });
  }
  setInterval(() => {}, 1 << 30);
}
record({ kind: "run", ...common });
if (environment.FAKE_GH_STDOUT) {
  process.stdout.write(environment.FAKE_GH_STDOUT);
}
if (environment.FAKE_GH_MODE !== "sleep") {
  process.exit(Number(environment.FAKE_GH_EXIT ?? 0));
}
