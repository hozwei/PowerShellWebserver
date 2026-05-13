#Requires -Version 7.0
<#
.SYNOPSIS
    Client: POST /post-form.ps1 — application/x-www-form-urlencoded body.

.DESCRIPTION
    Pairs with `webroot/post-form.ps1`. Demonstrates how the server
    accepts classic form encodings transparently and re-serialises
    them into the same JSON file the .ps1 script receives via
    -JsonFilePath. `key[]=...` repetition collapses into arrays —
    this client passes two tags to show that.

.PARAMETER FirstName
    Demo input.

.PARAMETER LastName
    Demo input.

.PARAMETER Tags
    Array of tags — each becomes a `tags[]=...` pair in the body.

.EXAMPLE
    .\Send-PostForm.ps1 -FirstName Anna -LastName Mueller -Tags admin,reader
#>
param(
    [string]   $FirstName = 'Anna',
    [string]   $LastName  = 'Mueller',
    [string[]] $Tags      = @('admin', 'reader')
)

. $PSScriptRoot/_Common.ps1

# Build x-www-form-urlencoded body manually so we can repeat `tags[]=...`.
$pairs = [System.Collections.Generic.List[string]]::new()
$pairs.Add('firstName=' + [uri]::EscapeDataString($FirstName))
$pairs.Add('lastName='  + [uri]::EscapeDataString($LastName))
foreach ($t in $Tags) {
    $pairs.Add('tags[]=' + [uri]::EscapeDataString($t))
}
$body = $pairs -join '&'

$envelope = Invoke-Posh -Path '/post-form.ps1' `
                        -Method POST `
                        -Body $body `
                        -ContentType 'application/x-www-form-urlencoded'

if ($envelope.exitCode -ne 0) {
    $envelope | Write-Envelope
    return
}

$echo = $envelope.output | ConvertFrom-Json -Depth 10
Write-Host ('Received at : {0}' -f $echo.receivedAt)
Write-Host ('Keys parsed : {0}' -f ($echo.keys -join ', '))
foreach ($k in $echo.keys) {
    $v = $echo.values.$k
    if ($v.type -eq 'array') {
        Write-Host ('  {0} = [{1}]  (count={2})' -f $k, ($v.items -join ', '), $v.count)
    } else {
        Write-Host ('  {0} = {1}' -f $k, $v.value)
    }
}
