#!/bin/bash
#
# SessionStart hook (async): the binaries this repo is worked on with.
#
# A remote session starts from a fresh container with none of them: no MoonBit
# toolchain, no Neovim, no StyLua, no SMT solvers. The first three track whatever
# is current, matching ci.yml, which pins nothing either -- so a session and CI
# agree with each other even though neither is reproducible against an old
# commit. The solvers are not CI dependencies at all; they are here for `moon
# prove`.
#
# This runs asynchronously, so the session starts immediately and the downloads
# land behind it. See the race note below before using anything installed here.

# NOT `set -e`. Every install below is independent, and this hook runs async
# with its output retained nowhere: under `set -e` a single transient failure
# -- one apt fetch through a flaky proxy -- aborted every remaining step and
# said nothing, leaving a half-installed toolchain that looked identical to a
# working one. That happened: a container had nvim and stylua but no solvers,
# so `moon prove` failed while the notes claimed the hook installs them.
# Each step now reports its own failure and the rest carry on.
set -uo pipefail

echo '{"async": true, "asyncTimeout": 300000}'

# Local checkouts have their own toolchains; leave them alone.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

MOON_BIN="$HOME/.moon/bin"
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
  path_line="export PATH=\"$MOON_BIN:$LOCAL_BIN:\$PATH\""
  if ! grep -qxF "$path_line" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    echo "$path_line" >> "$CLAUDE_ENV_FILE"
  fi
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
install_moonbit() {
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
}

# Gated on the binary actually running, not merely existing: an install torn
# off partway leaves a `moon` that every later session then skips over.
if ! "$MOON_BIN/moon" version >/dev/null 2>&1; then
  echo "Installing MoonBit toolchain..."
  step "moonbit" install_moonbit
else
  echo "MoonBit toolchain already present."
fi

# A fresh install ships no registry index, so resolving moonbitlang/async fails
# with "module was not found in the registry" until this runs.
if [ ! -d "$HOME/.moon/registry/index" ]; then
  echo "Fetching the MoonBit module registry..."
  step "moon-registry" moon update
else
  echo "MoonBit registry index already present."
fi

# --- Neovim: tests/protocol_spec.lua and tests/two-editors.sh --------------
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

# --- SMT solvers: the provers behind `moon prove` --------------------------
# `moon prove` is Why3-backed and dispatches to external solvers: with none it
# fails outright with "failed to locate any SMT solver for `moon prove`:
# searched for `alt-ergo`, `cvc5`, `z3` in PATH".
#
# Two are installed, not one, because Why3 is built to run several provers over
# the same goals -- the toolchain's generated config carries a `[partial_prover]`
# strategy ("Automatic run of provers") and `running_provers_max = 16`. A goal
# that one solver cannot discharge often falls to another, so the second is
# roughly 2s for a materially better chance of closing a proof.
#
# Both come from apt rather than a GitHub release, unlike the tools above:
# Z3's release assets embed a glibc version in their filenames, so there is no
# stable `releases/latest/download/...` URL to derive, and api.github.com is not
# reachable from these containers to look one up.
#
# apt's versions are not the drag they look like. MoonBit bundles its own Why3
# (`$MOON_HOME/share/why3`), whose newest Z3 driver is `z3_487.drv` -- written
# for 4.8.7. apt's 4.8.12 sits just past that; a bleeding-edge Z3 would be
# further from the shipped driver, not closer to it. cvc5's driver is
# version-generic, and apt's 1.1.2 is recent.
#
# Alt-Ergo is the third solver `moon prove` accepts, and Why3 ships drivers for
# it. It is deliberately not installed: it is not in apt, so it would mean an
# opam toolchain and an OCaml build in a hook that currently finishes in under a
# minute. Add it if the two SMT solvers leave goals unproved.
apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$1"
}

missing_solvers=()
for solver in z3 cvc5; do
  if command -v "$solver" >/dev/null 2>&1; then
    echo "${solver} already present."
  else
    missing_solvers+=("$solver")
  fi
done

# Refresh the index once, not once per missing solver.
if [ "${#missing_solvers[@]}" -gt 0 ]; then
  step "apt-update" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  for solver in "${missing_solvers[@]}"; do
    echo "Installing $solver..."
    step "$solver" apt_install "$solver"
  done
fi

# A marker the session can read. This hook's output is retained nowhere, so a
# partial install is otherwise indistinguishable from a complete one -- which is
# exactly how a container ended up without solvers while the notes said it had
# them. Check this file before trusting `moon prove`.
mkdir -p "$(dirname "$STATUS_FILE")"
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "ok $(date -u +%FT%TZ)" > "$STATUS_FILE"
  echo "Binaries ready."
else
  printf 'failed %s %s\n' "$(date -u +%FT%TZ)" "${FAILURES[*]}" > "$STATUS_FILE"
  echo "Binaries INCOMPLETE -- failed: ${FAILURES[*]} (see $STATUS_FILE)" >&2
fi
