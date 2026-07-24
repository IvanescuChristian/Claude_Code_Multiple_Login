# Windows (PowerShell) port of bin/claude.
#
# Shadows the real `claude` binary (this dir must sit ahead of it on PATH) to
# add a --login_new <profile> flag: runs that one invocation against an
# isolated CLAUDE_CONFIG_DIR so it gets its own credentials.json, separate
# from the shared %USERPROFILE%\.claude used by every other session/agent.
# Nothing is ever written to the shared config, so exiting leaves zero trace
# and every other running (or future, flag-less) `claude` instance is
# unaffected.
#
# Also fills in session defaults (--model, --fallback-model, --effort,
# --permission-mode) when the caller hasn't already specified them, for every
# invocation, whether or not --login_new is used.
#
# This script is invoked by claude.cmd (the thing actually on PATH), which
# forwards all arguments and the exit code. It is not meant to be put on
# PATH directly, since PowerShell does not resolve bare commands to .ps1
# files for security reasons.
#
# Usage:
#   claude --login_new work            # first time: creates+uses an isolated
#                                       # profile named "work"; run /login
#                                       # inside it once to sign in there
#   claude --login_new work            # later: reuses that profile's saved
#                                       #        credentials automatically
#   claude --login_new work --plugins foo --effort high
#                                       # any other flag/subcommand passes
#                                       # through untouched; explicit flags
#                                       # always win over the defaults below
#   claude ...                         # no flag: still gets the defaults,
#                                       # otherwise behaves exactly as before
#   claude --login_new --list          # list saved profiles, login status,
#                                       # and signed-in account when known
#   claude --login_new --help          # show wrapper-specific help

$ErrorActionPreference = 'Stop'

$ProfilesDir = if ($env:CLAUDE_LOGIN_NEW_PROFILES_DIR) { $env:CLAUDE_LOGIN_NEW_PROFILES_DIR } else { Join-Path $env:USERPROFILE '.claude-profiles' }

$DefaultModel          = if ($env:CLAUDE_LOGIN_NEW_DEFAULT_MODEL)           { $env:CLAUDE_LOGIN_NEW_DEFAULT_MODEL }           else { 'sonnet' }
$DefaultFallbackModel  = if ($env:CLAUDE_LOGIN_NEW_DEFAULT_FALLBACK_MODEL)  { $env:CLAUDE_LOGIN_NEW_DEFAULT_FALLBACK_MODEL }  else { 'fable' }
$DefaultEffort         = if ($env:CLAUDE_LOGIN_NEW_DEFAULT_EFFORT)         { $env:CLAUDE_LOGIN_NEW_DEFAULT_EFFORT }         else { 'medium' }
$DefaultPermissionMode = if ($env:CLAUDE_LOGIN_NEW_DEFAULT_PERMISSION_MODE) { $env:CLAUDE_LOGIN_NEW_DEFAULT_PERMISSION_MODE } else { 'acceptEdits' }

# Subcommands (as opposed to flags on the default interactive/print session)
# don't accept --model/--fallback-model/--effort, so defaults must be skipped
# whenever the first non-flag token is one of these.
$KnownSubcommands = @('agents','auth','auto-mode','doctor','gateway','install','mcp','plugin','plugins','project','setup-token','ultrareview','update','upgrade')

function Find-RealClaude {
    $selfDir = $PSScriptRoot
    $selfResolved = $null
    try { $selfResolved = (Resolve-Path $selfDir).Path } catch { $selfResolved = $selfDir }

    $pathDirs = $env:PATH -split ';' | Where-Object { $_ -ne '' }
    foreach ($dir in $pathDirs) {
        $dirResolved = $null
        try { $dirResolved = (Resolve-Path $dir -ErrorAction Stop).Path } catch { $dirResolved = $dir }
        if ($dirResolved -eq $selfResolved) { continue }

        foreach ($name in @('claude.cmd', 'claude.exe')) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    # PATH-based lookup can come up empty in shells/processes that never
    # picked up the profile that puts npm/volta/nvm bin dirs on PATH
    # (scheduled tasks, some IDE terminals, services, etc). Fall back to the
    # common install locations so the wrapper still works from there too.
    $fallbackCandidates = @(
        (Join-Path $env:APPDATA 'npm\claude.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Volta\bin\claude.cmd'),
        (Join-Path $env:ProgramFiles 'nodejs\claude.cmd')
    )
    foreach ($candidate in $fallbackCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $candidateResolved = (Resolve-Path $candidate).Path
            if ($candidateResolved -ne (Join-Path $selfResolved 'claude.cmd')) {
                return $candidate
            }
        }
    }

    return $null
}

$RealClaude = Find-RealClaude
if (-not $RealClaude) {
    [Console]::Error.WriteLine('claude wrapper: could not find the real claude binary on PATH (besides this wrapper)')
    exit 1
}

function Show-Profiles {
    if (-not (Test-Path -LiteralPath $ProfilesDir)) {
        Write-Host "No profiles yet. Create one with: claude --login_new <name>"
        return
    }
    $dirs = Get-ChildItem -LiteralPath $ProfilesDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $dirs) {
        Write-Host "No profiles yet. Create one with: claude --login_new <name>"
        return
    }
    Write-Host "Profiles in ${ProfilesDir}:"
    foreach ($d in $dirs) {
        $credsFile = Join-Path $d.FullName '.credentials.json'
        $configFile = Join-Path $d.FullName '.claude.json'
        $status = 'not logged in'
        if (Test-Path -LiteralPath $credsFile) { $status = 'logged in' }

        $account = ''
        if (Test-Path -LiteralPath $configFile) {
            try {
                $cfg = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
                $email = $cfg.oauthAccount.emailAddress
                $display = $cfg.oauthAccount.displayName
                if ($email -and $display) {
                    $account = "$email ($display)"
                } elseif ($email) {
                    $account = $email
                }
            } catch {}
        }

        $line = "  {0,-20} {1,-14}" -f $d.Name, $status
        if ($account) { $line += "  -  $account" }
        Write-Host $line
    }
}

function Show-Help {
    Write-Host @"
claude --login_new <profile> [claude args...]
    Runs claude under an isolated profile (its own credentials.json),
    without touching the shared %USERPROFILE%\.claude used by other sessions.
    First run: '/login' inside the session to sign in for this profile.

claude --login_new --list
    Lists saved profiles under $ProfilesDir, their login status, and the
    signed-in account (email/display name) when known.

claude --login_new --help
    Shows this help.

Session defaults applied to every invocation unless overridden:
    --model $DefaultModel  --fallback-model $DefaultFallbackModel  --effort $DefaultEffort  --permission-mode $DefaultPermissionMode
Override via CLAUDE_LOGIN_NEW_DEFAULT_* environment variables.

All other claude flags/subcommands pass through untouched.
"@
}

$rawArgs = $args

$loginNew = $null
$passArgs = New-Object System.Collections.Generic.List[string]

$i = 0
while ($i -lt $rawArgs.Count) {
    $a = $rawArgs[$i]
    if ($a -eq '--login_new' -or $a -eq '-login_new') {
        if ($i + 1 -ge $rawArgs.Count -or [string]::IsNullOrEmpty($rawArgs[$i + 1])) {
            [Console]::Error.WriteLine('claude: --login_new requires a profile name, e.g. --login_new work')
            exit 1
        }
        $loginNew = $rawArgs[$i + 1]
        $i += 2
        continue
    }
    if ($a -like '--login_new=*' -or $a -like '-login_new=*') {
        $loginNew = $a.Substring($a.IndexOf('=') + 1)
        $i += 1
        continue
    }
    $passArgs.Add($a)
    $i += 1
}

if ($loginNew -eq '--list' -or $loginNew -eq '-list' -or $loginNew -eq 'list') {
    Show-Profiles
    exit 0
}
if ($loginNew -eq '--help' -or $loginNew -eq '-help' -or $loginNew -eq 'help') {
    Show-Help
    exit 0
}

# Detect a subcommand as the first non-flag token (e.g. `claude mcp add ...`);
# session defaults don't apply to those.
$isSubcommand = $false
if ($passArgs.Count -gt 0 -and -not $passArgs[0].StartsWith('-')) {
    if ($KnownSubcommands -contains $passArgs[0]) {
        $isSubcommand = $true
    }
}

$finalArgs = New-Object System.Collections.Generic.List[string]
if (-not $isSubcommand) {
    $hasModel = $false
    $hasFallback = $false
    $hasEffort = $false
    $hasPermissionMode = $false
    foreach ($a in $passArgs) {
        if ($a -eq '--model' -or $a -like '--model=*') { $hasModel = $true }
        if ($a -eq '--fallback-model' -or $a -like '--fallback-model=*') { $hasFallback = $true }
        if ($a -eq '--effort' -or $a -like '--effort=*') { $hasEffort = $true }
        if ($a -eq '--permission-mode' -or $a -like '--permission-mode=*') { $hasPermissionMode = $true }
    }

    # Defaults first, caller's own args last, so an explicit flag always wins
    # if the has_* detection above ever misses a form.
    if (-not $hasModel) { $finalArgs.Add('--model'); $finalArgs.Add($DefaultModel) }
    if (-not $hasFallback) { $finalArgs.Add('--fallback-model'); $finalArgs.Add($DefaultFallbackModel) }
    if (-not $hasEffort) { $finalArgs.Add('--effort'); $finalArgs.Add($DefaultEffort) }
    if (-not $hasPermissionMode) { $finalArgs.Add('--permission-mode'); $finalArgs.Add($DefaultPermissionMode) }

    foreach ($a in $passArgs) { $finalArgs.Add($a) }
} else {
    foreach ($a in $passArgs) { $finalArgs.Add($a) }
}

if ($loginNew) {
    if ($loginNew -notmatch '^[A-Za-z0-9._-]+$') {
        [Console]::Error.WriteLine("claude: invalid profile name '$loginNew' (use letters, numbers, ., _, -)")
        exit 1
    }
    $profileDir = Join-Path $ProfilesDir $loginNew
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $credentialsFile = Join-Path $profileDir '.credentials.json'
    if (-not (Test-Path -LiteralPath $credentialsFile)) {
        [Console]::Error.WriteLine("claude: profile '$loginNew' has no saved login yet -- run /login inside this session to sign in (only this profile is affected).")
    }

    # Setting CLAUDE_CONFIG_DIR here only affects this process (spawned fresh
    # by claude.cmd for this one invocation), so it can never leak into the
    # interactive shell the user is typing in, nor into any other running or
    # future claude/agent process.
    $env:CLAUDE_CONFIG_DIR = $profileDir
    & $RealClaude @finalArgs
    exit $LASTEXITCODE
} else {
    & $RealClaude @finalArgs
    exit $LASTEXITCODE
}
