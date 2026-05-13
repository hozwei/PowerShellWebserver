#Requires -Version 7.0
<#
.SYNOPSIS
    POST endpoint accepting application/x-www-form-urlencoded bodies.

.DESCRIPTION
    When the request `Content-Type` is `application/x-www-form-urlencoded`
    (and that prefix is in `AcceptedContentTypes`, default), the server
    parses the form body, collapses `key[]=...` repetitions into arrays,
    and re-serialises the result as JSON before writing it to disk.

    Scripts see no difference between JSON and form input — both arrive
    through `-JsonFilePath`. This example simply prints which keys it
    received so the client can verify the round-trip.

.PARAMETER JsonFilePath
    Absolute path to the (re-serialised) JSON file. Injected by the
    server.

.EXAMPLE
    curl -X POST http://localhost/post-form.ps1 `
         -H "X-Api-Key: your-key" `
         -H "Content-Type: application/x-www-form-urlencoded" `
         --data 'firstName=Anna&lastName=Mueller&tags[]=admin&tags[]=reader'
#>
param(
    [string] $JsonFilePath = ''
)

$ErrorActionPreference = 'Stop'

# Central config: keeps the response shape aligned with post-json.ps1
# (both endpoints can echo the same $Global:PoshServerFqdn).
. (Join-Path $PSScriptRoot '..\globalvars.ps1')

if ([string]::IsNullOrWhiteSpace($JsonFilePath) -or
    -not (Test-Path -LiteralPath $JsonFilePath -PathType Leaf)) {
    Write-Error 'JsonFilePath missing or unreadable. POST a form body to call this endpoint.'
    exit 1
}

$data = Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 |
        ConvertFrom-Json -Depth 10 -AsHashtable

$result = [ordered]@{
    receivedAt = (Get-Date).ToString('o')
    server     = $PoshServerFqdn
    keys       = @($data.Keys | Sort-Object)
    values     = [ordered]@{}
}
foreach ($k in ($data.Keys | Sort-Object)) {
    $v = $data[$k]
    # Arrays come from `key[]=...` repetition.
    if ($v -is [System.Collections.IList]) {
        $result.values[$k] = [ordered]@{ type = 'array'; count = @($v).Count; items = @($v) }
    } else {
        $result.values[$k] = [ordered]@{ type = 'scalar'; value = [string]$v }
    }
}

$result | ConvertTo-Json -Depth 5
exit 0
