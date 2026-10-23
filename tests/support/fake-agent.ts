// A program that is not gh-touchid serving an agent socket: `bun fake-agent.ts <socket> <log>`. It answers every
// request as an agent would (a newer version, nothing held) and appends each request line to <log>. It says
// `listening` on stderr once it serves.

import { appendFileSync } from "node:fs";

const [socket, log] = process.argv.slice(2);
if (!socket || !log) {
  throw new Error("usage: fake-agent.ts <socket> <log>");
}

Bun.listen({
  unix: socket,
  socket: {
    data(connection, data) {
      appendFileSync(log, data.toString());
      connection.end(`${JSON.stringify({ protocol: 1, version: "99.0.0", ok: true, sessions: [], elevations: [] })}\n`);
    },
  },
});
console.error("listening");
