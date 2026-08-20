#!/usr/bin/env bash
# Fetch and build the server this plugin talks to, and print the binary's path.
#
# The server lives in its own repository -- lxndrcx/vim-global-mode-server-ada
# -- so nothing here needs an Ada toolchain until you want to run
# `tests/two-editors.sh`, which needs a real server. This script is the bridge:
# it clones (or updates) that repository under `.server/`, installs GNAT if it
# is missing, builds, and prints the binary path on stdout.
#
#   ./scripts/build-server.sh                    # clone/update, build, print path
#   ./scripts/build-server.sh --ref some-branch  # build a particular ref
#   ./tests/two-editors.sh "$(./scripts/build-server.sh)"
#
# Everything except the final path goes to stderr, so the command substitution
# above yields the path alone.
set -euo pipefail

REPO="${GLOBAL_MODE_SERVER_REPO:-https://github.com/lxndrcx/vim-global-mode-server-ada}"
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

if ! command -v gprbuild >/dev/null 2>&1; then
  say "Installing GNAT and gprbuild ..."
  if [ "$(id -u)" -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      --no-install-recommends gnat gprbuild >&2
  else
    say "gprbuild is missing and this is not root; install gnat and gprbuild."
    exit 1
  fi
fi

# Release, and not merely for speed. A debug build executes the hub's
# quantified invariants on every iteration of the server loop -- about 10^9
# operations -- and is far too slow to complete a second editor's handshake.
# Release is the project's default, so this is belt and braces.
say "Building the server ..."
(cd "$CHECKOUT" && gprbuild -P global_mode.gpr -XGLOBAL_MODE_BUILD=release >&2)

BIN="$CHECKOUT/bin/global_mode"
[ -x "$BIN" ] || { say "build produced no binary at $BIN"; exit 1; }
echo "$BIN"
