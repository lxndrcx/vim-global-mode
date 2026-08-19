///|
/// The dashboard page, embedded in the binary so the server stays a single
/// file with no asset paths to get wrong.
let dashboard_html : String =
  #|<!doctype html>
  #|<html lang="en">
  #|<head>
  #|<meta charset="utf-8">
  #|<meta name="viewport" content="width=device-width, initial-scale=1">
  #|<title>Global Mode</title>
  #|<style>
  #|  :root {
  #|    --bg: #f4f4f5; --fg: #18181b; --muted: #71717a;
  #|    --card: #ffffff; --border: #e4e4e7;
  #|  }
  #|  @media (prefers-color-scheme: dark) {
  #|    :root {
  #|      --bg: #09090b; --fg: #fafafa; --muted: #a1a1aa;
  #|      --card: #18181b; --border: #27272a;
  #|    }
  #|  }
  #|  * { box-sizing: border-box; }
  #|  body {
  #|    margin: 0; padding: 2rem 1rem; background: var(--bg); color: var(--fg);
  #|    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  #|    display: flex; flex-direction: column; align-items: center; gap: 1.5rem;
  #|    min-height: 100vh;
  #|  }
  #|  h1 {
  #|    margin: 0; font-size: .8rem; font-weight: 600; letter-spacing: .18em;
  #|    text-transform: uppercase; color: var(--muted);
  #|  }
  #|  #mode {
  #|    width: 100%; max-width: 40rem; padding: 3rem 1rem; border-radius: 1rem;
  #|    text-align: center; font-size: clamp(2.5rem, 12vw, 5rem); font-weight: 700;
  #|    letter-spacing: .1em; color: #09090b; background: #a1a1aa;
  #|    transition: background-color .12s ease;
  #|  }
  #|  #mode.n { background: #a1a1aa; }
  #|  #mode.i { background: #4ade80; }
  #|  #mode.v, #mode.V, #mode.b { background: #c084fc; }
  #|  #mode.R { background: #f87171; }
  #|  #mode.c { background: #fbbf24; }
  #|  #mode.t { background: #38bdf8; }
  #|  #blame { font-size: 1.1rem; text-align: center; min-height: 1.6em; }
  #|  #blame b { font-weight: 700; }
  #|  .card {
  #|    width: 100%; max-width: 40rem; background: var(--card);
  #|    border: 1px solid var(--border); border-radius: .75rem; padding: 1rem 1.25rem;
  #|  }
  #|  .card h2 {
  #|    margin: 0 0 .75rem; font-size: .7rem; letter-spacing: .16em;
  #|    text-transform: uppercase; color: var(--muted); font-weight: 600;
  #|  }
  #|  ul { list-style: none; margin: 0; padding: 0; }
  #|  li {
  #|    display: flex; justify-content: space-between; gap: 1rem;
  #|    padding: .35rem 0; border-top: 1px solid var(--border);
  #|  }
  #|  li:first-child { border-top: 0; }
  #|  li span:last-child { color: var(--muted); }
  #|  .meta {
  #|    display: flex; gap: 1.5rem; justify-content: center;
  #|    font-size: .8rem; color: var(--muted);
  #|  }
  #|  .empty { color: var(--muted); }
  #|  #link { color: var(--muted); font-size: .75rem; text-decoration: none; }
  #|  #link:hover { color: var(--fg); }
  #|</style>
  #|</head>
  #|<body>
  #|  <h1>Global Mode</h1>
  #|  <div id="mode" class="n">&mdash;</div>
  #|  <div id="blame"></div>
  #|  <div class="meta">
  #|    <span>seq <b id="seq">0</b></span>
  #|    <span id="conn">connecting&hellip;</span>
  #|  </div>
  #|  <div class="card">
  #|    <h2>Subject to it</h2>
  #|    <ul id="roster"></ul>
  #|  </div>
  #|  <a id="link" href="/api/state">/api/state</a>
  #|<script>
  #|(function () {
  #|  var modeEl = document.getElementById("mode");
  #|  var blameEl = document.getElementById("blame");
  #|  var seqEl = document.getElementById("seq");
  #|  var connEl = document.getElementById("conn");
  #|  var rosterEl = document.getElementById("roster");
  #|  var backoff = 500;
  #|
  #|  function render(s) {
  #|    modeEl.textContent = s.label;
  #|    modeEl.className = s.mode;
  #|    seqEl.textContent = s.seq;
  #|    blameEl.innerHTML = s.seq > 0
  #|      ? "<b></b> did this".replace("<b></b>", "<b>" + esc(s.by) + "</b>")
  #|      : "nobody has done anything yet";
  #|    rosterEl.innerHTML = "";
  #|    if (!s.clients.length) {
  #|      var li = document.createElement("li");
  #|      li.className = "empty";
  #|      li.textContent = "no editors connected";
  #|      rosterEl.appendChild(li);
  #|      return;
  #|    }
  #|    s.clients.forEach(function (c) {
  #|      var li = document.createElement("li");
  #|      var who = document.createElement("span");
  #|      who.textContent = c.user;
  #|      var where = document.createElement("span");
  #|      where.textContent = c.host;
  #|      li.appendChild(who);
  #|      li.appendChild(where);
  #|      rosterEl.appendChild(li);
  #|    });
  #|  }
  #|
  #|  function esc(s) {
  #|    var d = document.createElement("div");
  #|    d.textContent = s;
  #|    return d.innerHTML;
  #|  }
  #|
  #|  function connect() {
  #|    var proto = location.protocol === "https:" ? "wss:" : "ws:";
  #|    var ws = new WebSocket(proto + "//" + location.host + "/ws");
  #|    ws.onopen = function () {
  #|      connEl.textContent = "live";
  #|      backoff = 500;
  #|    };
  #|    ws.onmessage = function (e) {
  #|      try { render(JSON.parse(e.data)); } catch (_) {}
  #|    };
  #|    ws.onclose = function () {
  #|      connEl.textContent = "reconnecting…";
  #|      setTimeout(connect, backoff);
  #|      backoff = Math.min(backoff * 2, 10000);
  #|    };
  #|    ws.onerror = function () { ws.close(); };
  #|  }
  #|  connect();
  #|})();
  #|</script>
  #|</body>
  #|</html>
