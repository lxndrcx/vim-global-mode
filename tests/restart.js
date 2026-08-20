#!/usr/bin/env node
// Regression test for the three ways a client can be talked out of listening
// to its own server.
//
// All three share one root: `M.state.seq` is a high-water mark, and anything
// that raises it above what the real server can produce silences that server
// permanently. The client keeps saying "online" the whole time, which is what
// makes it so unpleasant -- there is no error, no reconnect, no symptom except
// an editor that has quietly stopped following anybody.
//
//   1. A server restart. Seq counts from zero again, so every frame the new
//      instance sends is below the mark left by the old one. `go_offline` used
//      to reset mode, blame, id, peers and every timer -- but not the counter.
//
//   2. A forged frame from any other socket. Nothing checked the source
//      address, so any local process that knew the port could set the mode and
//      leave the seq beyond the server's reach.
//
//   3. A stale refresh at an equal seq. Adopting "at least as new" let a frame
//      that left the server before this editor's own change arrived drag the
//      editor back into the mode it had just left.
//
// None of these are reachable from tests/two-editors.sh: they need a server
// that restarts, a second sender, or a frame held back by hand.
//
// Usage: node tests/restart.js <path-to-nvim> [port]

const dgram = require("node:dgram");
const frames = require("./frames.js");
const { spawn, execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const NVIM = process.argv[2] || "nvim";
const PORT = Number(process.argv[3] || 41097);
const REPO = path.resolve(__dirname, "..");
const work = fs.mkdtempSync(path.join(os.tmpdir(), "global-mode-restart-"));
const sock = path.join(work, "nvim.sock");

fs.writeFileSync(
  path.join(work, "init.lua"),
  `vim.opt.runtimepath:prepend("${REPO}")\n` +
    `require("global-mode").setup({ host = "127.0.0.1", port = ${PORT}, user = "probe", notify = true })\n`
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
const globalMode = () => rpc(["--remote-expr", `luaeval("require('global-mode').mode()")`]);
const seq = () => rpc(["--remote-expr", `luaeval("require('global-mode.client').state.seq")`]);

// A server that can be restarted: the socket and its state are rebuilt, and
// `seq` starts from zero again exactly as a fresh process would.
let server = null;
let peer = null;
let current = { mode: "n", seq: 0 };
let keepalive = null;

const send = (f) => {
  if (server && peer) server.send(frames.encode(f), peer.port, peer.address);
};

const start = () =>
  new Promise((resolve) => {
    server = dgram.createSocket("udp4");
    server.on("message", (buf, rinfo) => {
      const f = frames.decode(buf);
      if (!f) return;
      peer = rinfo;
      if (f.kind === "HELLO") {
        send({ type: frames.T.CHALLENGE, token: 0x0123456789abcdefn });
      } else if (f.kind === "JOIN") {
        send({
          type: frames.T.WELCOME,
          id: 1,
          mode: current.mode,
          seq: current.seq,
          user: "server",
        });
      }
    });
    keepalive = setInterval(() => {
      send({ type: frames.T.STATE, mode: current.mode, seq: current.seq, user: "bob", wantsPong: false });
    }, 1000);
    keepalive.unref();
    server.bind(PORT, "127.0.0.1", resolve);
  });

const stop = () =>
  new Promise((resolve) => {
    clearInterval(keepalive);
    const s = server;
    server = null;
    peer = null;
    s.close(resolve);
  });

const push = (mode, s) => {
  current = { mode, seq: s };
  send({ type: frames.T.STATE, mode, seq: s, user: "bob" });
};

(async () => {
  await start();

  const nvim = spawn(NVIM, ["--headless", "--listen", sock, "-u", path.join(work, "init.lua"), "-n"], {
    stdio: "ignore",
  });

  for (let i = 0; i < 50 && !fs.existsSync(sock); i++) await sleep(100);
  await sleep(1200);

  try {
    check("editor connected", peer !== null, true);

    // Run a while, so the client carries a high-water mark worth wedging on.
    push("i", 1000);
    await sleep(800);
    check("the editor follows a long-running server", globalMode(), "i");
    check("and holds its counter", seq(), "1000");

    // ---- 1. The restart ----
    await stop();
    // Longer than LIVENESS_MS, so the client gives up and re-handshakes.
    await sleep(8000);
    check("silence takes the editor offline", globalMode(), "vim.NIL");

    current = { mode: "n", seq: 0 };
    await start();
    await sleep(3000);

    check("a restarted server is followed again", globalMode(), "n");
    check("and the stale high-water mark is gone", seq(), "0");

    // A mode change from the restarted instance must land, at a seq far below
    // the one the client used to hold.
    push("v", 1);
    await sleep(800);
    check("its first real change is applied", rpc(["--remote-expr", "mode(1)"]), "v");

    // ---- 2. The forged frame ----
    const spoofer = dgram.createSocket("udp4");
    await new Promise((r) => spoofer.bind(0, "127.0.0.1", r));
    await new Promise((r) =>
      spoofer.send(
        frames.encode({ type: frames.T.STATE, mode: "R", seq: 2n ** 60n, user: "mallory" }),
        peer.port,
        peer.address,
        r
      )
    );
    await sleep(800);

    check("a frame from another socket is ignored", globalMode(), "v");
    check("and cannot poison the counter", seq(), "1");
    spoofer.close();

    // The real server still owns the editor afterwards.
    push("i", 2);
    await sleep(800);
    check("the real server is still in charge", globalMode(), "i");

    // ---- 3. The stale equal-seq refresh ----
    // Re-send the mode the editor was in *before* the last change, at the seq
    // the client already holds -- an in-flight refresh that crossed with a
    // local change. It must not drag the editor backwards.
    send({ type: frames.T.STATE, mode: "v", seq: 2, user: "bob" });
    await sleep(800);
    check("an equal-seq stale refresh is ignored", globalMode(), "i");

    // ---- The fast-context notify ----
    // Going offline notifies from a timer callback, where nvim_echo is
    // forbidden. It used to raise E5560 and abandon the rest of the tick.
    const errs = rpc(["--remote-expr", 'execute("messages")']);
    check("losing the server raised no E5560", /E5560/.test(errs), false);
  } finally {
    console.log(failures === 0 ? "\nall checks passed" : `\n${failures} check(s) failed`);
    nvim.kill();
    if (server) await stop();
    try {
      fs.rmSync(work, { recursive: true, force: true });
    } catch {}
  }
  process.exit(failures === 0 ? 0 : 1);
})();
