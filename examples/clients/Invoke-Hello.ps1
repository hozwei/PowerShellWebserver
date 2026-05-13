#Requires -Version 7.0
<#
.SYNOPSIS
    Client: GET /hello.ps1 — basic query-string call.

.DESCRIPTION
    Pairs with `webroot/hello.ps1`. Demonstrates:
        * the X-Api-Key header
        * passing typed parameters as query string (Name, Count, Loud)
        * inspecting the JSON envelope returned by .ps1 endpoints

.PARAMETER Name
    Display name passed to the server.

.PARAMETER Count
    How many times to repeat (1-10).

.PARAMETER Loud
    Pass -Loud to uppercase the greeting.

.EXAMPLE
    .\Invoke-Hello.ps1 -Name Anna -Count 3 -Loud
#>
param(
    [string] $Name = 'World',
    [int]    $Count = 1,
    [switch] $Loud
)

. $PSScriptRoot/_Common.ps1

$query = @{
    Name  = $Name
    Count = $Count
    Loud  = if ($Loud) { 'true' } else { 'false' }
}

$response = Invoke-Posh -Path '/hello.ps1' -Query $query
$response | Write-Envelope
