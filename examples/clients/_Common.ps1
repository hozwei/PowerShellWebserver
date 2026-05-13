#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the client example scripts.

.DESCRIPTION
    Dot-source this file from any example client (or paste the helpers
    inline) to get a single source for the base URL, API key, and
    common Invoke-RestMethod / Invoke-WebRequest wrappers used across
    the examples.

    The base URL and key default to env vars so you can switch them
    without editing files:

        $env:POSH_BASE_URL = 'https://api.example.com'
        $env:POSH_API_KEY  = 'your-key'

    Otherwise they fall back to http://localhost:80 and the value baked
    into the script.

.EXAMPLE
    . $PSScriptRoot/_Common.ps1
    Invoke-Posh -Path '/hello.ps1' -Query @{ Name = 'Anna' }
#>

$script:PoshBaseUrl = if ($env:POSH_BASE_URL) { $env:POSH_BASE_URL } else { 'http://localhost' }
$script:PoshApiKey  = if ($env:POSH_API_KEY)  { $env:POSH_API_KEY  } else { 'CHANGE-ME-or-set-POSH_API_KEY-env-var' }

function Get-PoshBaseUrl { $script:PoshBaseUrl }
function Get-PoshApiKey  { $script:PoshApiKey  }

function Invoke-Posh {
    <#
    .SYNOPSIS
        Thin wrapper around Invoke-RestMethod that adds the X-Api-Key
        header and joins the base URL with the given path.

    .PARAMETER Path
        URL path starting with `/` (e.g. `/hello.ps1`).

    .PARAMETER Method
        HTTP method. Defaults to GET.

    .PARAMETER Query
        Hashtable of query-string parameters. Values are URL-encoded.

    .PARAMETER Body
        Object to send as the request body. Hashtables and PSObjects
        get serialised to JSON automatically; strings are sent verbatim
        (use `-ContentType` then).

    .PARAMETER ContentType
        Override the content type. Defaults to `application/json` when
        a Body is given.

    .PARAMETER Session
        Optional WebSession (for cookie continuity across calls).

    .PARAMETER SkipHttpErrorCheck
        Same as the Invoke-RestMethod parameter — when set, 4xx/5xx
        responses do not throw and the JSON envelope can be inspected.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Method = 'GET',
        [hashtable] $Query,
        $Body,
        [string] $ContentType,
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [switch] $SkipHttpErrorCheck
    )

    $uri = "$script:PoshBaseUrl$Path"
    if ($Query -and $Query.Count -gt 0) {
        $kv = foreach ($k in $Query.Keys) {
            '{0}={1}' -f [uri]::EscapeDataString($k), [uri]::EscapeDataString([string]$Query[$k])
        }
        $uri += '?' + ($kv -join '&')
    }

    $headers = @{ 'X-Api-Key' = $script:PoshApiKey }
    $args    = @{
        Uri                 = $uri
        Method              = $Method
        Headers             = $headers
        SkipHttpErrorCheck  = [bool]$SkipHttpErrorCheck
    }
    if ($Session) { $args.WebSession = $Session }

    if ($null -ne $Body) {
        $isString = $Body -is [string]
        $args.Body = if ($isString) {
            $Body
        } else {
            $Body | ConvertTo-Json -Depth 10 -Compress
        }
        $args.ContentType = if ($ContentType) {
            $ContentType
        } elseif ($isString) {
            'text/plain; charset=utf-8'
        } else {
            'application/json'
        }
    }

    Invoke-RestMethod @args
}

function Write-Envelope {
    <#
    .SYNOPSIS
        Renders a posh JSON envelope (exitCode, output, error) for the
        terminal. Use after a script-endpoint call.
    #>
    param([Parameter(ValueFromPipeline)] $Response)
    process {
        if ($null -eq $Response) { return }
        if ($Response.PSObject.Properties['exitCode']) {
            $color = if ($Response.exitCode -eq 0) { 'Green' } else { 'Red' }
            Write-Host ("[exitCode={0}]" -f $Response.exitCode) -ForegroundColor $color
            if ($Response.output) { Write-Host $Response.output }
            if ($Response.error)  { Write-Host ("error: {0}" -f $Response.error) -ForegroundColor Yellow }
        } else {
            $Response | ConvertTo-Json -Depth 10
        }
    }
}
