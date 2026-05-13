#Requires -Version 7.0
<#
.SYNOPSIS
    Demo endpoint for the F9 path-placeholder feature.

.DESCRIPTION
    Demonstrates Next.js-style REST routing — the [id] in the filename matches
    one URL segment and arrives in the script as the -id parameter. Only active
    when `PathPlaceholders = $true` is set in config.psd1; otherwise the URL
    /users/<anything> returns 404 (exact-match only).

    Call:
        GET /users/123                    → -id '123'
        GET /users/admin                  → -id 'admin'
        GET /users/123?detail=true        → -id '123' -detail 'true'

.PARAMETER id
    Captured value of the [id] placeholder segment in the URL path.

.PARAMETER detail
    Optional query-string parameter. When 'true', adds an extra `details` field.
#>
param(
    [string] $id     = '',
    [string] $detail = 'false'
)

$result = [ordered]@{
    user      = $id
    timestamp = (Get-Date).ToString('o')
}

if ($detail -eq 'true') {
    $result.details = [ordered]@{
        hostname = $env:COMPUTERNAME
        pid      = $PID
    }
}

$result | ConvertTo-Json -Depth 5 -Compress
exit 0
