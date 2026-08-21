#!/usr/bin/env node
// Regression test for heartbeat resync.
//
// An editor can drift out of step with the server in several ways that nothing
// else corrects: a frame discarded from a full outbox, two editors changing
// mode at the same instant so the winner never learns its own `seq`, an apply
// dropped by the circuit breaker. Each of those used to be permanent, because
// the protocol had no resync at all — the server only ever announced *changes*,
// so a client that missed one stayed wrong forever.
//
// The heartbeat now carries the authoritative mode. This drives a real Neovim
// into a state that disagrees with the server and asserts the next beat fixes
// it, without the client echoing anything back.
//
// Usage: node tests/resync.js <path-to-nvim> [port]

const dgram = require("node:dgram");
const frames = require("./frames.js");
const { spawn, execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const NVIM = process.argv[2] || "nvim";
const PORT = Number(process.argv[3] || 41199);
const REPO = path.resolve(__dirname, "..");
const work = fs.mkdtempSync(path.join(os.tmpdir(), "global-mode-resync-"));
const sock = path.join(work, "nvim.sock");

fs.writeFileSync(
  path.join(work, "init.lua"),
  `vim.opt.runtimepath:prepend("${REPO}")\n` +
    `require("global-mode").setup({ host = "127.0.0.1", port = ${PORT}, user = "probe", notify = false })\n`
);

let failures = 0;
const check = (label, actual, expected) => {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures++;
  console.log(`${ok ? "ok  " : "FAIL"} ${label}`);
  if (!ok) console.log(`       expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rpc = (args) => {
  try {
    return execFileSync(NVIM, ["--server", sock, ...args], { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
};

const received = [];
let pongs = 0;

const server = dgram.createSocket("udp4");

// Where the editor is. UDP has no connection, so "connected" here means
// nothing more than having heard from it.
let peer = null;

// The state last pushed, re-sent periodically. The real server refreshes every
// couple of seconds and the client treats silence as death, so a fake server
// that only speaks when spoken to would be declared dead mid-test.
let current = { mode: "n", seq: 0 };

const send = (f) => {
  if (peer) server.send(frames.encode(f), peer.port, peer.address);
};

server.on("message", (buf, rinfo) => {
  const f = frames.decode(buf);
  if (!f) return;
  peer = rinfo;

  if (f.kind === "HELLO") {
    // Any token at all: this stands in for the real server, and what is being
    // tested is that the client echoes back whatever it is handed.
    send({ type: frames.T.CHALLENGE, token: 0x0123456789abcdefn });
  } else if (f.kind === "JOIN") {
    send({
      type: frames.T.WELCOME,
      id: 1,
      mode: current.mode,
      seq: current.seq,
      user: "server",
    });
  } else if (f.kind === "SET_MODE") {
    received.push(f.mode);
  } else if (f.kind === "PONG") {
    pongs++;
  }
});

setInterval(() => {
  if (peer) {
    send({
      type: frames.T.STATE,
      mode: current.mode,
      seq: current.seq,
      user: "bob",
      // Deliberately not asking for a pong. This frame exists only so the
      // client keeps hearing from us; a pong request here would be counted
      // against the heartbeats the test actually sends.
      wantsPong: false,
    });
  }
}, 2000).unref();

let pingsSent = 0;
const ping = (mode, seq) => {
  pingsSent++;
  current = { mode, seq };
  send({ type: frames.T.STATE, mode, seq, user: "bob", wantsPong: true });
};

(async () => {
  await new Promise((r) => server.bind(PORT, "127.0.0.1", r));

  const nvim = spawn(NVIM, ["--headless", "--listen", sock, "-u", path.join(work, "init.lua"), "-n"], {
    stdio: "ignore",
  });

  for (let i = 0; i < 50 && !fs.existsSync(sock); i++) await sleep(100);
  await sleep(1200);

  try {
    check("editor connected", peer !== null, true);

    // Drive the editor into insert. The server drops the change on the floor,
    // so the two now disagree: editor INSERT, server still says NORMAL.
    rpc(["--remote-send", "i"]);
    await sleep(600);
    check("the editor is in insert", rpc(["--remote-expr", "mode(1)"]), "i");
    check("the change was sent", received, ["i"]);

    // A heartbeat carrying the authoritative state must pull it back.
    const before = received.length;
    ping("n", 4);
    await sleep(1500);
    check("the heartbeat corrected the editor", rpc(["--remote-expr", "mode(1)"]), "n");
    check(
      "and it agrees on the global mode",
      rpc(["--remote-expr", 'luaeval("require(\'global-mode\').mode()")']),
      "n"
    );
    check("the correction was not echoed back", received.slice(before), []);

    // A heartbeat that agrees with the editor must do nothing at all.
    const quiet = received.length;
    ping("n", 5);
    await sleep(1200);
    check("an in-step heartbeat changes nothing", rpc(["--remote-expr", "mode(1)"]), "n");
    check("and sends nothing", received.slice(quiet), []);

    // A heartbeat can also push the editor into a mode nobody asked for.
    ping("R", 6);
    await sleep(1500);
    check("a heartbeat can install a new mode", rpc(["--remote-expr", "mode(1)"]), "R");

    // A stale heartbeat must be ignored rather than dragging the editor back.
    ping("i", 2);
    await sleep(1200);
    check("a stale heartbeat is ignored", rpc(["--remote-expr", "mode(1)"]), "R");

    // Every heartbeat must be answered. The server reaps a client after two
    // unanswered pings, and an idle editor -- nobody typing, which is the
    // normal state -- sends nothing else, so a missing pong means every quiet
    // editor is dropped roughly every fifteen seconds.
    check("every heartbeat was answered", pongs, pingsSent);
  } finally {
    console.log(failures === 0 ? "\nall checks passed" : `\n${failures} check(s) failed`);
    nvim.kill();
    server.close();
    try {
      fs.rmSync(work, { recursive: true, force: true });
    } catch {}
  }
  process.exit(failures === 0 ? 0 : 1);
})();
