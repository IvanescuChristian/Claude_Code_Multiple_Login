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
cp "$SOURCE_FILE" "$TARGET_FILE"
chmod +x "$TARGET_FILE"
echo "Installed wrapper to $TARGET_FILE"

# Find the real claude binary elsewhere on PATH (ignoring the one we just installed).
real_claude=""
IFS=:
for dir in $PATH; do
  candidate="$dir/claude"
  if [[ -x "$candidate" && "$(readlink -f "$candidate" 2>/dev/null)" != "$(readlink -f "$TARGET_FILE")" ]]; then
    real_claude="$candidate"
    break
  fi
done
unset IFS

if [[ -z "$real_claude" ]]; then
  echo "warning: could not find an existing claude installation on PATH to wrap." >&2
  echo "         Install/reinstall Claude Code, then re-run this script." >&2
  exit 0
fi
echo "Wrapping: $real_claude"

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
