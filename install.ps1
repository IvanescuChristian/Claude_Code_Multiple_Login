# Installs the claude --login_new wrapper for the current user (Windows).
#
# What it does:
#   - Copies bin/claude.cmd and bin/claude.ps1 from this repo to a directory
#     on your PATH (default: %USERPROFILE%\.local\bin), so `claude` typed in
#     PowerShell or cmd.exe resolves to the wrapper instead of the real
#     claude.cmd installed by npm/volta/etc.
#   - Verifies that directory actually comes before the real claude on PATH
#     (User PATH, so it doesn't touch anything system-wide), since a wrapper
#     installed later in PATH would never be used.
#
# Usage:
#   .\install.ps1                  # installs into %USERPROFILE%\.local\bin
#   .\install.ps1 -InstallDir 'C:\custom\bin'
#   .\install.ps1 -Uninstall
#   .\install.ps1 -Uninstall -InstallDir 'C:\custom\bin'
#
# This only ever touches files under -InstallDir and the current user's PATH
# environment variable; it never modifies system PATH, the git repo itself,
# or anything under a real claude install.

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude-cli-wrapper'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$SourceCmd = Join-Path $ScriptDir 'bin\claude.cmd'
$SourcePs1 = Join-Path $ScriptDir 'bin\claude.ps1'
$TargetCmd = Join-Path $InstallDir 'claude.cmd'
$TargetPs1 = Join-Path $InstallDir 'claude.ps1'

if ($Uninstall) {
    $removed = $false
    foreach ($f in @($TargetCmd, $TargetPs1)) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force
            Write-Host "Removed $f"
            $removed = $true
        }
    }
    if (-not $removed) {
        Write-Host "Nothing to remove under $InstallDir"
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $SourceCmd) -or -not (Test-Path -LiteralPath $SourcePs1)) {
    [Console]::Error.WriteLine("error: bin\claude.cmd / bin\claude.ps1 not found under $ScriptDir (run this script from a checkout of the repo)")
    exit 1
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath $SourceCmd -Destination $TargetCmd -Force
Copy-Item -LiteralPath $SourcePs1 -Destination $TargetPs1 -Force
Write-Host "Installed wrapper to $TargetCmd (+ $TargetPs1)"

# Find the real claude elsewhere on PATH (ignoring the dir we just installed to).
# Checks both claude.cmd (npm/volta installs) and claude.exe (native installer),
# since which one is present depends on how Claude Code was installed.
$installDirResolved = (Resolve-Path $InstallDir).Path
$realClaude = $null
:searchPath foreach ($dir in ($env:PATH -split ';' | Where-Object { $_ -ne '' })) {
    $dirResolved = $null
    try { $dirResolved = (Resolve-Path $dir -ErrorAction Stop).Path } catch { $dirResolved = $dir }
    if ($dirResolved -eq $installDirResolved) { continue }
    foreach ($name in @('claude.cmd', 'claude.exe')) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $realClaude = $candidate
            break searchPath
        }
    }
}

if (-not $realClaude) {
    Write-Warning "could not find an existing claude installation on PATH to wrap."
    Write-Warning "Install/reinstall Claude Code, then re-run this script."
    exit 0
}
Write-Host "Wrapping: $realClaude"

# Add the install dir to the front of User PATH (and this session's PATH)
# BEFORE verifying, so the verification below reflects the post-install state
# instead of always reporting the pre-install PATH as stale.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$userPathDirs = @()
if ($userPath) { $userPathDirs = $userPath -split ';' | Where-Object { $_ -ne '' } }
$alreadyOnUserPath = $userPathDirs | Where-Object {
    try { (Resolve-Path $_ -ErrorAction Stop).Path -eq $installDirResolved } catch { $false }
}

if (-not $alreadyOnUserPath) {
    $newUserPath = if ($userPath) { "$InstallDir;$userPath" } else { $InstallDir }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    # Also update this session so `claude` works immediately without reopening the terminal.
    $env:Path = "$InstallDir;$env:Path"
    Write-Host "Added '$InstallDir' to the front of your User PATH (persists for new terminals)."
    Write-Host "This session's PATH was updated too, so 'claude' should work right now."
} else {
    Write-Host "'$InstallDir' is already on your User PATH."
    # Still make sure THIS session's PATH has it in front (a prior install may
    # have added it further back, or this session predates the PATH change).
    $env:Path = "$InstallDir;$($env:Path -replace [regex]::Escape(";$InstallDir"), '' -replace [regex]::Escape("$InstallDir;"), '')"
}

# Confirm the install dir actually wins the PATH race for THIS process.
$resolvedCmd = Get-Command claude.cmd -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if (-not $resolvedCmd) {
    $resolvedCmd = Get-Command claude -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
}

if (-not $resolvedCmd) {
    Write-Warning "'$InstallDir' is not on your PATH yet (or this shell hasn't picked it up)."
} elseif ((Resolve-Path $resolvedCmd).Path -ne (Resolve-Path $TargetCmd).Path) {
    Write-Warning "'claude' on your PATH still resolves to $resolvedCmd, not the wrapper."
    Write-Warning "Move '$InstallDir' earlier in your User PATH."
} else {
    Write-Host "Verified: 'claude' now resolves to the wrapper ($resolvedCmd) in this session."
}

@'

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

Profiles are stored under %USERPROFILE%\.claude-profiles\<name>\ (override
with CLAUDE_LOGIN_NEW_PROFILES_DIR).

Every invocation also fills in --model sonnet, --fallback-model fable,
--effort medium, and --permission-mode acceptEdits unless you already passed
them (skipped for subcommands like `claude mcp`/`claude plugins`/`claude
auth`). Override via CLAUDE_LOGIN_NEW_DEFAULT_MODEL / _FALLBACK_MODEL /
_EFFORT / _PERMISSION_MODE env vars.
--plugin-dir, --plugin-url, and every other flag pass through untouched.
'@ | Write-Host
