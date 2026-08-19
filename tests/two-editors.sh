#!/usr/bin/env bash
# End-to-end: two real Neovim instances sharing one modal state.
#
# Drives them over RPC so keystrokes go through Neovim's real input loop --
# the only way genuine mode transitions happen. Starts its own server on its
# own port so the result never depends on ambient state.
#
# Usage: tests/two-editors.sh [path-to-server-binary]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_BIN="${1:-$HERE/server/_build/native/release/build/cmd/main/main.exe}"
[ -x "$SERVER_BIN" ] || SERVER_BIN="$HERE/server/_build/native/debug/build/cmd/main/main.exe"
WORK="$(mktemp -d)"
PORT=$(( (RANDOM % 10000) + 20000 ))
HTTP_PORT=$((PORT + 1))

if [ ! -x "$SERVER_BIN" ]; then
  echo "no server binary at $SERVER_BIN — run 'moon build --target native' in server/ first"
  exit 1
fi
command -v nvim >/dev/null || { echo "nvim not on PATH"; exit 1; }

fails=0
check() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected '$expected', got '$actual'"
    fails=$((fails + 1))
  fi
}

cleanup() {
  for name in alex sam; do
    [ -f "$WORK/$name.pid" ] && kill "$(cat "$WORK/$name.pid")" 2>/dev/null
  done
  [ -f "$WORK/server.pid" ] && kill "$(cat "$WORK/server.pid")" 2>/dev/null
  # On failure the logs are the only evidence, and $WORK is a mktemp dir that
  # is about to vanish -- so print them before it does.
  if [ "${fails:-0}" -ne 0 ]; then
    for log in "$WORK"/*.log; do
      [ -f "$log" ] || continue
      echo "----- $(basename "$log") -----"
      tail -40 "$log"
    done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

"$SERVER_BIN" --bind 127.0.0.1 --port "$PORT" --http-port "$HTTP_PORT" \
  >"$WORK/server.log" 2>&1 &
echo $! > "$WORK/server.pid"
sleep 1

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$HERE")
require("global-mode").setup({
  host = "127.0.0.1", port = $PORT, user = vim.env.GM_USER, notify = false,
})
LUA

start() {
  GM_USER="$1" nvim --headless --listen "$WORK/$1.sock" -u "$WORK/init.lua" -n \
    >"$WORK/$1.log" 2>&1 &
  echo $! > "$WORK/$1.pid"
  for _ in $(seq 50); do [ -S "$WORK/$1.sock" ] && return 0; sleep 0.1; done
  echo "FAIL $1 never came up"; exit 1
}

# Every RPC call is wrapped in a timeout: a wedged editor should fail the test,
# not hang it.
# A failed call must not return "": two failures would then compare equal and
# any check comparing one editor's value against another's would pass vacuously.
expr_on() {
  local out
  if ! out=$(timeout 5 nvim --server "$WORK/$1.sock" --remote-expr "$2" 2>/dev/null); then
    echo "<rpc-failed:$1>"
  else
    printf '%s' "$out" | tr -d '\n'
  fi
}
send_to() { timeout 5 nvim --server "$WORK/$1.sock" --remote-send "$2" 2>/dev/null; }

mode_of() { expr_on "$1" 'mode(1)'; }
global_of() { expr_on "$1" 'luaeval("require(\"global-mode\").mode()")'; }
seq_of() { expr_on "$1" 'luaeval("require(\"global-mode\").state.seq")'; }
by_of() { expr_on "$1" 'luaeval("require(\"global-mode\").state.by")'; }
connected() { expr_on "$1" 'luaeval("require(\"global-mode\").is_connected()")'; }

start alex
start sam

for _ in $(seq 50); do
  [ "$(connected alex)" = "true" ] && [ "$(connected sam)" = "true" ] && break
  sleep 0.1
done
sleep 0.5

check "both connected" "$(connected alex)$(connected sam)" "truetrue"
check "both start in normal mode" "$(mode_of alex)$(mode_of sam)" "nn"
check "both agree the global mode is normal" "$(global_of alex)$(global_of sam)" "nn"

base_seq=$(seq_of alex)

# The whole point of the plugin: alex presses i, sam suffers for it.
send_to alex 'i'
sleep 1
check "alex is in insert mode" "$(mode_of alex)" "i"
check "sam was dragged into insert mode" "$(mode_of sam)" "i"
check "sam knows the global mode is insert" "$(global_of sam)" "i"
check "sam knows who to blame" "$(by_of sam)" "alex"
check "one keypress advanced seq by exactly one" "$(seq_of sam)" "$((base_seq + 1))"

# And back out again, driven from the other side.
send_to sam '<C-\><C-n>'
sleep 1
check "sam returned to normal mode" "$(mode_of sam)" "n"
check "alex was dragged back to normal" "$(mode_of alex)" "n"
check "blame moved to sam" "$(by_of alex)" "sam"
check "seq advanced by exactly one again" "$(seq_of alex)" "$((base_seq + 2))"

# Visual mode propagates, and can be left again -- the originator's own view of
# the global mode has to stay current for this to work.
send_to alex 'v'
sleep 1
check "sam follows into visual mode" "$(mode_of sam)" "v"
# `seq` is assigned by the server and never echoed to whoever caused the
# change, so it is the other editor that sees it advance.
check "seq advanced once for visual" "$(seq_of sam)" "$((base_seq + 3))"

send_to alex '<C-\><C-n>'
sleep 1
check "alex can leave visual mode" "$(mode_of alex)" "n"
check "sam follows back out of visual" "$(mode_of sam)" "n"
check "seq advanced once leaving visual" "$(seq_of sam)" "$((base_seq + 4))"

# A cross-mode transition between two real editors. This is a worthwhile
# end-to-end check, but be clear about what it does NOT cover: it cannot reach
# the loop guard's transit rule. A real editor walking i->v emits `n` then `v`,
# so the recipient is stepped through normal and the transit never fires --
# deleting the transit rule leaves all of these checks green. Only
# tests/loop-guard.js, which pushes a mode directly, protects that.
send_to alex 'i'
sleep 1
check "both are in insert before the cross-mode test" "$(mode_of alex)$(mode_of sam)" "ii"
cross_seq=$(seq_of sam)
send_to alex '<C-\><C-n>v'
sleep 1.5
check "alex reached visual" "$(mode_of alex)" "v"
check "sam was dragged from insert to visual" "$(mode_of sam)" "v"
# alex made exactly two genuine changes (i->n, n->v). Anything beyond that is
# the recipient echoing changes that were forced on it.
check "no echo storm: seq advanced by exactly two" "$(seq_of sam)" "$((cross_seq + 2))"
send_to alex '<C-\><C-n>'
sleep 1

# The neovim#22263 guard: operator-pending must never reach the wire.
before_seq=$(seq_of sam)
send_to alex 'd'
sleep 1
check "operator-pending did not change the global mode" "$(global_of sam)" "n"
check "operator-pending did not advance seq" "$(seq_of sam)" "$before_seq"
check "sam was not disturbed by it" "$(mode_of sam)" "n"
send_to alex '<Esc>'
sleep 0.5

# Replace mode, for a mode with a multi-character Neovim name.
send_to alex 'R'
sleep 1
check "sam follows into replace mode" "$(mode_of sam)" "R"
send_to alex '<C-\><C-n>'
sleep 1

# A late joiner adopts whatever mode is already in force.
send_to alex 'i'
sleep 1
GM_USER=kim nvim --headless --listen "$WORK/kim.sock" -u "$WORK/init.lua" -n \
  >"$WORK/kim.log" 2>&1 &
echo $! > "$WORK/kim.pid"
for _ in $(seq 50); do [ -S "$WORK/kim.sock" ] && break; sleep 0.1; done
sleep 1.5
check "a late joiner is conscripted into the current mode" "$(mode_of kim)" "i"
kill "$(cat "$WORK/kim.pid")" 2>/dev/null
send_to alex '<C-\><C-n>'
sleep 0.5

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit "$fails"
