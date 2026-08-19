#!/bin/bash
#
# SessionStart hook (synchronous): the MoonBit skills.
#
# Declaring a plugin in `.claude/settings.json` does not make a remote container
# fetch it -- `enabledPlugins` only controls whether an already-installed plugin
# is enabled. Sessions were starting with the marketplace declared and
# `installed_plugins.json` empty, so the install has to happen here.
#
# Deliberately synchronous while the binaries hook is async: skills are read at
# session start to decide what the session knows, so installing them behind the
# session's back would be a race with no upside. It costs a few seconds on a
# cold container and nothing on a warm one.

set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not on PATH; skipping MoonBit skills install." >&2
  exit 0
fi

# moonbit-proof and moonbit-orientation are the reason this hook exists: the
# outstanding work on this repo is assessing MoonBit's Why3-backed verification
# against the server, and those skills are the source of truth for it.
# Installing rather than vendoring keeps them updatable, and avoids copying a
# third-party repo whose skills are licensed unevenly -- only moonbit-agent-guide
# (Apache-2.0) and moonbit-refactoring (MIT) carry a license of their own.
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

echo "Skills ready."
