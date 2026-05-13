#Requires -Version 7.0
<#
.SYNOPSIS
    IO layer for tools\Edit-PoshSettings.ps1.

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
    $encPrefix = $s.EncryptedDir + [System.IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($encPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        ($resolved -match 'encryptedString_[A-Za-z0-9_-]+\.txt$')) { return $true }
    return $false
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
# Read config.psd1 via Import-PowerShellDataFile (no script execution).
# ---------------------------------------------------------------------------
function Get-PoshConfigValues {
    [OutputType([hashtable])]
    param()
    $s = Get-PoshIoState
    if (-not (Test-Path -LiteralPath $s.ConfigPsd1 -PathType Leaf)) {
        throw "config.psd1 not found: $($s.ConfigPsd1) — run tools\Initialize-Config.ps1 first"
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
# Initialize-Config compatibility (the diff stays minimal).
# ---------------------------------------------------------------------------
function ConvertTo-PoshLiteral {
    [OutputType([string])]
    param(
        $Value,
        [Parameter(Mandatory)] [string] $Type
    )
    switch ($Type) {
        'string'       { return "'" + ([string]$Value -replace "'", "''") + "'" }
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
                    return "Wert entspricht nicht dem erwarteten Format ($($Field.Validator))"
                }
            }
            return $null
        }
        'enum' {
            $s = [string]$Value
            if (-not $Field.ContainsKey('Choices')) { return "Schema-Fehler: 'Choices' fehlt für $($Field.Name)" }
            if ($s -notin $Field.Choices) { return "Wert muss einer von '$($Field.Choices -join ", ")' sein" }
            return $null
        }
        'int' {
            $n = 0L
            if (-not [long]::TryParse([string]$Value, [ref] $n)) { return 'Ganzzahl erwartet' }
            if ($Field.ContainsKey('Min') -and $n -lt [long]$Field.Min) { return "Mindestens $($Field.Min)" }
            if ($Field.ContainsKey('Max') -and $n -gt [long]$Field.Max) { return "Höchstens $($Field.Max)" }
            return $null
        }
        'bool' {
            if ($Value -is [bool]) { return $null }
            if ([string]$Value -in @('true', 'false', 'True', 'False', '0', '1')) { return $null }
            return 'Bool erwartet ($true / $false)'
        }
        'string-array' {
            if ($null -eq $Value) { return $null }
            foreach ($item in @($Value)) {
                $s = [string]$item
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                # No per-item validator yet — the existing server tolerates
                # exact IPs, CIDR, and regex (~^pattern). Accept anything
                # non-empty and trim happens at serialize time.
                if ($s.Length -gt 200) { return "Eintrag '$s' ist zu lang (max 200 Zeichen)" }
            }
            return $null
        }
        default { return "Unbekannter Field-Typ: $($Field.Type)" }
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
        'enum'         { if ($null -eq $RawValue) { return '' } else { return [string]$RawValue } }
        'int'          {
            if ($null -eq $RawValue) { return 0L }
            $n = 0L
            if ([long]::TryParse([string]$RawValue, [ref] $n)) { return $n }
            return 0L
        }
        'bool' {
            if ($RawValue -is [bool]) { return $RawValue }
            $s = [string]$RawValue
            return ($s -in @('true', 'True', '1'))
        }
        'string-array' {
            if ($null -eq $RawValue) { return @() }
            if ($RawValue -is [string]) {
                # UI may send a multi-line string; split on newlines.
                return @(($RawValue -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            return @($RawValue | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
    if ($null -eq $Value) { return '(nicht gesetzt)' }
    if ($Type -eq 'bool') { if ($Value) { return '$true' } else { return '$false' } }
    if ($Type -eq 'string-array') {
        $arr = @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($arr.Count -eq 0) { return '(leer)' }
        return ($arr -join ', ')
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
    $literal = ConvertTo-PoshLiteral -Value $Value -Type $Type

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
            if ($file -eq 'globalvars.ps1') {
                Set-PoshGlobalvar -Name $field.Name -Value $typed -Type $field.Type
            } else {
                Set-PoshConfigKey -Key $field.Name -Value $typed -Type $field.Type
            }
        }
    }
    return @($backups)
}

# ---------------------------------------------------------------------------
# AES key generation. Mirrors the core write path of
# tools\Initialize-Globalvars.ps1 but returns instead of exiting so the
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
    $blockStart    = $startIx + $startMarker.Length
    $existingBlock = $content.Substring($blockStart, $endIx - $blockStart)
    $looksLikePlaceholder = $existingBlock -notmatch '\b[1-9]\d*\b'
    if (-not $looksLikePlaceholder -and -not $Force) {
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
        return @{ Replaced = (-not $looksLikePlaceholder); Backup = $bk }
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
    'Test-PoshIsAdmin'
)
