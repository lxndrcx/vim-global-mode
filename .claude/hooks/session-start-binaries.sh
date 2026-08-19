#!/bin/bash
#
# SessionStart hook (async): the binaries this repo is worked on with.
#
# A remote session starts from a fresh container with none of them: no MoonBit
# toolchain, no Neovim, no StyLua, no SMT solver. The first three track whatever
# is current, matching ci.yml, which pins nothing either -- so a session and CI
# agree with each other even though neither is reproducible against an old
# commit. Z3 is not a CI dependency at all; it is here for `moon prove`.
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

# --- Z3: the SMT solver behind `moon prove` -------------------------------
# `moon prove` is Why3-backed and dispatches to an external solver: without one
# it fails with "failed to locate any SMT solver for `moon prove`: searched for
# `alt-ergo`, `cvc5`, `z3` in PATH". Z3 is the one installed here, so the
# verification work the handover describes has a solver to run against.
#
# From apt rather than a GitHub release, unlike the tools above. Z3's release
# assets embed a glibc version in their filenames, so there is no stable
# `releases/latest/download/...` URL to derive, and api.github.com is not
# reachable from these containers to look one up. The tradeoff is age: apt
# carries 4.8.12 where upstream is well past it. If a proof turns out to need a
# newer solver, pin a release asset URL here or install `cvc5` instead --
# `moon prove` accepts either.
if ! command -v z3 >/dev/null 2>&1; then
  echo "Installing Z3..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends z3
else
  echo "Z3 already present."
fi

echo "Binaries ready."
