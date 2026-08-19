#!/bin/bash
#
# SessionStart hook (async): the binaries this repo's CI needs.
#
# A remote session starts from a fresh container with none of them: no MoonBit
# toolchain, no Neovim, no StyLua. Versions are whatever is current, matching
# ci.yml, which pins nothing either -- so a session and CI agree with each
# other even though neither is reproducible against an old commit.
#
# This runs asynchronously, so the session starts immediately and the downloads
# land behind it. See the race note below before using anything installed here.

set -euo pipefail

echo '{"async": true, "asyncTimeout": 300000}'

# Local checkouts have their own toolchains; leave them alone.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

MOON_BIN="$HOME/.moon/bin"
LOCAL_BIN="$HOME/.local/bin"

# Publish PATH before installing anything, not after. This hook is async, so
# the session may read $CLAUDE_ENV_FILE while the downloads are still running;
# writing the exports first means PATH is correct whenever that read happens,
# and the binaries appear underneath it a few seconds later.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$MOON_BIN:$LOCAL_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

export PATH="$MOON_BIN:$LOCAL_BIN:$PATH"
mkdir -p "$LOCAL_BIN" "$HOME/.local/share"

case "$(uname -m)" in
  x86_64)          NVIM_ARCH="linux-x86_64"; STYLUA_ARCH="linux-x86_64"  ;;
  aarch64 | arm64) NVIM_ARCH="linux-arm64";  STYLUA_ARCH="linux-aarch64" ;;
  *) echo "Unsupported architecture $(uname -m); skipping nvim and stylua." >&2
     NVIM_ARCH=""; STYLUA_ARCH="" ;;
esac

# --- MoonBit: server/ ------------------------------------------------------
if [ ! -x "$MOON_BIN/moon" ]; then
  echo "Installing MoonBit toolchain..."
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
else
  echo "MoonBit toolchain already present."
fi

# A fresh install ships no registry index, so resolving moonbitlang/async fails
# with "module was not found in the registry" until this runs.
if [ ! -d "$HOME/.moon/registry/index" ]; then
  echo "Fetching the MoonBit module registry..."
  moon update
else
  echo "MoonBit registry index already present."
fi

# --- Neovim: tests/protocol_spec.lua and tests/two-editors.sh --------------
if [ -n "$NVIM_ARCH" ] && [ ! -x "$LOCAL_BIN/nvim" ]; then
  echo "Installing Neovim..."
  curl -fsSL "https://github.com/neovim/neovim/releases/download/stable/nvim-${NVIM_ARCH}.tar.gz" \
    | tar -xz -C "$HOME/.local/share"
  ln -sfn "$HOME/.local/share/nvim-${NVIM_ARCH}/bin/nvim" "$LOCAL_BIN/nvim"
else
  echo "Neovim already present."
fi

# --- StyLua: the lua/, plugin/ and tests/ formatter ------------------------
if [ -n "$STYLUA_ARCH" ] && [ ! -x "$LOCAL_BIN/stylua" ]; then
  echo "Installing StyLua..."
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/stylua.zip" \
    "https://github.com/JohnnyMorganz/StyLua/releases/latest/download/stylua-${STYLUA_ARCH}.zip"
  unzip -oq "$tmp/stylua.zip" -d "$LOCAL_BIN"
  chmod +x "$LOCAL_BIN/stylua"
  rm -rf "$tmp"
else
  echo "StyLua already present."
fi

echo "Binaries ready."
