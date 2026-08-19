#!/bin/bash
#
# SessionStart hook for Claude Code on the web.
#
# A remote session starts from a fresh container: no MoonBit toolchain, and no
# plugin marketplaces despite `.claude/settings.json` declaring one. Declaring a
# plugin in settings does not cause a remote container to fetch it -- that only
# controls whether an already-installed plugin is enabled. So this hook installs
# both, and every step is a no-op when the work is already done.

set -euo pipefail

# Local checkouts have their own toolchain and their own plugin choices; leave
# them alone.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

MOON_BIN="$HOME/.moon/bin"

# --- MoonBit toolchain ------------------------------------------------------
# Matches .github/workflows/ci.yml, so a session and CI run the same compiler.
# The installer always fetches the current release; there is no pinned version
# to reproduce, which means a session can compile with a newer moonc than the
# one a given commit was written against.
if [ ! -x "$MOON_BIN/moon" ]; then
  echo "Installing MoonBit toolchain..."
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
else
  echo "MoonBit toolchain already present."
fi

export PATH="$MOON_BIN:$PATH"

# A fresh install ships no registry index, so resolving moonbitlang/async fails
# with "module was not found in the registry" until this runs.
if [ ! -d "$HOME/.moon/registry/index" ]; then
  echo "Fetching the MoonBit module registry..."
  moon update
else
  echo "MoonBit registry index already present."
fi

# Put moon on PATH for the session itself, not just for this script.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$MOON_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# --- MoonBit skills ---------------------------------------------------------
# moonbit-proof and moonbit-orientation are the reason this block exists: the
# outstanding work on this repo is assessing MoonBit's Why3-backed verification
# against the server, and those skills are the in-repo source of truth for it.
# Installing rather than vendoring keeps them updatable and avoids committing
# 532K of a third-party repo that ships no LICENSE file.
if command -v claude >/dev/null 2>&1; then
  if ! claude plugin marketplace list 2>/dev/null | grep -q 'moonbit-code-plugins'; then
    echo "Adding the moonbit-code-plugins marketplace..."
    claude plugin marketplace add moonbitlang/skills
  else
    echo "Marketplace moonbit-code-plugins already registered."
  fi

  if ! claude plugin list 2>/dev/null | grep -q 'moonbit-skills@moonbit-code-plugins'; then
    echo "Installing the moonbit-skills plugin..."
    claude plugin install moonbit-skills@moonbit-code-plugins
  else
    echo "Plugin moonbit-skills already installed."
  fi
else
  echo "claude CLI not on PATH; skipping MoonBit skills install." >&2
fi

echo "Session setup complete."
