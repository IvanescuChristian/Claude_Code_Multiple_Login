@echo off
setlocal
rem Thin shim so `claude` resolves to something on PATH via PATHEXT (.CMD).
rem PowerShell will not implicitly execute a bare .ps1 file for security
rem reasons, so all the actual logic lives in claude.ps1 next to this file;
rem this just forwards args/exit code through to it.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude.ps1" %*
exit /b %ERRORLEVEL%
