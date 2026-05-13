#Requires -Version 7.0
<#
.SYNOPSIS
    Generates a personalised config.psd1 from the inline $cfg defaults of
    Start-WebServer.ps1. Run ONCE per installation.

.DESCRIPTION
    config.psd1 is the runtime source of truth for every posh server
    setting. Start-WebServer.ps1 hard-fails at startup when the file is
    missing.

    This script asks Start-WebServer.ps1 itself to dump its inline `$cfg`
    defaults via the internal `-DumpConfig` switch, then serialises the
    result as a fully-populated, human-readable .psd1 with section headers
    so a junior admin can review and tune the live configuration in one
    place.

    The generated file is gitignored — it is local to this installation.
    The inline `$cfg` block in Start-WebServer.ps1 remains the upstream
    schema; new versions introduce new keys there with a documented default
    and old config.psd1 files keep working (missing keys fall back to the
    inline default).

.PARAMETER ServerScript
    Path to Start-WebServer.ps1. Defaults to the file next to the tools/
    folder this script lives in.

.PARAMETER OutputFile
    Path where config.psd1 is written. Defaults to '<repo>\config.psd1'
    (i.e. next to Start-WebServer.ps1).

.PARAMETER Force
    Overwrite an existing config.psd1. The previous file is moved aside as
    config.psd1.bak.YYYYMMDD-HHmmss before the new one is written so a
    misclick can always be undone.

.EXAMPLE
    .\tools\Initialize-Config.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive setup tool — coloured Write-Host output is intended.')]
param(
    [string] $ServerScript = '',
    [string] $OutputFile   = '',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Resolve defaults relative to the repo root (= the directory ABOVE the tools
# folder this script lives in). All install layouts that follow the standard
# repo structure work without any -ServerScript / -OutputFile argument.
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ServerScript)) {
    $ServerScript = Join-Path $repoRoot 'Start-WebServer.ps1'
}
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $repoRoot 'config.psd1'
}

if (-not (Test-Path -LiteralPath $ServerScript -PathType Leaf)) {
    Write-Host "ABORT: Start-WebServer.ps1 not found at $ServerScript" -ForegroundColor Red
    exit 1
}

# Refuse early so the user does not pay the AST-parse / dump cost on a
# guaranteed abort. -Force prints a backup notice further down.
if ((Test-Path -LiteralPath $OutputFile -PathType Leaf) -and -not $Force) {
    Write-Host "ABORT: $OutputFile already exists." -ForegroundColor Red
    Write-Host '       Re-run with -Force to overwrite (the existing file is backed up first).'
    exit 1
}

# ---------------------------------------------------------------------------
# Ask Start-WebServer.ps1 for its inline defaults. -DumpConfig prints the
# fully-derived $cfg as compact JSON to stdout and exits. Running it as a
# fresh pwsh subprocess keeps the listener / RunspacePool / mutexes from
# being created in this process.
# ---------------------------------------------------------------------------
$pwshExe = (Get-Process -Id $PID).MainModule.FileName
$json    = & $pwshExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ServerScript -DumpConfig
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    Write-Host "ABORT: Start-WebServer.ps1 -DumpConfig failed (exit $LASTEXITCODE)." -ForegroundColor Red
    if ($json) { Write-Host $json }
    exit 1
}

try {
    $defaults = $json | ConvertFrom-Json -AsHashtable -Depth 20
} catch {
    Write-Host "ABORT: -DumpConfig output is not valid JSON: $_" -ForegroundColor Red
    exit 1
}
if ($null -eq $defaults -or $defaults.Count -eq 0) {
    Write-Host 'ABORT: -DumpConfig returned an empty hashtable.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Group ordering: each entry collects related keys under a section header
# so the generated file reads like a curated config rather than an
# alphabetical dump. Keys not listed in any group are appended under
# "Other" so a future $cfg key still appears in the output even if this
# table has not been updated yet.
# ---------------------------------------------------------------------------
$GROUP_ORDER = @(
    @{ Title = 'HTTP / HTTPS endpoints';     Keys = @('HttpsEnabled', 'HttpPort', 'HttpsPort', 'Prefixes') }
    @{ Title = 'Filesystem paths';           Keys = @('WebRoot', 'LogDir', 'PwshExe', 'PostJsonDir', 'PostJsonRetentionDays') }
    @{ Title = 'Authentication';             Keys = @('ApiKey', 'ApiKeys', 'AuthMode', 'BasicAuthUser', 'BasicAuthPass', 'BasicAuthRealm') }
    @{ Title = 'Script execution';           Keys = @('ExecutionMode', 'InjectContextVars', 'ScriptTimeoutSec', 'MaxConcurrent', 'MaxRequestBodyBytes', 'AcceptedContentTypes', 'ScriptExtensionMap') }
    @{ Title = 'Rate limiting';              Keys = @('RateLimitRequests', 'RateLimitWindowSec', 'RateLimitPenaltySec', 'RateLimitMode', 'RateLimitPerIdentity', 'RateLimitQueueTimeoutSec', 'RateLimitExemptPaths', 'MinRequestIntervalSec') }
    @{ Title = 'IP filtering';               Keys = @('AllowedIPs', 'BlockedIPs') }
    @{ Title = 'Logging';                    Keys = @('LogRetentionDays', 'LogIntegrityHash', 'LogSchedule', 'LogFormat', 'AuditLogEnabled', 'AuditLogFile', 'SlowRequestThresholdMs', 'SlowLogFile') }
    @{ Title = 'Compression';                Keys = @('GzipEnabled', 'BrotliEnabled', 'GzipMinBytes', 'GzipMaxBytes', 'GzipMimeTypes') }
    @{ Title = 'Static serving';             Keys = @('StaticServingEnabled', 'StaticRoot', 'DefaultDocuments', 'StaticCacheHeaders', 'BlockedMimeTypes', 'MimeTypeMap') }
    @{ Title = 'Sessions and cookies';       Keys = @('SessionEnabled', 'SessionCookieName') }
    @{ Title = 'CORS';                       Keys = @('CorsAllowedOrigins', 'CorsAllowedMethods', 'CorsAllowedHeaders', 'CorsAllowCredentials', 'CorsMaxAgeSec') }
    @{ Title = 'PHP CGI';                    Keys = @('PhpCgiEnabled', 'PhpCgiPath', 'PhpCgiTimeoutSec') }
    @{ Title = 'Custom error pages';         Keys = @('CustomErrorPages', 'ErrorPagesRoot') }
    @{ Title = 'Background jobs';            Keys = @('BackgroundJobs', 'JobsLogFile') }
    @{ Title = 'Directory browsing';         Keys = @('DirectoryBrowsing', 'DirectoryBrowsingHidden') }
    @{ Title = 'Discovery and metadata';     Keys = @('IndexShowMetadata', 'PromMetricsEnabled', 'PathPlaceholders', 'OpenApiEnabled', 'OpenApiTitle', 'OpenApiVersion') }
)

# Hashtable keys that are not bareword PowerShell identifiers (anything
# starting with a digit or containing punctuation, e.g. '.ps1') must be
# quoted in psd1 — bareword '.ps1' is a parse error.
function Format-PsdKey {
    param([string] $Key)
    if ($Key -match '^[A-Za-z_][A-Za-z0-9_]*$') { return $Key }
    return "'" + ($Key -replace "'", "''") + "'"
}

# ---------------------------------------------------------------------------
# psd1 literal serializer. Renders bool / int / string / array / hashtable
# in a form Import-PowerShellDataFile parses back. No code execution paths
# are emitted — strings are single-quoted with '' escaping, $null becomes
# an empty string (every $cfg key with a nullable default treats '' the
# same way at runtime).
# ---------------------------------------------------------------------------
function ConvertTo-PsdLiteral {
    param(
        $Value,
        [int] $Indent = 1
    )
    $pad = '    ' * $Indent
    if ($null -eq $Value) { return "''" }
    if ($Value -is [bool]) {
        if ($Value) { return '$true' } else { return '$false' }
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int64] -or $Value -is [int16] -or $Value -is [byte]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) {
        return "'" + ($Value -replace "'", "''") + "'"
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '@{}' }
        $keys      = @($Value.Keys)
        $formatted = $keys | ForEach-Object { Format-PsdKey $_.ToString() }
        $maxKeyLen = ($formatted | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        $items     = for ($i = 0; $i -lt $keys.Count; $i++) {
            $rendered = ConvertTo-PsdLiteral -Value $Value[$keys[$i]] -Indent ($Indent + 1)
            $pad + '    ' + $formatted[$i].PadRight($maxKeyLen) + ' = ' + $rendered
        }
        $closingPad = '    ' * ($Indent - 1)
        return '@{' + [System.Environment]::NewLine + ($items -join [System.Environment]::NewLine) + [System.Environment]::NewLine + $closingPad + '    }'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = @($Value)
        if ($list.Count -eq 0) { return '@()' }
        $items = foreach ($item in $list) { ConvertTo-PsdLiteral -Value $item -Indent ($Indent + 1) }
        $oneLine = '@(' + ($items -join ', ') + ')'
        if ($oneLine.Length -le 100) { return $oneLine }
        $closingPad = '    ' * ($Indent - 1)
        $inner      = ($items | ForEach-Object { $pad + '    ' + $_ }) -join (',' + [System.Environment]::NewLine)
        return '@(' + [System.Environment]::NewLine + $inner + [System.Environment]::NewLine + $closingPad + '    )'
    }
    # Fallback — should not be reached for ConvertFrom-Json -AsHashtable output.
    return "'" + ($Value.ToString() -replace "'", "''") + "'"
}

# ---------------------------------------------------------------------------
# Build the file body group by group.
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$lines = [System.Collections.Generic.List[string]]::new()
$null  = $lines.Add("# ---------------------------------------------------------------------------")
$null  = $lines.Add("#  posh runtime configuration — generated by tools\Initialize-Config.ps1")
$null  = $lines.Add("#  on $timestamp from Start-WebServer.ps1.")
$null  = $lines.Add("#")
$null  = $lines.Add("#  This file is the runtime source of truth for the posh server. The")
$null  = $lines.Add("#  server hard-fails at startup when it is missing. Every key from the")
$null  = $lines.Add("#  inline `$cfg block in Start-WebServer.ps1 is materialised here with")
$null  = $lines.Add("#  its current default so a junior admin can review and tune the live")
$null  = $lines.Add("#  configuration in one place.")
$null  = $lines.Add("#")
$null  = $lines.Add("#  The file is gitignored — keep it local to this installation. The")
$null  = $lines.Add("#  inline `$cfg block remains the upstream schema; new versions introduce")
$null  = $lines.Add("#  new keys there with a documented default and old config.psd1 files keep")
$null  = $lines.Add("#  working (missing keys fall back to the inline default).")
$null  = $lines.Add("#")
$null  = $lines.Add("#  Edit safely via:")
$null  = $lines.Add("#    .\tools\Edit-PoshSettings.ps1     # browser-based editor (recommended)")
$null  = $lines.Add("#    notepad .\config.psd1             # direct edit")
$null  = $lines.Add("#")
$null  = $lines.Add("#  After saving, restart the Scheduled Task for changes to take effect:")
$null  = $lines.Add("#    Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'")
$null  = $lines.Add("#    Start-ScheduledTask -TaskName 'PowerShell-Webserver'")
$null  = $lines.Add("# ---------------------------------------------------------------------------")
$null  = $lines.Add('')
$null  = $lines.Add('@{')

# Compute the global key-padding width once so every key line aligns the
# same way across all groups. Otherwise the eye jumps between groups.
$allKeys     = @($defaults.Keys)
$globalKeyW  = ($allKeys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
$emittedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Write-Group {
    param(
        [string]   $Title,
        [string[]] $Keys,
        [hashtable] $Source,
        [int]      $KeyWidth,
        [System.Collections.Generic.List[string]] $Out,
        [System.Collections.Generic.HashSet[string]] $Seen
    )
    $present = @($Keys | Where-Object { $Source.ContainsKey($_) -and -not $Seen.Contains($_) })
    if ($present.Count -eq 0) { return }
    $null = $Out.Add('')
    $null = $Out.Add("    # -- $Title " + ('-' * [Math]::Max(3, 70 - $Title.Length)))
    foreach ($k in $present) {
        $rendered = ConvertTo-PsdLiteral -Value $Source[$k] -Indent 1
        $formatted = Format-PsdKey $k
        $null = $Out.Add('    ' + $formatted.PadRight($KeyWidth) + ' = ' + $rendered)
        $null = $Seen.Add($k)
    }
}

foreach ($g in $GROUP_ORDER) {
    Write-Group -Title $g.Title -Keys $g.Keys -Source $defaults -KeyWidth $globalKeyW -Out $lines -Seen $emittedKeys
}

# Forward-compat: any keys present in the dump but not listed in
# $GROUP_ORDER land in a final "Other" group so future $cfg additions
# still appear in the output without requiring this tool to be patched
# in lockstep with the server.
$leftover = @($defaults.Keys | Where-Object { -not $emittedKeys.Contains($_) } | Sort-Object)
if ($leftover.Count -gt 0) {
    Write-Group -Title 'Other (newer keys not yet grouped)' -Keys $leftover -Source $defaults -KeyWidth $globalKeyW -Out $lines -Seen $emittedKeys
}

$null = $lines.Add('}')
$null = $lines.Add('')

# ---------------------------------------------------------------------------
# Backup an existing file and write the new one. UTF-8 without BOM matches
# the convention from tools\Initialize-Globalvars.ps1. Rotate so only the
# last 5 backups stick around — otherwise repeated -Force runs leave a
# growing trail of config.psd1.bak.* in the repo root.
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $OutputFile -PathType Leaf) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$OutputFile.bak.$stamp"
    Move-Item -LiteralPath $OutputFile -Destination $backup -Force
    Write-Host "Existing config.psd1 backed up to $backup" -ForegroundColor Yellow

    $dir     = Split-Path -Parent $OutputFile
    $name    = Split-Path -Leaf   $OutputFile
    $allBaks = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$name.bak.*" } |
                Sort-Object Name -Descending)
    if ($allBaks.Count -gt 5) {
        foreach ($old in $allBaks | Select-Object -Skip 5) {
            try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop } catch { $null = $_ }
        }
    }
}

$body = ($lines -join [System.Environment]::NewLine)
if ($PSCmdlet.ShouldProcess($OutputFile, 'Write generated config.psd1')) {
    [System.IO.File]::WriteAllText($OutputFile, $body, [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Self-verify: re-parse what we just wrote so a serializer regression cannot
# leave the install with a broken config that fails at server startup.
# ---------------------------------------------------------------------------
try {
    $check = Import-PowerShellDataFile -LiteralPath $OutputFile
} catch {
    Write-Host "WARNING: generated config.psd1 cannot be re-parsed by Import-PowerShellDataFile: $_" -ForegroundColor Red
    Write-Host '         Inspect the file and report this as a bug in tools\Initialize-Config.ps1.'
    exit 1
}

Write-Host ''
Write-Host "OK: config.psd1 written to $OutputFile ($($check.Count) keys)" -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  - Review the file and adjust values for this install.'
Write-Host '  - Restart the Scheduled Task for changes to apply.'
