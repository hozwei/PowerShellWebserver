#Requires -Version 7.0
<#
.SYNOPSIS
    Demonstrates session/cookie reception by webroot scripts.

.DESCRIPTION
    Reads the per-request session ID and raw Cookie header that the server
    injects via environment variables when $cfg.SessionEnabled = $true.

    The server itself stays stateless — POSH_SESSION_ID is just an
    auto-minted cookie value that the client echoes back. Scripts that
    need persistent state must store it themselves (file, DB, …).

.EXAMPLE
    # Enable SessionEnabled in $cfg, then:
    Invoke-RestMethod -Uri 'http://localhost/with-session.ps1' `
        -SessionVariable s -Headers @{ 'X-Api-Key' = 'your-api-key' }
    # second request reuses the cookie returned by the first
    Invoke-RestMethod -Uri 'http://localhost/with-session.ps1' `
        -WebSession $s -Headers @{ 'X-Api-Key' = 'your-api-key' }
#>

$ErrorActionPreference = 'Stop'

# POSH_SESSION_ID is set only when $cfg.SessionEnabled = $true. Empty otherwise.
$sessionId = $env:POSH_SESSION_ID
if ([string]::IsNullOrEmpty($sessionId)) {
    Write-Output 'Session not enabled (set $cfg.SessionEnabled = $true to activate).'
    exit 0
}

# POSH_COOKIES is the raw Cookie: header — useful when the request carries
# additional cookies beyond the session ID.
$rawCookies = $env:POSH_COOKIES
if ([string]::IsNullOrEmpty($rawCookies)) { $rawCookies = '(none)' }

Write-Output "Session ID  : $sessionId"
Write-Output "Raw cookies : $rawCookies"
Write-Output ''
Write-Output 'Tip: pass -SessionVariable in Invoke-RestMethod to keep the cookie across calls.'
