#!/bin/bash
#
# SessionStart hook (async): the binaries this repo is worked on with.
#
# A remote session starts from a fresh container with neither: no Neovim, no
# StyLua. Both track whatever is current, matching ci.yml, which pins nothing
# either -- so a session and CI agree with each other even though neither is
# reproducible against an old commit.
#
# The MoonBit toolchain is deliberately not installed here. The server moved to
# lxndrcx/vim-global-mode-server-moonbit, and the one test that needs a running
# server -- tests/two-editors.sh -- gets one from `scripts/build-server.sh`,
# which installs MoonBit itself if you ask it to. Most work in this repository
# is Lua and needs neither.
#
# This runs asynchronously, so the session starts immediately and the downloads
# land behind it. See the race note below before using anything installed here.

# NOT `set -e`. Both installs below are independent, and this hook runs async
# with its output retained nowhere: under `set -e` a single transient failure
# -- one fetch through a flaky proxy -- aborted every remaining step and said
# nothing, leaving a half-installed toolchain that looked identical to a
# working one. Each step now reports its own failure and the rest carry on.
set -uo pipefail

echo '{"async": true, "asyncTimeout": 300000}'

# Local checkouts have their own toolchains; leave them alone.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

LOCAL_BIN="$HOME/.local/bin"
STATUS_FILE="$HOME/.cache/global-mode-binaries.status"
FAILURES=()

# Run one install step in a subshell so its own failures abort only itself.
step() {
  local name="$1"
  shift
  if ( set -e; "$@" ); then
    return 0
  fi
  echo "FAILED: $name" >&2
  FAILURES+=("$name")
  return 1
}

# Publish PATH before installing anything, not after. This hook is async, so
# the session may read $CLAUDE_ENV_FILE while the downloads are still running;
# writing the exports first means PATH is correct whenever that read happens,
# and the binaries appear underneath it a few seconds later.
# Written once: a warm container starts many sessions, and appending
# unconditionally grew both the file and PATH itself on every one.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  path_line="export PATH=\"$LOCAL_BIN:\$PATH\""
  if ! grep -qxF "$path_line" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    echo "$path_line" >> "$CLAUDE_ENV_FILE"
  fi
fi

export PATH="$LOCAL_BIN:$PATH"
mkdir -p "$LOCAL_BIN" "$HOME/.local/share"

case "$(uname -m)" in
  x86_64)          NVIM_ARCH="linux-x86_64"; STYLUA_ARCH="linux-x86_64"  ;;
  aarch64 | arm64) NVIM_ARCH="linux-arm64";  STYLUA_ARCH="linux-aarch64" ;;
  *) echo "Unsupported architecture $(uname -m); skipping nvim and stylua." >&2
     NVIM_ARCH=""; STYLUA_ARCH="" ;;
esac

# --- Neovim: every test in tests/ ------------------------------------------
install_nvim() {
  curl -fsSL "https://github.com/neovim/neovim/releases/download/stable/nvim-${NVIM_ARCH}.tar.gz" \
    | tar -xz -C "$HOME/.local/share"
  ln -sfn "$HOME/.local/share/nvim-${NVIM_ARCH}/bin/nvim" "$LOCAL_BIN/nvim"
}

if [ -n "$NVIM_ARCH" ] && [ ! -x "$LOCAL_BIN/nvim" ]; then
  echo "Installing Neovim..."
  step "nvim" install_nvim
else
  echo "Neovim already present."
fi

# --- StyLua: the lua/, plugin/ and tests/ formatter ------------------------
install_stylua() {
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/stylua.zip" \
    "https://github.com/JohnnyMorganz/StyLua/releases/latest/download/stylua-${STYLUA_ARCH}.zip"
  # Only the binary: `unzip -d "$LOCAL_BIN"` would drop every member of the
  # archive into a directory that is on PATH.
  unzip -oq "$tmp/stylua.zip" stylua -d "$LOCAL_BIN"
  chmod +x "$LOCAL_BIN/stylua"
  rm -rf "$tmp"
}

if [ -n "$STYLUA_ARCH" ] && [ ! -x "$LOCAL_BIN/stylua" ]; then
  echo "Installing StyLua..."
  step "stylua" install_stylua
else
  echo "StyLua already present."
fi

# A marker the session can read. This hook's output is retained nowhere, so a
# partial install is otherwise indistinguishable from a complete one.
mkdir -p "$(dirname "$STATUS_FILE")"
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "ok $(date -u +%FT%TZ)" > "$STATUS_FILE"
  echo "Binaries ready."
else
  printf 'failed %s %s\n' "$(date -u +%FT%TZ)" "${FAILURES[*]}" > "$STATUS_FILE"
  echo "Binaries INCOMPLETE -- failed: ${FAILURES[*]} (see $STATUS_FILE)" >&2
fi
