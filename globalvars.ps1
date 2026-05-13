#Requires -Version 7.0
<#
.SYNOPSIS
    Central configuration for posh — single source of truth for static
    values and the AES key used to encrypt credentials in encrypted_pw/.

.DESCRIPTION
    Every webroot script dot-sources this file at the top:
        . (Join-Path $PSScriptRoot '..\globalvars.ps1')

    Change a hostname, a path, an LDAP DN here once and every endpoint
    picks it up on the next call.

.NOTES
    Secret storage
    --------------
    The $key below encrypts and decrypts every file in encrypted_pw\.
    Run `tools\Initialize-Globalvars.ps1` ONCE per install to replace
    the placeholder bytes below with 32 cryptographically random bytes
    that are unique to this deployment.

    Run `tools\Set-PoshSecret.ps1 -Label '<name>'` to store a password.

    Scripts that need a credential do this manually (no magic function):

        . (Join-Path $PSScriptRoot '..\globalvars.ps1')
        $cipher = (Get-Content -LiteralPath (Join-Path $PoshEncryptedDir 'encryptedString_ad_adsread.txt') -Raw).Trim()
        $secStr = ConvertTo-SecureString -String $cipher -Key $key
        $cred   = [PSCredential]::new('DOMAIN\reader', $secStr)

    Variables in this file are CONSUMED by every script that dot-sources
    it. PSScriptAnalyzer's "assigned but never used" warning is therefore
    suppressed below.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables are consumed by every script that dot-sources this file.')]
param()


# ===========================================================================
#  Section 1 — Service endpoints and identifiers
# ===========================================================================

# Active Directory
$DomainController     = 'dc-01.example.local'
$DomainDnsSuffix      = 'example.local'

# Mail / Exchange
$ExchangeServer       = 'mail.example.local'
$ExchangePsUri        = "https://$ExchangeServer/PowerShell/"
$SmtpRelay            = 'mail-relay.example.local'
$AdminMail            = 'it-admins@example.local'

# Virtualisation / Backup / Asset / Patching
$VCenterFqdn          = 'vcenter.example.local'
$VeeamBackupServer    = 'backup.example.local'
$LansweeperUri        = 'https://lansweeper.example.local/'
$WsusServer           = 'wsus.example.local'
$WsusPort             = 8531
$SccmSiteCode         = 'XYZ'

# posh itself
$PoshServerFqdn       = 'posh.example.local'
$PoshServerUri        = "https://$PoshServerFqdn"

# Ticketing
$JiraServerUri        = 'https://jira.example.local'

# LDAP base DNs
$LdapUsers            = 'OU=Users,DC=example,DC=local'
$LdapUsersDisabled    = 'OU=Disabled,OU=Users,DC=example,DC=local'
$LdapServers          = 'OU=Servers,DC=example,DC=local'
$LdapClients          = 'OU=Clients,DC=example,DC=local'
$LdapGroups           = 'OU=Groups,DC=example,DC=local'

# Common defaults
$DefaultTargetHost    = $env:COMPUTERNAME
$PasswordRetentionDays = 180


# ===========================================================================
#  Section 2 — Filesystem paths (derived from this file's location)
# ===========================================================================

$PoshBaseDir          = $PSScriptRoot
$PoshWebRoot          = Join-Path $PoshBaseDir 'webroot'
$PoshLogDir           = Join-Path $PoshBaseDir 'logs'
$PoshPostJsonDir      = Join-Path $PoshBaseDir 'postjson'
$PoshEncryptedDir     = Join-Path $PoshBaseDir 'encrypted_pw'
$PoshToolsDir         = Join-Path $PoshBaseDir 'tools'


# ===========================================================================
#  Section 3 — AES key for encrypted_pw\encryptedString_*.txt
#
#  Placeholder below. Run tools\Initialize-Globalvars.ps1 ONCE per install
#  to replace it with 32 cryptographically random bytes unique to this
#  deployment. Do NOT commit a personalised globalvars.ps1 with a real key.
# ===========================================================================

# >>>POSH_KEY_START<<<
$key = @(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
# >>>POSH_KEY_END<<<
