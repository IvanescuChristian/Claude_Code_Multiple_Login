# Claude Code Multiple Login

Adds a `--login_new <profile>` flag to the `claude` CLI so you can run a
session under a different account, scoped only to that one invocation,
without affecting any other running (or future) `claude` session/agent.

## Why

`claude`'s auth (OAuth access/refresh token) lives in a single shared file:
`~/.claude/.credentials.json`. Every `claude` process on the machine reads
and refreshes against that same file, so running `/login` to switch accounts
effectively logs out every other concurrent session too.

`CLAUDE_CONFIG_DIR` is an env var Claude Code already supports for pointing
an entire process at an isolated config directory (its own credentials,
settings, sessions). This project wraps that into a single flag.

## How it works

`bin/claude` is a small shell wrapper that:
- Passes everything through unchanged to the real `claude` binary when no
  `--login_new` flag is given.
- When `--login_new <profile>` is given, runs that one invocation with
  `CLAUDE_CONFIG_DIR` set to `~/.claude-profiles/<profile>/` — a private
  directory with its own `.credentials.json`.

Because the env var is only ever passed to that one child process (never
exported into your shell), it can't leak into other terminals or other
`claude`/agent processes. The shared `~/.claude` directory is never opened
for writing by a `--login_new` run, so:
- other sessions using the default profile are unaffected while it runs,
- and once you exit, nothing needs to be "reverted" — nothing was touched.

## Install

```sh
./install.sh              # installs bin/claude to ~/.local/bin (default)
./install.sh /some/dir    # or a custom directory on your PATH
```

The installer copies `bin/claude` to the target directory and checks that
directory actually wins the PATH race against the real `claude` binary. If
it doesn't, it tells you exactly what to add to your shell rc file.

To uninstall:

```sh
./install.sh --uninstall [dir]   # removes the installed wrapper
```

## Usage

```sh
# First time: creates the "work" profile and starts a session under it.
# Nothing is logged in yet — run /login inside to sign in for this profile.
claude --login_new work

# Later: reuses the saved login for "work" automatically.
claude --login_new work

# No flag: behaves exactly like the real claude, untouched.
claude
```

Profiles live under `~/.claude-profiles/<name>/` (override the base
directory with `CLAUDE_LOGIN_NEW_PROFILES_DIR`).

## Limitations

- `--login_new` is a **launch-time** flag — it selects which profile a new
  `claude` process starts under. It cannot swap the account of an
  already-running interactive session; `/login` itself is a native command
  built into the compiled `claude` binary, and no user-space hook, prompt,
  tool, or MCP server can reach into a running process to change which
  credentials file it's using. To switch accounts, exit and relaunch with
  `--login_new <profile>`.
