#Requires -Version 7.0
<#
.SYNOPSIS
    IO layer for Edit-PoshSettings.ps1.

.DESCRIPTION
    Reads and writes globalvars.ps1 / config.psd1 in a way that preserves
    surrounding comments and whitespace. AST-based so we never depend on
    fragile per-key regex patterns. Also handles AES key generation,
    encrypted-secret storage, and POSH_API_KEY env-var management.

    All writes go through a path whitelist seeded from the repository
    root — defense-in-depth in case the route layer is ever bypassed.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module-level state. The host script (Edit-PoshSettings.ps1) calls
# Initialize-PoshSettingsIO once so the path whitelist is anchored to the
# real install — every other public function consults $script:state.
# ---------------------------------------------------------------------------
$script:state = $null

function Initialize-PoshSettingsIO {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )
    $resolvedRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "RepoRoot does not exist: $resolvedRoot"
    }
    $script:state = [pscustomobject]@{
        RepoRoot       = $resolvedRoot
        Globalvars     = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot 'globalvars.ps1'))
        ConfigPsd1     = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot 'config.psd1'))
        EncryptedDir   = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot 'encrypted_pw'))
    }
}

function Get-PoshIoState {
    if ($null -eq $script:state) {
        throw 'PoshSettingsIO is not initialised. Call Initialize-PoshSettingsIO first.'
    }
    return $script:state
}

# ---------------------------------------------------------------------------
# Path whitelist — only the three known targets may be written. Encrypted
# secrets are pattern-matched (encryptedString_<label>.txt) under the
# encrypted_pw directory. Any other path is a bug or a route-layer escape.
# ---------------------------------------------------------------------------
function Test-PoshIoTarget {
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Path)
    $s = Get-PoshIoState
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved -ieq $s.Globalvars) { return $true }
    if ($resolved -ieq $s.ConfigPsd1) { return $true }
    # Backup siblings of the two managed files. The stamp pattern is the
    # one Backup-PoshFile writes; anything outside that suffix is rejected
    # so an attacker who somehow reached this layer can't aim at arbitrary
    # paths.
    if ($resolved -match '^(.+)\.bak\.[0-9]{8}-[0-9]{6}$') {
        $base = $matches[1]
        if ($base -ieq $s.Globalvars) { return $true }
        if ($base -ieq $s.ConfigPsd1) { return $true }
    }
    $encPrefix = $s.EncryptedDir + [System.IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($encPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        ($resolved -match 'encryptedString_[A-Za-z0-9_-]+\.txt$')) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Backup catalogue + read/restore helpers used by the Setup tab.
# ---------------------------------------------------------------------------
function Get-PoshBackupList {
    [OutputType([hashtable])]
    param()
    $s = Get-PoshIoState
    $out = @{}
    foreach ($entry in @(
        @{ Logical = 'globalvars.ps1'; Path = $s.Globalvars }
        @{ Logical = 'config.psd1';    Path = $s.ConfigPsd1 }
    )) {
        $dir  = Split-Path -Parent $entry.Path
        $name = Split-Path -Leaf   $entry.Path
        $list = [System.Collections.Generic.List[hashtable]]::new()
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match ("^" + [regex]::Escape($name) + "\.bak\.([0-9]{8}-[0-9]{6})$") } |
                Sort-Object Name -Descending
            foreach ($f in $files) {
                $null = $matches  # touch automatic var so strict mode is happy
                if ($f.Name -match ("^" + [regex]::Escape($name) + "\.bak\.([0-9]{8}-[0-9]{6})$")) {
                    $stamp = $matches[1]
                    $iso   = try {
                        [datetime]::ParseExact($stamp, 'yyyyMMdd-HHmmss', $null).ToString('yyyy-MM-dd HH:mm:ss')
                    } catch { $stamp }
                    $null = $list.Add(@{
                        Stamp     = $stamp
                        Displayed = $iso
                        SizeBytes = $f.Length
                    })
                }
            }
        }
        $out[$entry.Logical] = @($list)
    }
    return $out
}

function Read-PoshBackup {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateSet('globalvars.ps1','config.psd1')] [string] $File,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9]{8}-[0-9]{6}$')] [string] $Stamp,
        [int] $MaxBytes = 262144
    )
    $s = Get-PoshIoState
    $base = if ($File -eq 'globalvars.ps1') { $s.Globalvars } else { $s.ConfigPsd1 }
    $backupPath = "$base.bak.$Stamp"
    Assert-PoshIoTarget -Path $backupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "Backup not found: $File @ $Stamp"
    }
    $info = Get-Item -LiteralPath $backupPath
    if ($info.Length -gt $MaxBytes) {
        throw ("Backup is too large to preview ({0} bytes > {1} cap)" -f $info.Length, $MaxBytes)
    }
    return [System.IO.File]::ReadAllText($backupPath, [System.Text.UTF8Encoding]::new($false))
}

function Restore-PoshBackup {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateSet('globalvars.ps1','config.psd1')] [string] $File,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9]{8}-[0-9]{6}$')] [string] $Stamp
    )
    $s = Get-PoshIoState
    $current = if ($File -eq 'globalvars.ps1') { $s.Globalvars } else { $s.ConfigPsd1 }
    $backupPath = "$current.bak.$Stamp"
    Assert-PoshIoTarget -Path $backupPath
    Assert-PoshIoTarget -Path $current
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "Backup not found: $File @ $Stamp"
    }
    # Always back up the current file before overwriting so a misclick is
    # recoverable. Pruning is handled by Backup-PoshFile's rotation.
    $newBackup = $null
    if ($PSCmdlet.ShouldProcess($current, "Pre-restore backup")) {
        $newBackup = Backup-PoshFile -FilePath $current
    }
    if ($PSCmdlet.ShouldProcess($current, "Restore from $Stamp")) {
        Copy-Item -LiteralPath $backupPath -Destination $current -Force
    }
    return @{
        File          = $File
        RestoredStamp = $Stamp
        PreBackup     = $newBackup
    }
}

function Assert-PoshIoTarget {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-PoshIoTarget -Path $Path)) {
        throw "Path is not on the IO whitelist: $Path"
    }
}

# ---------------------------------------------------------------------------
# File backup. Copies <name> to <name>.bak.YYYYMMDD-HHmmss and prunes
# older backups to keep the directory tidy.
# ---------------------------------------------------------------------------
function Backup-PoshFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [int] $Keep = 5
    )
    Assert-PoshIoTarget -Path $FilePath
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $null }
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$FilePath.bak.$stamp"
    if ($PSCmdlet.ShouldProcess($FilePath, "Backup to $backup")) {
        Copy-Item -LiteralPath $FilePath -Destination $backup -Force
    }
    $dir  = Split-Path -Parent $FilePath
    $name = Split-Path -Leaf $FilePath
    $existing = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$name.bak.*" } |
        Sort-Object Name -Descending)
    if ($existing.Count -gt $Keep) {
        foreach ($old in $existing | Select-Object -Skip $Keep) {
            if ($PSCmdlet.ShouldProcess($old.FullName, 'Remove old backup')) {
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $backup
}

# ---------------------------------------------------------------------------
# Read globalvars.ps1: parse, return a hashtable of {VarName = current
# string-or-int value}. Uses Import-Module-style isolation: dot-source
# into a private scope and snapshot the variables.
# ---------------------------------------------------------------------------
function Get-PoshGlobalvarValues {
    [OutputType([hashtable])]
    param([string[]] $Names)
    $s = Get-PoshIoState
    if (-not (Test-Path -LiteralPath $s.Globalvars -PathType Leaf)) {
        throw "globalvars.ps1 not found: $($s.Globalvars)"
    }
    # Run dot-source inside a transient scriptblock so the variables it
    # creates are local to that scope (they otherwise leak into the
    # module's $script: scope and stay there).
    $scriptBlock = {
        param([string] $Path, [string[]] $Wanted)
        . $Path
        $out = @{}
        foreach ($n in $Wanted) {
            $v = Get-Variable -Name $n -ValueOnly -ErrorAction SilentlyContinue
            if ($null -ne $v) { $out[$n] = $v }
        }
        return $out
    }
    return & $scriptBlock $s.Globalvars $Names
}

# ---------------------------------------------------------------------------
# Private RHS-AST helpers. Used by Get-PoshGlobalvarDefinitions and
# Add-PoshGlobalvar to figure out whether a variable's right-hand side is
# a plain literal we can safely edit, or a computed expression we should
# leave alone (Join-Path, $env:..., interpolated strings).
# ---------------------------------------------------------------------------
function Get-PoshRhsExpression {
    param($RhsStatement)
    $r = $RhsStatement
    if ($r -is [System.Management.Automation.Language.PipelineAst]) {
        if ($r.PipelineElements.Count -ne 1) { return $null }
        $r = $r.PipelineElements[0]
    }
    if ($r -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return $r.Expression
    }
    return $r
}

function Get-PoshRhsTypeInfo {
    param($RhsStatement)
    $expr = Get-PoshRhsExpression -RhsStatement $RhsStatement
    if ($null -eq $expr) { return @{ Type = 'string'; IsLiteral = $false } }

    if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return @{ Type = 'string'; IsLiteral = $true }
    }
    if ($expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        # Interpolation makes this a derived value — read-only in the editor.
        $nested = @($expr.NestedExpressions)
        if ($nested.Count -eq 0) { return @{ Type = 'string'; IsLiteral = $true } }
        return @{ Type = 'string'; IsLiteral = $false }
    }
    if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        $v = $expr.Value
        if ($v -is [int] -or $v -is [long] -or $v -is [int32] -or $v -is [int64]) {
            return @{ Type = 'int'; IsLiteral = $true }
        }
        if ($v -is [bool]) { return @{ Type = 'bool'; IsLiteral = $true } }
        return @{ Type = 'string'; IsLiteral = $true }
    }
    if ($expr -is [System.Management.Automation.Language.ArrayLiteralAst] -or
        $expr -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        return @{ Type = 'string-array'; IsLiteral = $true }
    }
    # Variable refs ($env:COMPUTERNAME), Join-Path, member access, etc.
    return @{ Type = 'string'; IsLiteral = $false }
}

# ---------------------------------------------------------------------------
# AST-scan globalvars.ps1 for top-level $Var = ... assignments. Returns
# one entry per actually-defined variable with the type inferred from the
# RHS literal (string, int, bool, string-array). Variables with computed
# right-hand sides (Join-Path, $env:..., interpolated strings) are
# returned with IsLiteral=$false so the caller can show them read-only.
#
# This is the dynamic source of truth: deleting a $Var line in globalvars.ps1
# removes the variable from the editor on the next load; adding a new line
# makes it appear automatically.
# ---------------------------------------------------------------------------
function Get-PoshGlobalvarDefinitions {
    [OutputType([hashtable[]])]
    param()
    $s = Get-PoshIoState
    if (-not (Test-Path -LiteralPath $s.Globalvars -PathType Leaf)) { return @() }
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.Globalvars, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        throw "globalvars.ps1 has parse errors — fix manually first."
    }
    $defs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($stmt in $ast.EndBlock.Statements) {
        if ($stmt -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
        if ($stmt.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $name = $stmt.Left.VariablePath.UserPath
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name -eq 'key') { continue }   # AES key — managed via setup helper
        $info = Get-PoshRhsTypeInfo -RhsStatement $stmt.Right
        $null = $defs.Add(@{
            Name      = $name
            Type      = $info.Type
            IsLiteral = $info.IsLiteral
            RawText   = $stmt.Right.Extent.Text
        })
    }
    return @($defs)
}

# ---------------------------------------------------------------------------
# Append a new $Var = ... assignment to globalvars.ps1. Placed right after
# the last literal top-level assignment so it lands in "Section 1"
# (service endpoints + LDAP) rather than between the path-derivation
# lines or after the AES key marker.
# ---------------------------------------------------------------------------
function Add-PoshGlobalvar {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')] [string] $Name,
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [ValidateSet('string','int','string-array','bool')] [string] $Type
    )
    $s = Get-PoshIoState
    Assert-PoshIoTarget -Path $s.Globalvars
    if (-not (Test-Path -LiteralPath $s.Globalvars -PathType Leaf)) {
        throw "globalvars.ps1 not found: $($s.Globalvars)"
    }
    if ($Name -eq 'key') { throw 'Refusing to overwrite $key via Add-PoshGlobalvar — use the AES-key setup helper instead.' }
    $existing = @(Get-PoshGlobalvarDefinitions | Where-Object { $_.Name -eq $Name })
    if ($existing.Count -gt 0) {
        throw "Variable '`$$Name' already exists. Edit it instead."
    }
    $literal = ConvertTo-PoshLiteral -Value $Value -Type $Type
    $line    = '$' + $Name + ' = ' + $literal

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.Globalvars, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { throw 'globalvars.ps1 has parse errors — fix manually first.' }

    # We want to land at the END of Section 1 (service endpoints) and
    # BEFORE Section 2 (filesystem paths derived from $PSScriptRoot).
    #
    # Old approach broke on the first non-literal in Section 1 — but the
    # baseline contains `$PoshServerUri = "https://$PoshServerFqdn"` in
    # the middle of Section 1, which is non-literal (interpolated). So we
    # used to insert between $PoshServerFqdn and $PoshServerUri instead
    # of after the LDAP block.
    #
    # New approach: first locate the first path-derivation statement
    # (anything whose RHS text mentions $PSScriptRoot or Join-Path —
    # those are the Section-2 markers). Then walk all statements before
    # that boundary and remember the last LITERAL one. Non-literals in
    # Section 1 ($PoshServerUri, $DefaultTargetHost) are skipped but no
    # longer truncate the scan.
    $sectionTwoStart = $null
    foreach ($stmt in $ast.EndBlock.Statements) {
        if ($stmt -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
        if ($stmt.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        if ($stmt.Right.Extent.Text -match '\$PSScriptRoot|Join-Path') {
            $sectionTwoStart = $stmt.Extent.StartOffset
            break
        }
    }
    $lastLiteralAssign = $null
    foreach ($stmt in $ast.EndBlock.Statements) {
        if ($stmt -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
        if ($stmt.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $n = $stmt.Left.VariablePath.UserPath
        if ($n -eq 'key') { continue }
        if ($null -ne $sectionTwoStart -and $stmt.Extent.StartOffset -ge $sectionTwoStart) { break }
        $info = Get-PoshRhsTypeInfo -RhsStatement $stmt.Right
        if ($info.IsLiteral) { $lastLiteralAssign = $stmt }
    }

    $content = [System.IO.File]::ReadAllText($s.Globalvars)
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }

    if ($lastLiteralAssign) {
        # Insert a blank line + the new statement right after the last
        # Section 1 assignment. EndOffset is after the value AST; we then
        # walk forward past any same-line trailing comment + line break so
        # we slot in between two lines rather than mid-line.
        $insertAt = $lastLiteralAssign.Extent.EndOffset
        while ($insertAt -lt $content.Length -and $content[$insertAt] -notin @("`r","`n")) { $insertAt++ }
        if ($insertAt -lt $content.Length -and $content[$insertAt] -eq "`r") { $insertAt++ }
        if ($insertAt -lt $content.Length -and $content[$insertAt] -eq "`n") { $insertAt++ }
        $newContent = $content.Substring(0, $insertAt) + $line + $newline + $content.Substring($insertAt)
    } else {
        $keyMark = '# >>>POSH_KEY_START<<<'
        $idx = $content.IndexOf($keyMark)
        if ($idx -ge 0) {
            $before = $content.Substring(0, $idx).TrimEnd()
            $newContent = $before + $newline + $newline + $line + $newline + $newline + $newline + $content.Substring($idx)
        } else {
            $newContent = $content.TrimEnd() + $newline + $newline + $line + $newline
        }
    }

    # All validations passed — backup, then write. Doing the backup
    # AFTER validation avoids littering disk with orphan .bak files
    # for invalid add attempts (e.g. duplicate name).
    $bk = $null
    if ($PSCmdlet.ShouldProcess($s.Globalvars, "Backup + add `$$Name = $literal")) {
        $bk = Backup-PoshFile -FilePath $s.Globalvars
        [System.IO.File]::WriteAllText($s.Globalvars, $newContent, [System.Text.UTF8Encoding]::new($false))
    }
    return @{ Name = $Name; Backup = $bk }
}

# ---------------------------------------------------------------------------
# Delete one top-level $Var = ... line (and its trailing newline) from
# globalvars.ps1. Refuses to remove $key. Refuses if the variable is
# computed (likely a path-derivation in Section 2 — let the user know,
# don't silently nuke). Refuses if the same name is assigned more than
# once so we never guess which line to drop.
# ---------------------------------------------------------------------------
function Remove-PoshGlobalvar {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name)
    $s = Get-PoshIoState
    Assert-PoshIoTarget -Path $s.Globalvars
    if ($Name -eq 'key') { throw 'Refusing to remove $key — use the setup helper instead.' }

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.Globalvars, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { throw 'globalvars.ps1 has parse errors — fix manually first.' }

    # $matches is a PowerShell automatic variable — using $assignments
    # avoids any future -match / -replace in this function silently
    # overwriting the AST reference.
    $assignments = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $_.Left.VariablePath.UserPath -eq $Name
    })
    if ($assignments.Count -eq 0) { throw "Variable '`$$Name' not found at top level of globalvars.ps1." }
    if ($assignments.Count -gt 1) { throw "Variable '`$$Name' has multiple assignments — refusing to guess which one to remove." }

    $stmt = $assignments[0]
    $info = Get-PoshRhsTypeInfo -RhsStatement $stmt.Right
    if (-not $info.IsLiteral) {
        throw "Variable '`$$Name' is computed (e.g. Join-Path or `$env:...). Edit globalvars.ps1 by hand if you really want to remove it."
    }

    $content = [System.IO.File]::ReadAllText($s.Globalvars)
    $start   = $stmt.Extent.StartOffset
    $end     = $stmt.Extent.EndOffset
    # Walk start back to beginning of the line (after the previous newline)
    while ($start -gt 0 -and $content[$start - 1] -ne "`n") { $start-- }
    # Walk end forward past any trailing comment + line terminator(s)
    while ($end -lt $content.Length -and $content[$end] -notin @("`r","`n")) { $end++ }
    if ($end -lt $content.Length -and $content[$end] -eq "`r") { $end++ }
    if ($end -lt $content.Length -and $content[$end] -eq "`n") { $end++ }

    $newContent = $content.Substring(0, $start) + $content.Substring($end)

    # All validations passed — backup, then write. Routes no longer back
    # up separately, so a refused-to-remove call doesn't leave an orphan
    # .bak file every time the user clicks the X on a computed field.
    $bk = $null
    if ($PSCmdlet.ShouldProcess($s.Globalvars, "Backup + remove `$$Name")) {
        $bk = Backup-PoshFile -FilePath $s.Globalvars
        [System.IO.File]::WriteAllText($s.Globalvars, $newContent, [System.Text.UTF8Encoding]::new($false))
    }
    return @{ Name = $Name; Backup = $bk }
}

# ---------------------------------------------------------------------------
# Read config.psd1 via Import-PowerShellDataFile (no script execution).
# ---------------------------------------------------------------------------
function Get-PoshConfigValues {
    [OutputType([hashtable])]
    param()
    $s = Get-PoshIoState
    if (-not (Test-Path -LiteralPath $s.ConfigPsd1 -PathType Leaf)) {
        throw "config.psd1 not found: $($s.ConfigPsd1) — run tools\Initialize-PoshConfig.ps1 first"
    }
    return Import-PowerShellDataFile -LiteralPath $s.ConfigPsd1
}

# ---------------------------------------------------------------------------
# Status of POSH_API_KEY. We never expose the key itself — only whether
# it is set, and how long it is, so the UI can surface "configured: yes,
# 24 chars" without leaking the secret.
# ---------------------------------------------------------------------------
function Get-PoshApiKeyStatus {
    [OutputType([hashtable])]
    param()
    $machine = [Environment]::GetEnvironmentVariable('POSH_API_KEY', 'Machine')
    $process = $env:POSH_API_KEY
    return @{
        SetMachine  = -not [string]::IsNullOrEmpty($machine)
        SetProcess  = -not [string]::IsNullOrEmpty($process)
        LengthChars = if ($machine) { $machine.Length } else { 0 }
    }
}

# ---------------------------------------------------------------------------
# Status of the AES $key in globalvars.ps1. "Initialised" means the byte
# array contains at least one non-zero byte — placeholder is all zeros.
# ---------------------------------------------------------------------------
function Get-PoshAesKeyStatus {
    [OutputType([hashtable])]
    param()
    $s = Get-PoshIoState
    if (-not (Test-Path -LiteralPath $s.Globalvars -PathType Leaf)) {
        return @{ Initialised = $false; Reason = 'globalvars.ps1 missing' }
    }
    $vars = Get-PoshGlobalvarValues -Names @('key')
    if (-not $vars.ContainsKey('key')) {
        return @{ Initialised = $false; Reason = '$key not defined' }
    }
    $bytes = @($vars['key'])
    $nonZero = @($bytes | Where-Object { $_ -ne 0 }).Count
    return @{
        Initialised = ($nonZero -gt 0)
        ByteLength  = $bytes.Count
    }
}

# ---------------------------------------------------------------------------
# List existing encrypted secret files (just labels, never content).
# ---------------------------------------------------------------------------
function Get-PoshSecretList {
    [OutputType([string[]])]
    param()
    $s = Get-PoshIoState
    if (-not (Test-Path -LiteralPath $s.EncryptedDir -PathType Container)) {
        return @()
    }
    $files = Get-ChildItem -LiteralPath $s.EncryptedDir -File -Filter 'encryptedString_*.txt' -ErrorAction SilentlyContinue
    return @(
        $files | ForEach-Object {
            if ($_.BaseName -match '^encryptedString_(.+)$') { $Matches[1] }
        } | Where-Object { $_ } | Sort-Object
    )
}

# ---------------------------------------------------------------------------
# Render a typed value as a psd1 / PowerShell literal. Strings get single
# quotes with internal '' escaping. Arrays get @(...) on one line for
# Initialize-PoshConfig compatibility (the diff stays minimal).
# ---------------------------------------------------------------------------
function ConvertTo-PoshLiteral {
    [OutputType([string])]
    param(
        $Value,
        [Parameter(Mandatory)] [string] $Type,
        # Number of spaces the surrounding line is indented. Only relevant
        # for multi-line literals (keymap) so the nested entries and the
        # closing brace align with the surrounding hashtable layout.
        # 0 means "no surrounding indent" (e.g. building a literal for a
        # standalone assignment).
        [int] $IndentSpaces = 0
    )
    switch ($Type) {
        'string'       { return "'" + ([string]$Value -replace "'", "''") + "'" }
        'password'     { return "'" + ([string]$Value -replace "'", "''") + "'" }
        'enum'         { return "'" + ([string]$Value -replace "'", "''") + "'" }
        'int' {
            $n = [long]$Value
            return $n.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }
        'bool' {
            $b = [bool]$Value
            if ($b) { return '$true' } else { return '$false' }
        }
        'string-array' {
            $arr = @()
            if ($null -ne $Value) {
                foreach ($item in @($Value)) {
                    $s = [string]$item
                    if (-not [string]::IsNullOrWhiteSpace($s)) { $arr += $s.Trim() }
                }
            }
            if ($arr.Count -eq 0) { return '@()' }
            $items = $arr | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }
            return '@(' + ($items -join ', ') + ')'
        }
        'keymap' {
            # label -> key hashtable. Emitted multi-line for readability so
            # `git diff` on config.psd1 shows clean per-row changes when
            # rotating individual keys. Indent matches the caller-supplied
            # IndentSpaces (the outer line's indent) so the closing brace
            # aligns with the key name and nested entries sit one level
            # deeper.
            if ($null -eq $Value) { return '@{}' }
            $coerced = if ($Value -is [hashtable]) { $Value } else { @{} }
            if ($coerced.Count -eq 0) { return '@{}' }
            $outerPad = ' ' * $IndentSpaces
            $innerPad = ' ' * ($IndentSpaces + 4)
            $maxLabelLen = (@($coerced.Keys | ForEach-Object { ([string]$_).Length + 2 }) | Measure-Object -Maximum).Maximum
            $pairs = foreach ($k in @($coerced.Keys | Sort-Object)) {
                $label = [string]$k
                $val   = [string]$coerced[$k]
                $keyQuoted = "'" + ($label -replace "'", "''") + "'"
                $valQuoted = "'" + ($val -replace "'", "''") + "'"
                ("{0}{1,-$maxLabelLen} = {2}" -f $innerPad, $keyQuoted, $valQuoted)
            }
            return ("@{`r`n" + ($pairs -join "`r`n") + "`r`n$outerPad}")
        }
        default { throw "Unknown type for serialization: $Type" }
    }
}

# ---------------------------------------------------------------------------
# Validate a single field's value against its schema entry. Returns $null
# on success or a human-readable error string. The same validator runs
# client-side as a `pattern` attribute / numeric min/max — but the server
# is authoritative.
# ---------------------------------------------------------------------------
function Test-PoshFieldValue {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Field,
        $Value
    )
    switch ($Field.Type) {
        'string' {
            $s = if ($null -eq $Value) { '' } else { [string]$Value }
            if ($Field.ContainsKey('Validator') -and $Field.Validator) {
                if ($s -notmatch $Field.Validator) {
                    return "Value does not match the expected format ($($Field.Validator))"
                }
            }
            return $null
        }
        'password' {
            # Passwords are opaque strings — no format validation beyond
            # the universal "no newlines" rule. The UI masks them; the
            # server stores them plaintext in config.psd1.
            $s = if ($null -eq $Value) { '' } else { [string]$Value }
            if ($s -match "[`r`n]") { return 'Password must not contain line breaks' }
            return $null
        }
        'enum' {
            $s = [string]$Value
            if (-not $Field.ContainsKey('Choices')) { return "Schema error: 'Choices' missing for $($Field.Name)" }
            # -in is case-insensitive for strings in PowerShell. Match the
            # server's tolerance for casing while still rejecting truly
            # unknown values.
            if ($s -notin $Field.Choices) { return "Value must be one of '$($Field.Choices -join ", ")'" }
            return $null
        }
        'int' {
            # Reject $null and bools explicitly so the coercer can hand us
            # a sentinel for "user gave us nonsense" without us treating
            # nonsense-coerced-to-0 as a valid value.
            if ($null -eq $Value)   { return 'Integer expected' }
            if ($Value -is [bool])  { return 'Integer expected (not a Bool)' }
            $n = 0L
            if (-not [long]::TryParse([string]$Value, [ref] $n)) { return 'Integer expected' }
            if ($Field.ContainsKey('Min') -and $n -lt [long]$Field.Min) { return "At least $($Field.Min)" }
            if ($Field.ContainsKey('Max') -and $n -gt [long]$Field.Max) { return "At most $($Field.Max)" }
            return $null
        }
        'bool' {
            if ($null -eq $Value)   { return 'Bool expected ($true / $false)' }
            if ($Value -is [bool])  { return $null }
            return 'Bool expected ($true / $false)'
        }
        'string-array' {
            if ($null -eq $Value) { return $null }
            foreach ($item in @($Value)) {
                $s = [string]$item
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                # No per-item validator yet — the existing server tolerates
                # exact IPs, CIDR, and regex (~^pattern). Accept anything
                # non-empty and trim happens at serialize time.
                if ($s.Length -gt 200) { return "Entry '$s' is too long (max 200 characters)" }
            }
            return $null
        }
        'keymap' {
            if ($null -eq $Value) { return $null }
            if ($Value -isnot [hashtable]) { return 'Keymap value must be an object (label -> key)' }
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($k in @($Value.Keys)) {
                $label = [string]$k
                if ([string]::IsNullOrWhiteSpace($label)) { return 'Empty label not allowed' }
                if ($label -notmatch '^[A-Za-z0-9_-]+$') {
                    return "Label '$label' must match A-Z, 0-9, _ and -"
                }
                if (-not $seen.Add($label)) { return "Duplicate label '$label'" }
                $apiKey = [string]$Value[$k]
                if ([string]::IsNullOrEmpty($apiKey)) { return "Key for label '$label' is empty" }
                if ($apiKey.Length -lt 16) { return "Key for label '$label' must be at least 16 characters" }
                if ($apiKey -match "[`r`n]") { return "Key for label '$label' must not contain line breaks" }
            }
            return $null
        }
        default { return "Unknown field type: $($Field.Type)" }
    }
}

# ---------------------------------------------------------------------------
# Coerce a JSON-deserialised value into the typed PowerShell value the
# serializer expects. JSON only knows string/number/bool/array — so an
# 'int' field arrives as long, a 'bool' as bool, a 'string' as string.
# Defensive defaulting in case the UI sends the wrong shape.
# ---------------------------------------------------------------------------
function ConvertTo-PoshTypedValue {
    param(
        [Parameter(Mandatory)] [hashtable] $Field,
        $RawValue
    )
    switch ($Field.Type) {
        'string'       { if ($null -eq $RawValue) { return '' } else { return [string]$RawValue } }
        'password'     { if ($null -eq $RawValue) { return '' } else { return [string]$RawValue } }
        'enum'         { if ($null -eq $RawValue) { return '' } else { return [string]$RawValue } }
        'int' {
            # Return $null on bad input — the caller's Test-PoshFieldValue
            # surfaces it as "Integer expected". Previously this silently
            # mapped 'abc' to 0L, which then passed any Min=0 validator.
            if ($null -eq $RawValue) { return $null }
            if ($RawValue -is [bool]) { return $null }
            $n = 0L
            if ([long]::TryParse([string]$RawValue, [ref] $n)) { return $n }
            return $null
        }
        'bool' {
            if ($RawValue -is [bool]) { return $RawValue }
            if ($null -eq $RawValue)  { return $null }
            # Accept a documented superset of spellings, then return $null
            # for anything else so validation rejects it instead of
            # silently coercing to $false.
            $s = ([string]$RawValue).Trim()
            if ($s -in @('true','True','TRUE','1','yes','Yes','YES'))   { return $true }
            if ($s -in @('false','False','FALSE','0','no','No','NO','')) { return $false }
            return $null
        }
        'string-array' {
            if ($null -eq $RawValue) { return @() }
            if ($RawValue -is [string]) {
                # UI may send a multi-line string; split on newlines.
                return @(($RawValue -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            return @($RawValue | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        'keymap' {
            # JSON arrives as a hashtable thanks to ConvertFrom-Json
            # -AsHashtable. Re-emit a clean hashtable with trimmed labels
            # so trailing spaces from copy-paste don't sneak into the file.
            $out = @{}
            if ($null -eq $RawValue) { return $out }
            if ($RawValue -isnot [hashtable]) {
                # Be liberal: also accept array-of-pair objects {label, key}.
                foreach ($entry in @($RawValue)) {
                    if ($entry -is [hashtable] -and $entry.ContainsKey('label') -and $entry.ContainsKey('key')) {
                        $label = [string]$entry['label']
                        $key   = [string]$entry['key']
                        if (-not [string]::IsNullOrWhiteSpace($label)) {
                            $out[$label.Trim()] = $key
                        }
                    }
                }
                return $out
            }
            foreach ($k in @($RawValue.Keys)) {
                $label = [string]$k
                if ([string]::IsNullOrWhiteSpace($label)) { continue }
                $out[$label.Trim()] = [string]$RawValue[$k]
            }
            return $out
        }
        default { throw "Unknown type for coercion: $($Field.Type)" }
    }
}

# ---------------------------------------------------------------------------
# Compare current values vs. proposed. Returns an array of change records
# the UI shows in the diff modal. No file IO here — pure compare.
# ---------------------------------------------------------------------------
function Compare-PoshFieldValues {
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)] [hashtable[]] $Schema,
        [Parameter(Mandatory)] [hashtable]   $Current,
        [Parameter(Mandatory)] [hashtable]   $Proposed
    )
    $changes = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($field in $Schema) {
        $name = $field.Name
        if (-not $Proposed.ContainsKey($name)) { continue }
        $proposedTyped = ConvertTo-PoshTypedValue -Field $field -RawValue $Proposed[$name]
        $currentVal    = if ($Current.ContainsKey($name)) { $Current[$name] } else { $null }
        if (Compare-PoshScalar -A $currentVal -B $proposedTyped) {
            $null = $changes.Add(@{
                File   = $field.File
                Name   = $name
                Label  = $field.Label
                Before = ConvertTo-PoshDisplayString -Value $currentVal -Type $field.Type
                After  = ConvertTo-PoshDisplayString -Value $proposedTyped -Type $field.Type
            })
        }
    }
    return @($changes)
}

function Compare-PoshScalar {
    # Returns $true when A and B differ.
    param($A, $B)
    if ($null -eq $A -and $null -eq $B) { return $false }
    if ($null -eq $A -or $null -eq $B)  { return $true }
    # Hashtables must be compared key-by-key — naively enumerating both
    # only yields DictionaryEntry stringifications, which collide on
    # 'System.Collections.DictionaryEntry' and report "no change" even
    # when keys/values differ.
    if ($A -is [hashtable] -or $B -is [hashtable]) {
        if ($A -isnot [hashtable] -or $B -isnot [hashtable]) { return $true }
        if ($A.Count -ne $B.Count) { return $true }
        foreach ($k in @($A.Keys)) {
            if (-not $B.ContainsKey($k)) { return $true }
            if ([string]$A[$k] -ne [string]$B[$k]) { return $true }
        }
        return $false
    }
    if ($A -is [System.Collections.IEnumerable] -and $A -isnot [string]) {
        $aArr = @($A | ForEach-Object { [string]$_ })
        $bArr = @($B | ForEach-Object { [string]$_ })
        if ($aArr.Count -ne $bArr.Count) { return $true }
        for ($i = 0; $i -lt $aArr.Count; $i++) {
            if ($aArr[$i] -ne $bArr[$i]) { return $true }
        }
        return $false
    }
    return ([string]$A -ne [string]$B)
}

function ConvertTo-PoshDisplayString {
    param($Value, [string] $Type)
    if ($null -eq $Value) { return '(not set)' }
    if ($Type -eq 'bool') { if ($Value) { return '$true' } else { return '$false' } }
    if ($Type -eq 'password') {
        $s = [string]$Value
        if ([string]::IsNullOrEmpty($s)) { return '(empty)' }
        # Never echo the actual value back to the UI even in the diff —
        # an over-the-shoulder reader shouldn't be able to read a password
        # from the change preview.
        return ('●' * [Math]::Min($s.Length, 12))
    }
    if ($Type -eq 'string-array') {
        $arr = @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($arr.Count -eq 0) { return '(empty)' }
        return ($arr -join ', ')
    }
    if ($Type -eq 'keymap') {
        if ($Value -isnot [hashtable]) { return '(empty)' }
        if ($Value.Count -eq 0) { return '(empty)' }
        # Show labels + masked key length per row so the operator sees what
        # changed without exposing the secrets in the diff.
        $parts = foreach ($k in @($Value.Keys | Sort-Object)) {
            $key = [string]$Value[$k]
            $mask = '●' * [Math]::Min($key.Length, 8)
            "{0}={1}({2})" -f $k, $mask, $key.Length
        }
        return ($parts -join ', ')
    }
    return [string]$Value
}

# ---------------------------------------------------------------------------
# AST-based replacement of a single $Var = ... assignment in
# globalvars.ps1. Preserves all surrounding comments and whitespace
# verbatim because we only splice the value's substring.
# ---------------------------------------------------------------------------
function Set-PoshGlobalvar {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [string] $Type
    )
    $s = Get-PoshIoState
    Assert-PoshIoTarget -Path $s.Globalvars
    $literal = ConvertTo-PoshLiteral -Value $Value -Type $Type

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.Globalvars, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        throw "Cannot edit globalvars.ps1 — file has parse errors. Fix manually first."
    }
    $assignments = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $Name
    }, $true)
    if ($assignments.Count -eq 0) {
        throw "Variable '`$$Name' not found in globalvars.ps1"
    }
    if ($assignments.Count -gt 1) {
        throw "Variable '`$$Name' is assigned $($assignments.Count) times in globalvars.ps1 — refusing to guess which one to update"
    }
    $valueAst = $assignments[0].Right
    $extent   = $valueAst.Extent
    $content  = [System.IO.File]::ReadAllText($s.Globalvars)
    $newContent = $content.Substring(0, $extent.StartOffset) + $literal + $content.Substring($extent.EndOffset)

    if ($PSCmdlet.ShouldProcess($s.Globalvars, "Update `$$Name")) {
        [System.IO.File]::WriteAllText($s.Globalvars, $newContent, [System.Text.UTF8Encoding]::new($false))
    }
}

# ---------------------------------------------------------------------------
# AST-based replacement of one key in the top-level hashtable of
# config.psd1. Same Extent-slice trick keeps comments and key alignment
# intact.
# ---------------------------------------------------------------------------
function Set-PoshConfigKey {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [string] $Type
    )
    $s = Get-PoshIoState
    Assert-PoshIoTarget -Path $s.ConfigPsd1

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.ConfigPsd1, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        throw "Cannot edit config.psd1 — file has parse errors. Fix manually first."
    }
    # The top-level expression of a psd1 is a single HashtableAst.
    $hashes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
    if ($hashes.Count -eq 0) { throw 'config.psd1 contains no hashtable literal' }
    $hash = $hashes[0]  # outermost
    $pair = $hash.KeyValuePairs | Where-Object {
        $_.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $_.Item1.Value -eq $Key
    } | Select-Object -First 1
    if (-not $pair) {
        throw "Key '$Key' not found at top level of config.psd1"
    }
    $extent  = $pair.Item2.Extent
    $content = [System.IO.File]::ReadAllText($s.ConfigPsd1)

    # Detect the indent of the line containing the key so multi-line
    # literals (keymap) align with the surrounding @{} block instead of
    # using a hardcoded 12-space indent.
    $keyStart = $pair.Item1.Extent.StartOffset
    $indent = 0
    $scan = $keyStart - 1
    while ($scan -ge 0 -and $content[$scan] -ne "`n") {
        if ($content[$scan] -eq ' ') { $indent++ }
        elseif ($content[$scan] -eq "`t") { $indent += 4 }
        else { $indent = 0 }  # non-whitespace before newline -> line starts with code, not pure indent
        $scan--
    }

    $literal = ConvertTo-PoshLiteral -Value $Value -Type $Type -IndentSpaces $indent
    $newContent = $content.Substring(0, $extent.StartOffset) + $literal + $content.Substring($extent.EndOffset)

    if ($PSCmdlet.ShouldProcess($s.ConfigPsd1, "Update '$Key'")) {
        [System.IO.File]::WriteAllText($s.ConfigPsd1, $newContent, [System.Text.UTF8Encoding]::new($false))
    }
}

# ---------------------------------------------------------------------------
# Apply a batch of changes atomically per file. Each file is backed up
# once before its first change and the whole batch is committed in one
# pass. Returns the list of backup paths created.
# ---------------------------------------------------------------------------
function Save-PoshFieldChanges {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable[]] $Schema,
        [Parameter(Mandatory)] [hashtable]   $Proposed
    )
    $s = Get-PoshIoState

    # Defense in depth: re-run validation here even though the route layer
    # already did it. Anything that ever calls this function directly
    # (tests, future automation) gets the same protection.
    $errs = [System.Collections.Generic.List[string]]::new()
    foreach ($field in $Schema) {
        if (-not $Proposed.ContainsKey($field.Name)) { continue }
        if ($field.ContainsKey('IsLiteral') -and -not $field.IsLiteral) {
            $null = $errs.Add(("{0}: computed value, not editable" -f $field.Name))
            continue
        }
        $typed = ConvertTo-PoshTypedValue -Field $field -RawValue $Proposed[$field.Name]
        $err   = Test-PoshFieldValue -Field $field -Value $typed
        if ($err) { $null = $errs.Add(("{0}: {1}" -f $field.Name, $err)) }
    }
    if ($errs.Count -gt 0) {
        throw "Validation failed: $($errs -join '; ')"
    }

    $byFile = @{}
    foreach ($field in $Schema) {
        if ($Proposed.ContainsKey($field.Name)) {
            if (-not $byFile.ContainsKey($field.File)) { $byFile[$field.File] = @() }
            $byFile[$field.File] += @{ Field = $field; Value = $Proposed[$field.Name] }
        }
    }
    $backups = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $byFile.Keys) {
        $abs = switch ($file) {
            'globalvars.ps1' { $s.Globalvars }
            'config.psd1'    { $s.ConfigPsd1 }
            default          { throw "Unsupported file in schema: $file" }
        }
        if ($PSCmdlet.ShouldProcess($abs, "Backup before edit")) {
            $bk = Backup-PoshFile -FilePath $abs
            if ($bk) { $null = $backups.Add($bk) }
        }
        foreach ($entry in $byFile[$file]) {
            $field   = $entry.Field
            $typed   = ConvertTo-PoshTypedValue -Field $field -RawValue $entry.Value
            try {
                if ($file -eq 'globalvars.ps1') {
                    Set-PoshGlobalvar -Name $field.Name -Value $typed -Type $field.Type
                } else {
                    Set-PoshConfigKey -Key $field.Name -Value $typed -Type $field.Type
                }
            } catch {
                # Wrap with the file + key so the editor's toast tells the
                # operator exactly where the save broke instead of just
                # "Save failed: <inner exception>".
                throw ("{0}: writing '{1}' failed -> {2}" -f $file, $field.Name, $_.Exception.Message)
            }
        }
    }
    return @($backups)
}

# ---------------------------------------------------------------------------
# AES key generation. Mirrors the core write path of
# tools\New-PoshAesKey.ps1 but returns instead of exiting so the
# HTTP handler can surface success / failure as JSON.
# ---------------------------------------------------------------------------
function New-PoshAesKey {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch] $Force)
    $s = Get-PoshIoState
    Assert-PoshIoTarget -Path $s.Globalvars
    if (-not (Test-Path -LiteralPath $s.Globalvars -PathType Leaf)) {
        throw "globalvars.ps1 not found: $($s.Globalvars)"
    }
    $content = [System.IO.File]::ReadAllText($s.Globalvars)
    $startMarker = '# >>>POSH_KEY_START<<<'
    $endMarker   = '# >>>POSH_KEY_END<<<'
    $startIx     = $content.IndexOf($startMarker)
    $endIx       = $content.IndexOf($endMarker)
    if ($startIx -lt 0 -or $endIx -lt 0 -or $endIx -le $startIx) {
        throw "Marker block missing in globalvars.ps1 (expected $startMarker ... $endMarker)"
    }
    # Placeholder detection: dot-source the file and inspect the actual
    # byte array. The previous regex on the text block matched any digit
    # token (including digits in code comments), so a comment like
    # "# 256 bytes" inside the markers was misread as "initialised".
    $vars   = Get-PoshGlobalvarValues -Names @('key')
    $bytes  = if ($vars.ContainsKey('key')) { @($vars['key']) } else { @() }
    $isPlaceholder = ((@($bytes | Where-Object { $_ -ne 0 }).Count) -eq 0)
    if (-not $isPlaceholder -and -not $Force) {
        throw '$key is already initialised. Re-running invalidates every encrypted_pw\encryptedString_*.txt under the current key. Pass -Force to proceed.'
    }
    $bytes = [byte[]]::new(32)
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $newline      = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $keyArrayText = '$key = @(' + (($bytes | ForEach-Object { [string]$_ }) -join ', ') + ')'
    $newBlock     = $startMarker + $newline + $keyArrayText + $newline + $endMarker
    $newContent   = $content.Substring(0, $startIx) + $newBlock + $content.Substring($endIx + $endMarker.Length)

    if ($PSCmdlet.ShouldProcess($s.Globalvars, 'Backup + write new $key')) {
        $bk = Backup-PoshFile -FilePath $s.Globalvars
        [System.IO.File]::WriteAllText($s.Globalvars, $newContent, [System.Text.UTF8Encoding]::new($false))
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0 }
        return @{ Replaced = (-not $isPlaceholder); Backup = $bk }
    }
    return @{ Replaced = $false; Backup = $null }
}

# ---------------------------------------------------------------------------
# Encrypted secret storage. Same crypto path as tools\Set-PoshSecret.ps1
# but takes the password as a SecureString-already-from-the-handler so
# the cleartext lives only in process memory for the duration of the
# encrypt call.
# ---------------------------------------------------------------------------
function Save-PoshSecret {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [securestring] $Password,
        [switch] $Force
    )
    $s = Get-PoshIoState
    if ($Label -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Label must match ^[A-Za-z0-9_-]+$  (got: '$Label')"
    }
    $vars = Get-PoshGlobalvarValues -Names @('key', 'PoshEncryptedDir')
    if (-not $vars.ContainsKey('key')) {
        throw '$key not defined in globalvars.ps1 — run "Generate AES key" first'
    }
    $bytes = @($vars['key'])
    $nonZero = @($bytes | Where-Object { $_ -ne 0 }).Count
    if ($nonZero -eq 0) {
        throw '$key is the placeholder — run "Generate AES key" first'
    }
    $encDir = if ($vars.ContainsKey('PoshEncryptedDir')) { [string]$vars['PoshEncryptedDir'] } else { $s.EncryptedDir }
    if (-not (Test-Path -LiteralPath $encDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $encDir -Force
    }
    $outFile = Join-Path $encDir ("encryptedString_$Label.txt")
    Assert-PoshIoTarget -Path $outFile
    if ((Test-Path -LiteralPath $outFile -PathType Leaf) -and -not $Force) {
        throw "Secret '$Label' already exists. Pass -Force to overwrite."
    }
    $cipher = ConvertFrom-SecureString -SecureString $Password -Key ([byte[]]$bytes)
    if ($PSCmdlet.ShouldProcess($outFile, 'Write encrypted secret')) {
        [System.IO.File]::WriteAllText($outFile, $cipher, [System.Text.UTF8Encoding]::new($false))
    }
    return @{ Label = $Label; File = $outFile }
}

# ---------------------------------------------------------------------------
# Set POSH_API_KEY at machine scope. Requires the editor process to have
# been launched elevated; the route handler refuses earlier with a
# friendly error if not.
# ---------------------------------------------------------------------------
function Set-PoshApiKeyEnv {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'API key must not be empty' }
    if ($PSCmdlet.ShouldProcess('POSH_API_KEY (Machine)', 'Set')) {
        [Environment]::SetEnvironmentVariable('POSH_API_KEY', $Value, 'Machine')
    }
}

function Test-PoshIsAdmin {
    [OutputType([bool])]
    param()
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function @(
    'Initialize-PoshSettingsIO',
    'Get-PoshIoState',
    'Test-PoshIoTarget',
    'Backup-PoshFile',
    'Get-PoshGlobalvarValues',
    'Get-PoshGlobalvarDefinitions',
    'Add-PoshGlobalvar',
    'Remove-PoshGlobalvar',
    'Get-PoshConfigValues',
    'Get-PoshApiKeyStatus',
    'Get-PoshAesKeyStatus',
    'Get-PoshSecretList',
    'ConvertTo-PoshLiteral',
    'ConvertTo-PoshTypedValue',
    'Test-PoshFieldValue',
    'Compare-PoshFieldValues',
    'ConvertTo-PoshDisplayString',
    'Set-PoshGlobalvar',
    'Set-PoshConfigKey',
    'Save-PoshFieldChanges',
    'New-PoshAesKey',
    'Save-PoshSecret',
    'Set-PoshApiKeyEnv',
    'Test-PoshIsAdmin',
    'Get-PoshBackupList',
    'Read-PoshBackup',
    'Restore-PoshBackup'
)
