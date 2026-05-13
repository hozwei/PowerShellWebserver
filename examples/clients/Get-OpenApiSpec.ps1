#Requires -Version 7.0
<#
.SYNOPSIS
    Client: GET /openapi.json — fetch + summarise the auto-generated spec.

.DESCRIPTION
    /openapi.json returns an OpenAPI 3.1 document built on the fly from
    each webroot script's comment-based help and `param()` block.
    Importable into Swagger UI, Postman, API gateways, etc. The route
    is auth-exempt so discovery tooling does not need credentials.

    By default this client prints a compact, human-readable summary.
    Pass -Raw to dump the full JSON instead, or -OutFile <path> to save
    the spec to disk.

.PARAMETER Raw
    Print the raw OpenAPI document instead of a summary.

.PARAMETER OutFile
    Optional path to write the JSON to.

.EXAMPLE
    .\Get-OpenApiSpec.ps1
    .\Get-OpenApiSpec.ps1 -OutFile .\openapi.json
#>
param(
    [switch] $Raw,
    [string] $OutFile = ''
)

. $PSScriptRoot/_Common.ps1

$uri  = '{0}/openapi.json' -f (Get-PoshBaseUrl)
$body = (Invoke-WebRequest -Uri $uri -SkipHttpErrorCheck).Content

if ($OutFile) {
    [System.IO.File]::WriteAllText($OutFile, $body, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Spec written to: $OutFile"
}

if ($Raw) {
    Write-Host $body
    return
}

$spec = $body | ConvertFrom-Json -Depth 12
Write-Host ('openapi: {0}' -f $spec.openapi)
Write-Host ('title  : {0}' -f $spec.info.title)
Write-Host ('version: {0}' -f $spec.info.version)
Write-Host ''
Write-Host 'Paths:'
$paths = $spec.paths.PSObject.Properties | Sort-Object Name
foreach ($p in $paths) {
    $methods = ($p.Value.PSObject.Properties.Name | Sort-Object) -join ', '
    Write-Host ('  {0}  [{1}]' -f $p.Name, $methods.ToUpper())
    foreach ($mname in ($p.Value.PSObject.Properties.Name | Sort-Object)) {
        $op = $p.Value.$mname
        if ($op.summary) {
            Write-Host ('      {0}: {1}' -f $mname.ToUpper(), $op.summary)
        }
        foreach ($pp in @($op.parameters)) {
            $req = if ($pp.required) { '*' } else { ' ' }
            Write-Host ('        {0} {1}  in={2}  type={3}' -f $req, $pp.name, $pp.in, $pp.schema.type)
        }
    }
}
