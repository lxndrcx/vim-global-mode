#!/usr/bin/env bash
# Fetch and build the server this plugin talks to, and print the binary's path.
#
# The server lives in its own repository -- lxndrcx/vim-global-mode-server-moonbit
# -- so nothing here needs the MoonBit toolchain until you want to run
# `tests/two-editors.sh`, which needs a real server. This script is the bridge:
# it clones (or updates) that repository under `.server/`, installs MoonBit if
# it is missing, builds, and prints the binary path on stdout.
#
#   ./scripts/build-server.sh                    # clone/update, build, print path
#   ./scripts/build-server.sh --ref some-branch  # build a particular ref
#   ./tests/two-editors.sh "$(./scripts/build-server.sh)"
#
# Everything except the final path goes to stderr, so the command substitution
# above yields the path alone.
set -euo pipefail

REPO="${GLOBAL_MODE_SERVER_REPO:-https://github.com/lxndrcx/vim-global-mode-server-moonbit}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="$HERE/.server"
REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:?--ref needs a value}"; shift 2 ;;
    -h | --help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Chatter belongs on stderr; the last line of stdout is the binary path and
# callers substitute it directly.
say() { echo "$@" >&2; }

if [ ! -d "$CHECKOUT/.git" ]; then
  say "Cloning $REPO into .server ..."
  git clone --quiet "$REPO" "$CHECKOUT"
else
  say "Updating .server ..."
  git -C "$CHECKOUT" fetch --quiet origin
fi

if [ -n "$REF" ]; then
  git -C "$CHECKOUT" checkout --quiet "$REF"
  # A tag or a bare SHA has no upstream to pull from, so only fast-forward when
  # one exists -- otherwise this fails on exactly the refs that need no update.
  git -C "$CHECKOUT" rev-parse --quiet --verify "origin/$REF" >/dev/null 2>&1 &&
    git -C "$CHECKOUT" merge --quiet --ff-only "origin/$REF"
else
  git -C "$CHECKOUT" checkout --quiet "$(git -C "$CHECKOUT" symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')"
  git -C "$CHECKOUT" merge --quiet --ff-only '@{u}'
fi

export PATH="$HOME/.moon/bin:$PATH"
if ! moon version >/dev/null 2>&1; then
  say "Installing the MoonBit toolchain ..."
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash >&2
fi

# A fresh install ships no registry index, so resolving moonbitlang/async fails
# with "module was not found in the registry" until this runs.
if [ ! -d "$HOME/.moon/registry/index" ]; then
  say "Fetching the MoonBit module registry ..."
  moon update >&2
fi

say "Building the server ..."
(cd "$CHECKOUT" && moon build --target native >&2)

BIN="$CHECKOUT/_build/native/debug/build/cmd/main/main.exe"
[ -x "$BIN" ] || { say "build produced no binary at $BIN"; exit 1; }
echo "$BIN"
