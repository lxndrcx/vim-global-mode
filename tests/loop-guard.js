#!/usr/bin/env node
// Regression test for the loop guard, driven by a controlled server.
//
// Every entry in the plugin's key table begins with CTRL-\ CTRL-N, so forcing a
// non-normal mode onto an editor that is in some *other* non-normal mode passes
// through normal on the way and fires an extra ModeChanged. If the guard treats
// that transit as a genuine local change, the editor broadcasts a bogus `n` --
// yanking every other editor to normal -- and then re-broadcasts the very mode
// it was just told to enter.
//
// tests/two-editors.sh cannot reach this case: when a real editor walks i->v it
// emits `n` then `v`, so the recipient is stepped through normal and the transit
// never fires. A direct push is what triggers it, which is what the `welcome`
// path does for a late joiner, and what a backlogged client does after the
// server's outbox has discarded the intermediate frame.
//
// Usage: node tests/loop-guard.js <path-to-nvim> [port]

const dgram = require("node:dgram");
const frames = require("./frames.js");
const { spawn, execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const NVIM = process.argv[2] || "nvim";
const PORT = Number(process.argv[3] || 41099);
const REPO = path.resolve(__dirname, "..");
const work = fs.mkdtempSync(path.join(os.tmpdir(), "global-mode-loop-"));
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

const push = (mode, seq) => {
  current = { mode, seq };
  send({ type: frames.T.STATE, mode, seq, user: "bob" });
};

(async () => {
  await new Promise((r) => server.bind(PORT, "127.0.0.1", r));

  const nvim = spawn(NVIM, ["--headless", "--listen", sock, "-u", path.join(work, "init.lua"), "-n"], {
    stdio: "ignore",
  });

  for (let i = 0; i < 50 && !fs.existsSync(sock); i++) await sleep(100);
  await sleep(1200);

  const cleanup = () => {
    nvim.kill();
    server.close();
    try {
      fs.rmSync(work, { recursive: true, force: true });
    } catch {}
  };

  try {
    check("editor connected", peer !== null, true);

    // Put the editor into insert mode by its own hand; this SHOULD be reported.
    rpc(["--remote-send", "i"]);
    await sleep(600);
    check("the editor's own keypress is broadcast", received, ["i"]);
    check("the editor is in insert mode", rpc(["--remote-expr", "mode(1)"]), "i");

    // Now force VISUAL directly, with no intervening normal. This is the case
    // that used to produce a spurious `n` followed by a spurious `v`.
    const before = received.length;
    push("v", 2);
    await sleep(1500);

    check("the forced mode was applied", rpc(["--remote-expr", "mode(1)"]), "v");
    check("no frames were echoed back", received.slice(before), []);

    // And again from visual into replace, still with no intervening normal.
    const beforeReplace = received.length;
    push("R", 3);
    await sleep(1500);

    check("a second cross-mode push applied", rpc(["--remote-expr", "mode(1)"]), "R");
    check("still nothing echoed back", received.slice(beforeReplace), []);

    // A genuine local change after all that must still be reported, proving the
    // guard cleared its expectations rather than latching shut.
    const beforeGenuine = received.length;
    rpc(["--remote-send", "<C-\\><C-n>"]);
    await sleep(800);
    check("a genuine change is still broadcast afterwards", received.slice(beforeGenuine), ["n"]);

    // Two frames in ONE TCP write. Any latency, or a busy main loop, coalesces
    // reads like this. `apply` schedules its work, so when the second frame is
    // handled the first one's keys are still in the typeahead and `mode(1)`
    // still reports the OLD mode -- so a check against the current mode
    // discarded the second frame as a no-op and left the editor in the first
    // one's mode believing it was in the second's. Nothing recovered it.
    //
    // Everything else in this file pushes one frame at a time with a sleep
    // between, which is exactly why this needs writing by hand.
    const beforeBatch = received.length;
    push("i", 10);
    push("n", 11);
    await sleep(2000);
    check("a coalesced batch lands on its LAST mode", rpc(["--remote-expr", "mode(1)"]), "n");
    check(
      "and the editor agrees with the server about it",
      rpc(["--remote-expr", 'luaeval("require(\'global-mode\').mode()")']),
      "n"
    );
    check("the batch was not echoed back", received.slice(beforeBatch), []);

    // The reverse ordering too: ending on a non-normal mode.
    const beforeBatch2 = received.length;
    push("n", 12);
    push("v", 13);
    await sleep(2000);
    check("a coalesced batch ending in visual lands there", rpc(["--remote-expr", "mode(1)"]), "v");
    check("still nothing echoed", received.slice(beforeBatch2), []);
  } finally {
    console.log(failures === 0 ? "\nall checks passed" : `\n${failures} check(s) failed`);
    cleanup();
  }
  process.exit(failures === 0 ? 0 : 1);
})();
