#Requires -Version 7.0
<#
.SYNOPSIS
    Demonstrates how exit codes, Write-Error, and Write-Output map to HTTP.

.DESCRIPTION
    The server translates webroot script outcomes into HTTP status codes:

        exit 0                    -> HTTP 200, JSON { exitCode: 0, output: ..., error: '' }
        exit <non-zero>           -> HTTP 500, JSON { exitCode: N, output: ..., error: ... }
        Write-Error + exit N      -> stderr captured into 'error', HTTP 500
        Script exceeds timeout    -> HTTP 504 (terminated by the server)

    Pass `?Mode=...` to choose which path to exercise:

        ?Mode=ok       -> normal Write-Output, exit 0
        ?Mode=warn     -> writes to stdout and stderr but still exits 0
        ?Mode=fail     -> writes an error and exits 1 (HTTP 500)
        ?Mode=throw    -> raises a terminating exception (HTTP 500)
        ?Mode=timeout  -> sleeps past ScriptTimeoutSec (HTTP 504)

.PARAMETER Mode
    One of: 'ok', 'warn', 'fail', 'throw', 'timeout'. Defaults to 'ok'.

.PARAMETER Message
    Optional message added to the response. Defaults to a generic note.

.EXAMPLE
    Invoke-RestMethod -Uri 'http://localhost/errors.ps1?Mode=fail' `
        -Headers @{ 'X-Api-Key' = 'your-key' } -SkipHttpErrorCheck
#>
param(
    [string] $Mode    = 'ok',
    [string] $Message = 'demo message'
)

# Central config — included so the response includes the operator's
# AdminMail address, useful when a 500 prompts an operator to follow up.
. (Join-Path $PSScriptRoot '..\globalvars.ps1')

switch ($Mode.ToLowerInvariant()) {
    'ok' {
        Write-Output "OK: $Message  (contact: $AdminMail on issue)"
        exit 0
    }
    'warn' {
        Write-Output "Output: $Message"
        Write-Error  "Non-fatal warning: $Message"
        # Still exit 0 — the response is HTTP 200 with `error` populated.
        exit 0
    }
    'fail' {
        Write-Output "Partial output before failure: $Message"
        Write-Error  "Operation failed: $Message"
        exit 1
    }
    'throw' {
        throw "Demo exception: $Message"
    }
    'timeout' {
        Write-Output 'Sleeping past ScriptTimeoutSec — the server should kill us with HTTP 504.'
        # Default ScriptTimeoutSec is 300s; this sleeps 10 minutes to be safe.
        Start-Sleep -Seconds 600
        Write-Output 'You should never see this line.'
        exit 0
    }
    default {
        Write-Error "Unknown Mode '$Mode'. Valid values: ok, warn, fail, throw, timeout."
        exit 2
    }
}
