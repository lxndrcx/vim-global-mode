#!/usr/bin/env node
// Fake editors for testing the global-mode server without Neovim.
//
//   node scripts/fake-client.js --clients 3
//       Open N clients, have one change mode, and assert that the change
//       reaches every other client and never comes back to the originator.
//
//   node scripts/fake-client.js --watch --user alex
//       Open a single client and print everything the server sends, so you
//       can watch real Neovim instances drive the global mode.

const net = require("node:net");

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(name);
  return i === -1 ? fallback : argv[i + 1];
};
const has = (name) => argv.includes(name);

const HOST = flag("--host", "127.0.0.1");
const PORT = Number(flag("--port", "7777"));
const HTTP_PORT = Number(flag("--http-port", "7778"));

/** One fake editor: a TCP socket that speaks newline-delimited JSON. */
class FakeEditor {
  constructor(user) {
    this.user = user;
    this.received = [];
    this.socket = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = net.createConnection({ host: HOST, port: PORT }, () => {
        this.send({ t: "hello", user: this.user, host: "test", nvim: "0.11.0" });
        resolve(this);
      });
      this.socket.setEncoding("utf8");
      this.socket.on("error", reject);

      // TCP hands us arbitrary chunks, so reassemble lines before parsing.
      let buffer = "";
      this.socket.on("data", (chunk) => {
        buffer += chunk;
        let nl;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, nl);
          buffer = buffer.slice(nl + 1);
          if (!line) continue;
          let msg;
          try {
            msg = JSON.parse(line);
          } catch {
            console.error(`${this.user}: unparseable line ${line}`);
            continue;
          }
          if (msg.t === "ping") {
            this.send({ t: "pong" });
            continue;
          }
          this.received.push(msg);
          if (this.onMessage) this.onMessage(msg);
        }
      });
    });
  }

  send(msg) {
    this.socket.write(JSON.stringify(msg) + "\n");
  }

  setMode(mode) {
    this.send({ t: "mode", mode });
  }

  modes() {
    return this.received.filter((m) => m.t === "mode");
  }

  close() {
    if (this.socket) this.socket.destroy();
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchState() {
  const res = await fetch(`http://${HOST}:${HTTP_PORT}/api/state`);
  return res.json();
}

let failures = 0;
function check(label, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures++;
  const mark = ok ? "ok  " : "FAIL";
  console.log(`${mark} ${label}`);
  if (!ok) console.log(`       expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

async function watch() {
  const editor = new FakeEditor(flag("--user", "watcher"));
  editor.onMessage = (msg) => console.log(JSON.stringify(msg));
  await editor.connect();
  console.log(`watching as ${editor.user}; ctrl-c to stop`);
  process.stdin.resume();
}

async function runTests() {
  const n = Number(flag("--clients", "3"));
  const names = Array.from({ length: n }, (_, i) => `user${i + 1}`);

  // Everything below is asserted relative to the server's state on arrival,
  // so the run is correct against a long-lived server, not just a fresh one.
  const initial = await fetchState();
  const baseSeq = initial.seq;
  const baseClients = initial.clients.length;

  const editors = [];
  for (const name of names) {
    editors.push(await new FakeEditor(name).connect());
  }
  await sleep(150);

  const [first, ...others] = editors;

  // Every client should have been welcomed exactly once.
  check(
    "each client receives one welcome",
    editors.map((e) => e.received.filter((m) => m.t === "welcome").length),
    editors.map(() => 1),
  );

  // The core promise: one client's mode change lands on all the others.
  first.setMode("i");
  await sleep(150);

  check("originator does not receive its own change", first.modes().length, 0);
  check(
    "every other client receives it",
    others.map((e) => e.modes().length),
    others.map(() => 1),
  );
  check(
    "and it is the right mode",
    others.map((e) => e.modes()[0]?.mode),
    others.map(() => "i"),
  );
  check(
    "attributed to the right user",
    others.map((e) => e.modes()[0]?.by),
    others.map(() => "user1"),
  );

  let state = await fetchState();
  check("the dashboard agrees on the mode", state.mode, "i");
  check("the dashboard agrees on the label", state.label, "INSERT");
  check("the dashboard agrees on the blame", state.by, "user1");
  check("seq advanced by exactly one", state.seq, baseSeq + 1);
  check("the roster gained our clients", state.clients.length, baseClients + n);
  check(
    "the roster carries our usernames",
    names.filter((name) => state.clients.some((c) => c.user === name)).sort(),
    [...names].sort(),
  );

  // The loop-guard backstop: re-reporting the mode already in force must be
  // a no-op, so a client whose guard fails cannot start a ping-pong storm.
  const before = state.seq;
  for (const e of editors) e.setMode("i");
  await sleep(150);
  state = await fetchState();
  check("re-reporting the current mode does not advance seq", state.seq, before);
  check(
    "and generates no further traffic",
    others.map((e) => e.modes().length),
    others.map(() => 1),
  );

  // A different client taking over.
  others[0].setMode("V");
  await sleep(150);
  state = await fetchState();
  check("a second client can change the mode", state.mode, "V");
  check("blame moves with it", state.by, "user2");
  check("seq advanced again", state.seq, before + 1);

  // An invalid mode must be ignored rather than accepted or fatal.
  first.send({ t: "mode", mode: "no" });
  first.send({ t: "mode", mode: "bogus" });
  first.socket.write("this is not json\n");
  await sleep(150);
  state = await fetchState();
  check("invalid modes are ignored", state.mode, "V");
  check("garbage does not disconnect anyone", state.clients.length, baseClients + n);

  // The per-line cap. Without it, one client sending bytes with no newline
  // burned 100% of a core and 56 MB of RSS; nothing else in any suite touches
  // the server's framing, so this is the only thing standing between that
  // regression and a release.
  const flooder = await new FakeEditor("flooder").connect();
  await sleep(150);
  const withFlooder = (await fetchState()).clients.length;
  let dropped = false;
  flooder.socket.on("close", () => { dropped = true; });
  flooder.socket.on("error", () => { dropped = true; });
  flooder.socket.write("A".repeat(64 * 1024));   // no newline, ever
  await sleep(1500);
  check("an over-long line disconnects that client", dropped, true);

  state = await fetchState();
  check("and the server survives it", typeof state.mode, "string");
  check("and the other editors are untouched", state.clients.length, withFlooder - 1);

  // A mode change still propagates afterwards, so the server is not just alive
  // but working.
  const beforeFlood = state.seq;
  first.setMode("R");
  await sleep(200);
  state = await fetchState();
  check("the server still serves after a flood", state.seq, beforeFlood + 1);

  // Disconnect handling.
  const leaving = editors.pop();
  leaving.close();
  await sleep(200);
  state = await fetchState();
  check("a departed client leaves the roster", state.clients.length, baseClients + n - 1);

  for (const e of editors) e.close();
  await sleep(100);

  console.log(failures === 0 ? "\nall checks passed" : `\n${failures} check(s) failed`);
  process.exit(failures === 0 ? 0 : 1);
}

(has("--watch") ? watch() : runTests()).catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
