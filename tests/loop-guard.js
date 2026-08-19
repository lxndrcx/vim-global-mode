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

const net = require("node:net");
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
        received.push(msg.mode);
      } else if (msg.t === "ping") {
        s.write(JSON.stringify({ t: "pong" }) + "\n");
      }
    }
  });
});

const push = (mode, seq) =>
  socket.write(JSON.stringify({ t: "mode", mode, seq, by: "bob", by_id: "c9" }) + "\n");

(async () => {
  await new Promise((r) => server.listen(PORT, "127.0.0.1", r));

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
    check("editor connected", socket !== null, true);

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
  } finally {
    console.log(failures === 0 ? "\nall checks passed" : `\n${failures} check(s) failed`);
    cleanup();
  }
  process.exit(failures === 0 ? 0 : 1);
})();
