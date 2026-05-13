#Requires -Version 7.0
<#
.SYNOPSIS
    Reflects the session cookie and incoming cookies the server injected.

.DESCRIPTION
    With `SessionEnabled = $true`, the server mints a fresh HttpOnly
    session cookie when a request arrives without one and forwards the
    value to webroot scripts through environment variables:

        POSH_SESSION_ID  - the value of the SessionCookieName cookie
        POSH_COOKIES     - the raw Cookie: header from the request

    The server itself stays stateless; scripts that need server-side
    state must persist it themselves (file, DB, ...).

    Calling this endpoint twice in the same `Invoke-RestMethod
    -SessionVariable` chain returns the same SessionId across both
    responses, proving the cookie round-trip works.

.EXAMPLE
    Invoke-RestMethod -Uri 'http://localhost/session.ps1' `
        -Headers @{ 'X-Api-Key' = 'your-key' } -SessionVariable s
    # Second call reuses the cookie set by the first
    Invoke-RestMethod -Uri 'http://localhost/session.ps1' `
        -Headers @{ 'X-Api-Key' = 'your-key' } -WebSession  $s
#>

$ErrorActionPreference = 'Stop'

# Central config — used here to surface the deployment FQDN alongside
# the session id, so multi-server cookie tests can verify which posh
# instance issued the cookie.
. (Join-Path $PSScriptRoot '..\globalvars.ps1')

$sessionId  = $env:POSH_SESSION_ID
$rawCookies = $env:POSH_COOKIES

$result = [ordered]@{
    server           = $PoshServerFqdn
    sessionId        = if ([string]::IsNullOrEmpty($sessionId))  { $null } else { $sessionId }
    sessionEnabled   = -not [string]::IsNullOrEmpty($sessionId)
    rawCookieHeader  = if ([string]::IsNullOrEmpty($rawCookies)) { '' } else { $rawCookies }
    rawCookieCount   = if ([string]::IsNullOrEmpty($rawCookies)) { 0  } else { ($rawCookies -split ';').Count }
    note             = if ([string]::IsNullOrEmpty($sessionId)) {
        'SessionEnabled is $false in config.psd1 — set it to $true to mint a POSH-Session-Id cookie.'
    } else {
        'SessionEnabled is active. Second call with -WebSession will reuse this id.'
    }
    timestamp        = (Get-Date).ToString('o')
}

$result | ConvertTo-Json -Depth 5
exit 0
