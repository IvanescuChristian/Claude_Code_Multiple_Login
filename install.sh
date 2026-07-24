#!/usr/bin/env bash
# Installs the claude --login_new wrapper for the current user.
#
# What it does:
#   - Copies bin/claude from this repo to a directory on your PATH
#     (default: ~/.local/bin), so it shadows the real `claude` binary.
#   - Verifies that directory actually comes before the real claude on
#     PATH, since a wrapper installed later in PATH would never be used.
#
# Usage:
#   ./install.sh                 # installs into ~/.local/bin
#   ./install.sh /custom/bin/dir # installs into a custom directory
#
# Uninstall: rm the installed file (path printed at the end of this script,
# also re-printable via `./install.sh --uninstall`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/bin/claude"
INSTALL_DIR="${1:-$HOME/.local/bin}"
TARGET_FILE="$INSTALL_DIR/claude"

if [[ "${1:-}" == "--uninstall" ]]; then
  target="${2:-$HOME/.local/bin}/claude"
  if [[ -f "$target" ]]; then
    rm -f "$target"
    echo "Removed $target"
  else
    echo "Nothing to remove at $target"
  fi
  exit 0
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "error: $SOURCE_FILE not found (run this script from a checkout of the repo)" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

# Before touching anything: if $TARGET_FILE already exists, capture what it
# *currently* resolves to. On a native Claude Code install this is normally
# a symlink like ~/.local/bin/claude -> ~/.local/share/claude/versions/<ver>
# — i.e. the ONLY on-PATH reference to the real binary. `cp` onto an
# existing path follows symlinks and overwrites whatever they point at in
# place, so a plain `cp "$SOURCE_FILE" "$TARGET_FILE"` here would clobber
# that real versioned binary itself, not just the symlink (this is exactly
# what happened previously: ~/.local/share/claude/versions/2.1.215 ended up
# byte-for-byte identical to bin/claude). Resolve and preserve that path
# *before* removing the old entry, so we still know where the real binary
# is even after $TARGET_FILE becomes the wrapper.
preexisting_target=""
if [[ -e "$TARGET_FILE" ]]; then
  preexisting_target="$(readlink -f "$TARGET_FILE" 2>/dev/null || true)"
fi

rm -f "$TARGET_FILE"
cp "$SOURCE_FILE" "$TARGET_FILE"
chmod +x "$TARGET_FILE"
echo "Installed wrapper to $TARGET_FILE"

is_our_wrapper() {
  # True if $1 is missing, not executable, or byte-identical to the wrapper
  # source — i.e. not safe to treat as "the real claude" (either it doesn't
  # exist, or it's itself a previous/other wrapper install, which would
  # otherwise let us wrap a wrapper, or worse, an unrelated `claude` on a
  # totally different machine/filesystem reached only by PATH accident).
  [[ -x "$1" ]] || return 0
  cmp -s "$1" "$SOURCE_FILE" 2>/dev/null
}

real_claude=""
if [[ -n "$preexisting_target" ]] && ! is_our_wrapper "$preexisting_target"; then
  real_claude="$preexisting_target"
fi

# Fall back to a PATH scan only if $TARGET_FILE didn't already point at a
# usable real binary (e.g. first-ever install with $INSTALL_DIR not yet on
# PATH, so nothing was there to resolve above).
if [[ -z "$real_claude" ]]; then
  IFS=:
  for dir in $PATH; do
    candidate="$dir/claude"
    if [[ -x "$candidate" ]] && ! is_our_wrapper "$candidate" \
       && [[ "$(readlink -f "$candidate" 2>/dev/null)" != "$(readlink -f "$TARGET_FILE")" ]]; then
      real_claude="$candidate"
      break
    fi
  done
  unset IFS
fi

if [[ -z "$real_claude" ]]; then
  echo "warning: could not find an existing claude installation to wrap." >&2
  echo "         Install/reinstall Claude Code, then re-run this script." >&2
  exit 0
fi
echo "Wrapping: $real_claude"

# Record the resolved path so bin/claude doesn't have to rediscover it via a
# live PATH scan at runtime — once $TARGET_FILE occupies the only on-PATH
# `claude` slot, a runtime scan has nothing else to find on a pure native
# install (no separate PATH entry for the real binary exists at all), and
# falling back to an unrelated `claude` found elsewhere (e.g. a Windows
# install reachable over a WSL interop mount) means every profile silently
# authenticates against that other install's single account instead of its
# own — the exact bug this fixes.
printf '%s\n' "$real_claude" > "$INSTALL_DIR/.claude-real-bin"

# Confirm the install dir actually wins the PATH race.
resolved="$(command -v claude || true)"
if [[ -z "$resolved" ]]; then
  echo "warning: '$INSTALL_DIR' is not on your PATH yet. Add this to your shell rc:" >&2
  echo "         export PATH=\"$INSTALL_DIR:\$PATH\"" >&2
elif [[ "$(readlink -f "$resolved")" != "$(readlink -f "$TARGET_FILE")" ]]; then
  echo "warning: 'claude' on your PATH still resolves to $resolved, not the wrapper." >&2
  echo "         Move '$INSTALL_DIR' earlier in PATH, e.g. in your shell rc:" >&2
  echo "         export PATH=\"$INSTALL_DIR:\$PATH\"" >&2
else
  echo "Verified: 'claude' now resolves to the wrapper ($resolved)."
fi

cat <<'EOF'

Usage:
  claude --login_new <profile>   Start a session using an isolated login,
                                  scoped only to this invocation. First run
                                  will prompt you to /login inside; it's
                                  remembered for next time under the same
                                  profile name. Every other session/agent
                                  that doesn't pass --login_new is completely
                                  unaffected, both while this one runs and
                                  after it exits.
  claude ...                     No flag: identical to the real claude,
                                  plus the session defaults below.

Profiles are stored under ~/.claude-profiles/<name>/ (override with
CLAUDE_LOGIN_NEW_PROFILES_DIR).

Every invocation also fills in --model sonnet, --fallback-model fable, and
--effort medium unless you already passed them (skipped for subcommands
like `claude mcp`/`claude plugins`/`claude auth`). Override via
CLAUDE_LOGIN_NEW_DEFAULT_MODEL / _FALLBACK_MODEL / _EFFORT env vars.
--plugin-dir, --plugin-url, and every other flag pass through untouched.
EOF
