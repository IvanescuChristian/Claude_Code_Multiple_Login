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

### macOS / Linux

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

### Windows

```powershell
.\install.ps1                              # installs to %USERPROFILE%\.local\bin (default)
.\install.ps1 -InstallDir C:\some\dir      # or a custom directory
```

The installer copies `bin\claude.cmd` and `bin\claude.ps1` to the target
directory, adds that directory to the front of your **User** PATH (never
System PATH, and it never touches this git checkout itself), and verifies
that `claude` now resolves to the wrapper instead of the real `claude.cmd`
installed by npm/volta/etc. It updates the current session's PATH too, so it
works immediately without reopening your terminal.

`claude.cmd` is a thin shim (PowerShell won't implicitly run a bare `.ps1`
for security reasons) that forwards everything to `claude.ps1`, which is the
actual port of `bin/claude`'s logic — same `--login_new` flag, same session
defaults, same subcommand detection, same profile-isolation guarantees, just
using `CLAUDE_CONFIG_DIR` + `%USERPROFILE%\.claude-profiles\<name>\` instead
of `$HOME/.claude-profiles/<name>/`.

To uninstall:

```powershell
.\install.ps1 -Uninstall                       # removes from the default dir
.\install.ps1 -Uninstall -InstallDir C:\some\dir
```

## Usage

### macOS / Linux

```sh
# First time: creates the "work" profile and starts a session under it.
# Nothing is logged in yet — run /login inside to sign in for this profile.
claude --login_new work

# Later: reuses the saved login for "work" automatically.
claude --login_new work

# No flag: behaves exactly like the real claude, untouched.
claude

# List saved profiles, login status, and signed-in account when known.
claude --login_new --list

# Show wrapper-specific help (this flag, --list, session defaults, etc).
claude --login_new --help
```

Profiles live under `~/.claude-profiles/<name>/` (override the base
directory with `CLAUDE_LOGIN_NEW_PROFILES_DIR`).

### Windows

Same flag, same behavior, from PowerShell or cmd.exe:

```powershell
# First time: creates the "work" profile and starts a session under it.
# Nothing is logged in yet — run /login inside to sign in for this profile.
claude --login_new work

# Later: reuses the saved login for "work" automatically.
claude --login_new work

# Start a second, independent account side by side in another terminal —
# the "work" session above is untouched.
claude --login_new personal

# Any other flag/subcommand still passes through, in any order:
claude --login_new work --plugin-dir C:\path\to\plugin --effort high
claude mcp add foo          # subcommands skip the session defaults, as usual

# No flag: behaves exactly like the real claude, untouched.
claude

# List saved profiles, login status, and signed-in account when known.
claude --login_new --list

# Show wrapper-specific help (this flag, --list, session defaults, etc).
claude --login_new --help
```

Profiles live under `%USERPROFILE%\.claude-profiles\<name>\` (override the
base directory with `CLAUDE_LOGIN_NEW_PROFILES_DIR`). Each profile gets its
own `.credentials.json`, so `/login` inside a `--login_new work` session only
ever signs in that profile — every other terminal, including a plain
`claude` with no flag, keeps using the shared default account untouched.

## Session defaults

Every invocation (whether or not `--login_new` is used) gets these defaults
filled in unless you already passed them yourself:

- `--model sonnet`
- `--fallback-model fable`
- `--effort medium`
- `--permission-mode acceptEdits`

Any explicit flag you pass wins over its default, e.g.
`claude --login_new work --model opus` starts on Opus, not Sonnet. Defaults
are skipped entirely for subcommands (`claude mcp ...`, `claude plugins ...`,
`claude auth ...`, etc.) since those don't accept session flags. All other
flags — `--plugin-dir`, `--plugin-url`, `--agent`, `--mcp-config`, and so on —
pass through untouched, in any order, alongside `--login_new`.

Override the defaults for every invocation via env vars:

```sh
# macOS / Linux
export CLAUDE_LOGIN_NEW_DEFAULT_MODEL=opus
export CLAUDE_LOGIN_NEW_DEFAULT_FALLBACK_MODEL=sonnet
export CLAUDE_LOGIN_NEW_DEFAULT_EFFORT=high
export CLAUDE_LOGIN_NEW_DEFAULT_PERMISSION_MODE=default
```

```powershell
# Windows — current session only
$env:CLAUDE_LOGIN_NEW_DEFAULT_MODEL = 'opus'
$env:CLAUDE_LOGIN_NEW_DEFAULT_FALLBACK_MODEL = 'sonnet'
$env:CLAUDE_LOGIN_NEW_DEFAULT_EFFORT = 'high'
$env:CLAUDE_LOGIN_NEW_DEFAULT_PERMISSION_MODE = 'default'

# Windows — persist across terminals (User scope)
[Environment]::SetEnvironmentVariable('CLAUDE_LOGIN_NEW_DEFAULT_MODEL', 'opus', 'User')
[Environment]::SetEnvironmentVariable('CLAUDE_LOGIN_NEW_DEFAULT_FALLBACK_MODEL', 'sonnet', 'User')
[Environment]::SetEnvironmentVariable('CLAUDE_LOGIN_NEW_DEFAULT_EFFORT', 'high', 'User')
[Environment]::SetEnvironmentVariable('CLAUDE_LOGIN_NEW_DEFAULT_PERMISSION_MODE', 'default', 'User')
```

## Limitations

- `--login_new` is a **launch-time** flag — it selects which profile a new
  `claude` process starts under. It cannot swap the account of an
  already-running interactive session; `/login` itself is a native command
  built into the compiled `claude` binary, and no user-space hook, prompt,
  tool, or MCP server can reach into a running process to change which
  credentials file it's using. To switch accounts, exit and relaunch with
  `--login_new <profile>`.
- Capping spend once you hit 100% of your plan's usage isn't something this
  wrapper can do. "Extra usage" (overage) beyond your plan is an
  account/org-level toggle on claude.ai, enforced server-side — there's no
  CLI flag, env var, or local settings.json key that controls it, so a
  shell wrapper has nothing to set. Check/change it at
  https://claude.ai/settings/usage (or your org's admin billing settings).
  The one client-side spend cap that does exist, `--max-budget-usd`, only
  applies to non-interactive `--print` runs, not interactive sessions.
