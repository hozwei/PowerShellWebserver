#Requires -Version 7.0
<#
.SYNOPSIS
    Specific 'admin' user handler — wins over the [id].ps1 placeholder.

.DESCRIPTION
    Sibling demo for the F9 placeholder route at `webroot/users/[id].ps1`.
    Because exact filenames take priority over placeholders, the URL
    `/users/admin` is served by THIS file, not by `[id].ps1` — letting
    you expose a richer handler for known cases while the parameterised
    route still covers everything else.

    To verify the priority:

        GET /users/admin   → this script, with the static admin payload
        GET /users/42      → [id].ps1, with -id '42'

.EXAMPLE
    Invoke-RestMethod -Uri 'http://localhost/users/admin' `
        -Headers @{ 'X-Api-Key' = 'your-key' }
#>

$ErrorActionPreference = 'Stop'

[ordered]@{
    id          = 'admin'
    name        = 'Administrator'
    role        = 'admin'
    privileges  = @('read', 'write', 'rotate-keys', 'view-audit')
    note        = 'Static handler — picked by exact-filename priority over the [id] placeholder route.'
    timestamp   = (Get-Date).ToString('o')
} | ConvertTo-Json -Depth 5
exit 0
