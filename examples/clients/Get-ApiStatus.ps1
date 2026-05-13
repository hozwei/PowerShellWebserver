#Requires -Version 7.0
<#
.SYNOPSIS
    Client: GET /api-status.psxml — alternate-extension XML endpoint.

.DESCRIPTION
    Pairs with `webroot/api-status.psxml`. .psxml endpoints bypass the
    JSON envelope and return the script's stdout verbatim with
    Content-Type `text/xml`. This client uses Invoke-WebRequest so we
    can inspect the raw response, then parses the body as XML.

.EXAMPLE
    .\Get-ApiStatus.ps1
#>

. $PSScriptRoot/_Common.ps1

$uri = '{0}/api-status.psxml' -f (Get-PoshBaseUrl)
$headers = @{ 'X-Api-Key' = Get-PoshApiKey }
$response = Invoke-WebRequest -Uri $uri -Headers $headers -SkipHttpErrorCheck

Write-Host ('HTTP {0}' -f $response.StatusCode)
Write-Host ('Content-Type: {0}' -f $response.Headers['Content-Type'])
Write-Host ''
Write-Host '--- raw XML ---'
Write-Host $response.Content

# Parse + access individual fields. The response is a single <Result>
# document with nested <Items>/<Item>/<key>value</key> children.
[xml] $doc = $response.Content
Write-Host ''
Write-Host '--- parsed ---'
foreach ($item in $doc.Result.Items.Item) {
    foreach ($prop in $item.PSObject.Properties) {
        if ($prop.Name -in @('OuterXml','InnerXml','InnerText','HasChildNodes')) { continue }
        Write-Host ('  {0}: {1}' -f $prop.Name, $prop.Value)
    }
}
