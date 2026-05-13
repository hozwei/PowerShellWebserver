#Requires -Version 7.0
<#
.SYNOPSIS
    Minimal GET endpoint — greets the caller by name.

.DESCRIPTION
    The simplest possible posh endpoint: declares a few typed parameters,
    writes its output to stdout, and exits with code 0 for a normal
    response. The server wraps the output in the
    `{ exitCode, output, error }` JSON envelope automatically.

    Query string parameters arrive as named arguments. Strings stay
    strings, integers must be cast inside the script (HTTP transports
    everything as text).

.PARAMETER Name
    Display name. Defaults to 'World'.

.PARAMETER Count
    How many times to repeat the greeting (1-10). Defaults to 1.

.PARAMETER Loud
    When 'true', the greeting is uppercased.

.EXAMPLE
    Invoke-RestMethod -Uri 'http://localhost/hello.ps1?Name=Anna' `
        -Headers @{ 'X-Api-Key' = 'your-key' }
#>
param(
    [string] $Name  = 'World',
    [string] $Count = '1',
    [string] $Loud  = 'false'
)

# Dot-source the central config (server names, paths, AES key).
. (Join-Path $PSScriptRoot '..\globalvars.ps1')

# Query-string values arrive as strings — cast Count and convert Loud.
$repeats = [int]$Count
if ($repeats -lt 1)  { $repeats = 1 }
if ($repeats -gt 10) { $repeats = 10 }
$shout = $Loud -eq 'true' -or $Loud -eq '1'

# Server name pulled from globalvars so a deployment rename touches one file.
$greeting = "Hello, $Name! (from $PoshServerFqdn)"
if ($shout) { $greeting = $greeting.ToUpper() }

1..$repeats | ForEach-Object { Write-Output $greeting }
exit 0
