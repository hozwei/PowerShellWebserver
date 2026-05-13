#Requires -Version 7.0
<#
.SYNOPSIS
    Generates 32 cryptographically random bytes and writes them as the
    `$key` array in globalvars.ps1. Run ONCE per installation.

.DESCRIPTION
    Replaces the placeholder block between `# >>>POSH_KEY_START<<<` and
    `# >>>POSH_KEY_END<<<` in globalvars.ps1 with a freshly-generated
    AES-256 key. Aborts when the existing key looks non-default unless
    -Force is passed — re-running this would invalidate every existing
    encrypted_pw\encryptedString_*.txt.

.PARAMETER GlobalvarsFile
    Path to globalvars.ps1. Defaults to the file next to the tools/ folder.

.PARAMETER Force
    Overwrite an existing non-default key. After this, every existing
    encryptedString_*.txt must be re-encrypted via Set-PoshSecret.ps1.

.EXAMPLE
    .\tools\Initialize-Globalvars.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $GlobalvarsFile = '',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($GlobalvarsFile)) {
    $GlobalvarsFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'globalvars.ps1'
}
if (-not (Test-Path -LiteralPath $GlobalvarsFile -PathType Leaf)) {
    Write-Host "ABORT: globalvars.ps1 not found at $GlobalvarsFile" -ForegroundColor Red
    exit 1
}

$content = [System.IO.File]::ReadAllText($GlobalvarsFile)

$startMarker = '# >>>POSH_KEY_START<<<'
$endMarker   = '# >>>POSH_KEY_END<<<'
$startIx     = $content.IndexOf($startMarker)
$endIx       = $content.IndexOf($endMarker)
if ($startIx -lt 0 -or $endIx -lt 0 -or $endIx -le $startIx) {
    Write-Host "ABORT: marker block not found. Expected '$startMarker' ... '$endMarker' in globalvars.ps1." -ForegroundColor Red
    exit 1
}

# Detect a non-placeholder key — bytes other than zeros means somebody already
# initialised this deployment and there are likely encrypted secrets in use.
$blockStart    = $startIx + $startMarker.Length
$existingBlock = $content.Substring($blockStart, $endIx - $blockStart)
$looksLikePlaceholder = $existingBlock -notmatch '\b[1-9]\d*\b'
if (-not $looksLikePlaceholder -and -not $Force) {
    Write-Host 'ABORT: $key already contains non-zero bytes (this install was already initialised).' -ForegroundColor Red
    Write-Host '       Re-running invalidates every encrypted_pw\encryptedString_*.txt under the current key.'
    Write-Host '       Re-run with -Force AFTER you have re-encrypted (or are willing to discard) the existing secrets.'
    exit 1
}

# Generate 32 random bytes via the system CSPRNG.
$bytes = [byte[]]::new(32)
$rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

# Build the replacement block. Indentation matches the rest of the file.
$keyArrayText = '$key = @(' + (($bytes | ForEach-Object { '{0}' -f $_ }) -join ', ') + ')'
$newBlock = "$startMarker`n$keyArrayText`n$endMarker"
$newContent = $content.Substring(0, $startIx) + $newBlock + $content.Substring($endIx + $endMarker.Length)

if ($PSCmdlet.ShouldProcess($GlobalvarsFile, 'Write new $key block')) {
    [System.IO.File]::WriteAllText($GlobalvarsFile, $newContent, [System.Text.UTF8Encoding]::new($false))
}

# Wipe the byte array from memory.
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0 }

Write-Host ''
Write-Host "OK: new random 32-byte key written to $GlobalvarsFile" -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host "  - Run tools\Set-PoshSecret.ps1 -Label '<name>' to store an encrypted password."
Write-Host "  - Do NOT commit a personalised globalvars.ps1 — it contains your unique key."
