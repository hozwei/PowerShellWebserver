#Requires -Version 7.0
<#
.SYNOPSIS
    REST endpoint for a single user, addressed by id (F9 placeholder).

.DESCRIPTION
    Demonstrates Next.js-style path placeholders. The `[id]` segment in
    the filename matches one URL path segment and arrives as `-id`.

        GET /users/123         → -id '123'
        GET /users/anna.smith  → -id 'anna.smith'

    Only enabled when `PathPlaceholders = $true` is set in `config.psd1`.
    With the feature off, the URL `/users/123` returns 404 (exact-match
    only) and the file is reachable only via the literal URL
    `/users/[id].ps1`.

    Exact-filename routes win over placeholders: `webroot/users/admin.ps1`
    will serve `/users/admin` instead of this script — that lets you
    define specific handlers alongside the parameterised one.

.PARAMETER id
    User id captured from the URL path. Required.

.PARAMETER Detail
    When 'true', includes a host info block alongside the basic record.
#>
param(
    [string] $id     = '',
    [string] $Detail = 'false'
)

$ErrorActionPreference = 'Stop'

# Two-level dot-source — this file lives at webroot/users/[id].ps1, so
# globalvars.ps1 is two directories up.
. (Join-Path $PSScriptRoot '..\..\globalvars.ps1')

$showDetail = $Detail -eq 'true' -or $Detail -eq '1'

if ([string]::IsNullOrWhiteSpace($id)) {
    Write-Error 'User id is required.'
    exit 1
}

# Toy in-script "DB". A real endpoint would query AD against $LdapUsers
# using credentials decrypted from encrypted_pw\ with the $key already
# in scope (both supplied by globalvars.ps1):
#
#   $cipher = (Get-Content "$PoshEncryptedDir\encryptedString_ad_adsread.txt" -Raw).Trim()
#   $secStr = ConvertTo-SecureString -String $cipher -Key $key
#   $cred   = [PSCredential]::new('DOMAIN\svc-adsread', $secStr)
#   Get-ADUser -Identity $id -SearchBase $LdapUsers -Credential $cred
$record = [ordered]@{
    id        = $id
    name      = "User-$id"
    domain    = $DomainDnsSuffix
    ldapBase  = $LdapUsers
    createdAt = (Get-Date).AddDays(-([math]::Abs($id.GetHashCode()) % 365)).ToString('yyyy-MM-dd')
    active    = ($id.GetHashCode() % 2) -eq 0
}

if ($showDetail) {
    $record.serverInfo = [ordered]@{
        host       = $env:COMPUTERNAME
        timestamp  = (Get-Date).ToString('o')
        pid        = $PID
    }
}

$record | ConvertTo-Json -Depth 5
exit 0
