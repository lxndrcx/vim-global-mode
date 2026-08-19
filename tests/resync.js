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

const net = require("node:net");
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
let socket = null;

const server = net.createServer((s) => {
  socket = s;
  s.setEncoding("utf8");
  let buf = "";
  s.on("error", () => {});
  s.on("data", (chunk) => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.t === "hello") {
        s.write(JSON.stringify({ t: "welcome", id: "c1", mode: "n", seq: 0, by: "server" }) + "\n");
      } else if (msg.t === "mode") {
        // Deliberately NOT acted on: this models the change being lost, which
        // is exactly the situation resync has to recover from.
        received.push(msg.mode);
      }
    }
  });
});

const ping = (mode, seq) =>
  socket.write(JSON.stringify({ t: "ping", mode, seq, by: "bob" }) + "\n");

(async () => {
  await new Promise((r) => server.listen(PORT, "127.0.0.1", r));

  const nvim = spawn(NVIM, ["--headless", "--listen", sock, "-u", path.join(work, "init.lua"), "-n"], {
    stdio: "ignore",
  });

  for (let i = 0; i < 50 && !fs.existsSync(sock); i++) await sleep(100);
  await sleep(1200);

  try {
    check("editor connected", socket !== null, true);

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
