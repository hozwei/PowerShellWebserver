#Requires -Version 7.0
<#
.SYNOPSIS
    Registers Start-WebServer.ps1 as a Windows Scheduled Task.

.DESCRIPTION
    Creates a Scheduled Task that:
    - Runs automatically at system startup
    - Runs as the configured administrator user
    - Keeps the web server running indefinitely (no timeout)
    - Automatically restarts up to 3 times after a crash (1-minute interval)

    Optional: HTTPS configuration with a self-signed certificate or an
    existing certificate (thumbprint or PFX import), netsh binding,
    and Windows Firewall rules.

    Requires PowerShell 7 (pwsh.exe).
    Must be run as Administrator.

.EXAMPLE
    .\Register-ScheduledTask.ps1

    # Start immediately without rebooting:
    Start-ScheduledTask -TaskName 'PowerShell-Webserver'

    # Remove the task:
    Unregister-ScheduledTask -TaskName 'PowerShell-Webserver' -Confirm:$false
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Base path — robust against empty $PSScriptRoot
# ---------------------------------------------------------------------------
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $baseDir = $PSScriptRoot
} else {
    $baseDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$TASK_NAME   = 'PowerShell-Webserver'
$SCRIPT_PATH = Join-Path $baseDir 'Start-WebServer.ps1'
$WORK_DIR    = $baseDir

# Fixed AppID GUID for netsh sslcert — identical across re-installations
# so old bindings can be cleanly replaced.
$POSH_APP_GUID = 'a3b2c1d0-4e5f-6a7b-8c9d-0e1f2a3b4c5d'

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output ''
    Write-Output 'ERROR: This script must be run as Administrator.'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# Start-WebServer.ps1 must be present
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $SCRIPT_PATH -PathType Leaf)) {
    Write-Output ''
    Write-Output "ERROR: Start-WebServer.ps1 not found at: $SCRIPT_PATH"
    Write-Output 'Both scripts must be in the same directory.'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# Helper: prompt with default value
# Displays "[Default]" and returns the default when input is empty.
# ---------------------------------------------------------------------------
function Read-HostWithDefault {
    param(
        [string] $Prompt,
        [string] $Default
    )
    $raw = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw.Trim()
}

# ---------------------------------------------------------------------------
# Helper: yes/no prompt
# Returns $true for J/j/Y/y, $false for N/n and anything else.
# ---------------------------------------------------------------------------
function Read-YesNo {
    param(
        [string] $Prompt,
        [bool]   $Default = $false
    )
    $defaultHint = if ($Default) { 'Y/n' } else { 'y/N' }
    $raw = (Read-Host "$Prompt ($defaultHint)").Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw -match '^[JjYy]'
}

# ---------------------------------------------------------------------------
# Helper: clean thumbprint
# Removes invisible Unicode characters (U+200E etc.) and whitespace.
# netsh fails with a cryptic error on dirty thumbprints.
# ---------------------------------------------------------------------------
function Get-CleanThumbprint {
    param([string] $Thumbprint)
    return ($Thumbprint -replace '[^a-fA-F0-9]', '').ToUpper()
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output 'PowerShell Webserver - Scheduled Task Registration'
Write-Output "Task name   : $TASK_NAME"
Write-Output "Script      : $SCRIPT_PATH"
Write-Output "Working dir : $WORK_DIR"
Write-Output ''

# ---------------------------------------------------------------------------
# Prompt for username and password
# ---------------------------------------------------------------------------
Write-Output 'The task runs under a local administrator account.'
Write-Output 'Leave username empty to use "Administrator".'
Write-Output ''

$inputUser = Read-Host 'Username (default: Administrator)'
if ([string]::IsNullOrWhiteSpace($inputUser)) {
    $taskUser = 'Administrator'
} else {
    $taskUser = $inputUser.Trim()
}

$securePwd = Read-Host "Password for '$taskUser'" -AsSecureString
$bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
$taskPassword = $null
try {
    $taskPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    # Always zero the BSTR — regardless of whether conversion succeeded.
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrEmpty($taskPassword)) {
    Write-Output ''
    Write-Output 'ERROR: Password must not be empty.'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# Prompt for API key and set it as a system environment variable
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output 'API key for POSH_API_KEY (input is visible — watch your screen):'
$apiKey = Read-Host 'API key'

if ([string]::IsNullOrEmpty($apiKey)) {
    Write-Output ''
    Write-Output 'ERROR: API key must not be empty.'
    Write-Output ''
    exit 1
}

[Environment]::SetEnvironmentVariable('POSH_API_KEY', $apiKey, 'Machine')
$apiKey = $null   # clear from memory immediately
Write-Output 'POSH_API_KEY set as system environment variable.'

# ---------------------------------------------------------------------------
# HTTPS configuration
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ' HTTPS Configuration'
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ''

$httpsEnabled = Read-YesNo -Prompt 'Enable HTTPS?' -Default $false

# Prompt for ports — always needed (HTTP port is required even without HTTPS).
Write-Output ''
$httpPortStr  = Read-HostWithDefault -Prompt 'HTTP port'  -Default '80'
$httpPort     = [int]$httpPortStr

# HTTPS-specific configuration
$httpsPort      = 443
$httpDisabled   = $false
$certThumbprint = $null

if ($httpsEnabled) {
    $httpsPortStr = Read-HostWithDefault -Prompt 'HTTPS port' -Default '443'
    $httpsPort    = [int]$httpsPortStr

    # ------------------------------------------------------------------
    # Select certificate source
    # ------------------------------------------------------------------
    Write-Output ''
    Write-Output 'Certificate source:'
    Write-Output '  1) Create a new self-signed certificate'
    Write-Output '  2) Use an existing certificate'
    Write-Output ''
    $certSource = Read-HostWithDefault -Prompt 'Selection' -Default '1'

    if ($certSource -eq '1') {
        # --------------------------------------------------------------
        # Option 1: create a self-signed certificate
        # --------------------------------------------------------------
        Write-Output ''
        $certYearsStr = Read-HostWithDefault -Prompt 'Certificate validity in years' -Default '10'
        $certYears    = [int]$certYearsStr
        if ($certYears -lt 1) { $certYears = 1 }

        Write-Output ''
        Write-Output 'Creating self-signed certificate...'

        # Determine local IPv4 addresses (no loopback, no link-local).
        $localIPs = @(Get-NetIPAddress `
            -AddressFamily IPv4 `
            -AddressState  Preferred `
            -ErrorAction   SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike '127.*' -and
                $_.IPAddress -notlike '169.254.*'
            } |
            Select-Object -ExpandProperty IPAddress)

        # Build SAN string: DNS entries first, then IPs.
        # Always include 127.0.0.1 — even if not in localIPs.
        $sanParts = [System.Collections.Generic.List[string]]::new()
        $null = $sanParts.Add("DNS=$env:COMPUTERNAME")
        $null = $sanParts.Add('DNS=localhost')
        $null = $sanParts.Add('IPAddress=127.0.0.1')
        foreach ($ip in $localIPs) {
            $null = $sanParts.Add("IPAddress=$ip")
        }
        $textExt = '2.5.29.17={text}' + ($sanParts -join '&')

        $certNotAfter = (Get-Date).AddYears($certYears)

        try {
            # -DnsName must not be combined with -TextExtension (SAN OID 2.5.29.17) —
            # Windows rejects both SAN sources simultaneously ("DnsName parameter conflicts").
            # All SANs (DNS + IP) are set exclusively via -TextExtension.
            $cert = New-SelfSignedCertificate `
                -Subject           "CN=$env:COMPUTERNAME" `
                -TextExtension     @($textExt) `
                -CertStoreLocation 'Cert:\LocalMachine\My' `
                -KeyUsage          KeyEncipherment, DigitalSignature `
                -KeyExportPolicy   Exportable `
                -FriendlyName      'posh-webserver' `
                -NotAfter          $certNotAfter `
                -ErrorAction       Stop
        } catch {
            Write-Output ''
            Write-Output "ERROR: Certificate could not be created: $_"
            Write-Output ''
            exit 1
        }

        $certThumbprint = Get-CleanThumbprint -Thumbprint $cert.Thumbprint

        Write-Output "  Subject    : $($cert.Subject)"
        Write-Output "  SAN        : $env:COMPUTERNAME, localhost, $($localIPs -join ', ')"
        Write-Output "  Valid      : $certYears year(s) (until $($certNotAfter.ToString('yyyy-MM-dd')))"
        Write-Output "  Store      : LocalMachine\My"
        Write-Output "  Thumbprint : $certThumbprint"

    } else {
        # --------------------------------------------------------------
        # Option 2: use an existing certificate
        # --------------------------------------------------------------
        Write-Output ''
        Write-Output 'Specify certificate:'
        Write-Output '  A) Thumbprint (certificate already installed in LocalMachine\My)'
        Write-Output '  B) Import PFX file'
        Write-Output ''
        $certInputMethod = (Read-HostWithDefault -Prompt 'Selection' -Default 'A').ToUpper()

        if ($certInputMethod -eq 'A') {
            # ----------------------------------------------------------
            # Option 2A: enter thumbprint directly
            # ----------------------------------------------------------
            Write-Output ''
            $rawThumb = Read-Host 'Thumbprint'
            if ([string]::IsNullOrWhiteSpace($rawThumb)) {
                Write-Output ''
                Write-Output 'ERROR: Thumbprint must not be empty.'
                Write-Output ''
                exit 1
            }

            $certThumbprint = Get-CleanThumbprint -Thumbprint $rawThumb

            # Look up certificate in store.
            Write-Output ''
            Write-Output 'Searching for certificate in LocalMachine\My...'
            $cert = Get-ChildItem 'Cert:\LocalMachine\My' |
                Where-Object { (Get-CleanThumbprint -Thumbprint $_.Thumbprint) -eq $certThumbprint } |
                Select-Object -First 1

            if ($null -eq $cert) {
                Write-Output ''
                Write-Output "ERROR: Certificate with thumbprint '$certThumbprint' not found in Cert:\LocalMachine\My."
                Write-Output 'Solution: import the certificate into the store first, or choose option B (PFX).'
                Write-Output ''
                exit 1
            }

            # Check expiry date.
            if ($cert.NotAfter -lt (Get-Date)) {
                Write-Output ''
                Write-Output "ERROR: Certificate has expired (NotAfter: $($cert.NotAfter.ToString('yyyy-MM-dd')))."
                Write-Output 'Solution: use a valid certificate.'
                Write-Output ''
                exit 1
            }

            Write-Output "  Found      : $($cert.Subject)"
            Write-Output "  Valid until: $($cert.NotAfter.ToString('yyyy-MM-dd'))"
            Write-Output "  Thumbprint : $certThumbprint"

        } else {
            # ----------------------------------------------------------
            # Option 2B: import PFX file
            # ----------------------------------------------------------
            Write-Output ''
            $pfxPath = Read-Host 'Path to PFX file'
            if ([string]::IsNullOrWhiteSpace($pfxPath)) {
                Write-Output ''
                Write-Output 'ERROR: Path must not be empty.'
                Write-Output ''
                exit 1
            }
            $pfxPath = $pfxPath.Trim('"').Trim()

            if (-not (Test-Path -LiteralPath $pfxPath -PathType Leaf)) {
                Write-Output ''
                Write-Output "ERROR: File not found: $pfxPath"
                Write-Output ''
                exit 1
            }

            $pfxPassword = Read-Host 'PFX password (leave empty if none)' -AsSecureString

            Write-Output ''
            Write-Output 'Importing certificate...'

            try {
                $imported = Import-PfxCertificate `
                    -FilePath          $pfxPath `
                    -CertStoreLocation 'Cert:\LocalMachine\My' `
                    -Password          $pfxPassword `
                    -Exportable `
                    -ErrorAction       Stop
            } catch {
                Write-Output ''
                Write-Output "ERROR: PFX could not be imported: $_"
                Write-Output 'Possible causes: wrong password, corrupted file, no private key.'
                Write-Output ''
                exit 1
            } finally {
                # Clear SecureString from memory.
                if ($null -ne $pfxPassword) {
                    $pfxPassword.Dispose()
                    $pfxPassword = $null
                }
            }

            # Import-PfxCertificate returns an array for certificate chains.
            # Use the end-entity certificate (the one with a private key).
            $cert = @($imported) | Where-Object { $_.HasPrivateKey } | Select-Object -First 1

            if ($null -eq $cert) {
                Write-Output ''
                Write-Output 'ERROR: No certificate with a private key found in the PFX file.'
                Write-Output ''
                exit 1
            }

            # Check expiry date.
            if ($cert.NotAfter -lt (Get-Date)) {
                Write-Output ''
                Write-Output "ERROR: Imported certificate has expired (NotAfter: $($cert.NotAfter.ToString('yyyy-MM-dd')))."
                Write-Output ''
                exit 1
            }

            $certThumbprint = Get-CleanThumbprint -Thumbprint $cert.Thumbprint

            Write-Output "  Imported   : $($cert.Subject)"
            Write-Output "  Valid until: $($cert.NotAfter.ToString('yyyy-MM-dd'))"
            Write-Output "  Thumbprint : $certThumbprint"
        }
    }

    # ------------------------------------------------------------------
    # Set netsh sslcert binding
    # Delete any existing binding first (clean re-install),
    # then add the new binding.
    # ------------------------------------------------------------------
    Write-Output ''
    Write-Output "Binding certificate to port $httpsPort (netsh sslcert)..."

    # Remove existing binding — always ignore exit code (1 = not found = ok).
    $null = netsh http delete sslcert "ipport=0.0.0.0:$httpsPort" 2>&1

    # Add new binding.
    $addOut = netsh http add sslcert "ipport=0.0.0.0:$httpsPort" "certhash=$certThumbprint" "appid={$POSH_APP_GUID}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output ''
        Write-Output "ERROR: netsh sslcert add failed (exit: $LASTEXITCODE): $addOut"
        Write-Output "Check: netsh http show sslcert ipport=0.0.0.0:$httpsPort"
        Write-Output ''
        exit 1
    }

    Write-Output "  OK - certificate bound to 0.0.0.0:$httpsPort"

    # Store thumbprint as machine env var for diagnostics (not a secret — fingerprint only).
    [Environment]::SetEnvironmentVariable('POSH_CERT_THUMBPRINT', $certThumbprint, 'Machine')

    # ------------------------------------------------------------------
    # Disable HTTP?
    # ------------------------------------------------------------------
    Write-Output ''
    $httpDisabled = Read-YesNo -Prompt "Disable HTTP (port $httpPort)?" -Default $false
    if ($httpDisabled) {
        Write-Output "  HTTP will be disabled — HTTPS only (port $httpsPort)."
    }
}

# ---------------------------------------------------------------------------
# Windows Firewall
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ' Windows Firewall'
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ''

# Collect active ports.
$activePorts = [System.Collections.Generic.List[int]]::new()
if (-not $httpsEnabled -or -not $httpDisabled) {
    $null = $activePorts.Add($httpPort)
}
if ($httpsEnabled) {
    $null = $activePorts.Add($httpsPort)
}

$openFirewall = Read-YesNo -Prompt "Open ports ($($activePorts -join ', ')) in Windows Firewall?" -Default $false

if ($openFirewall) {
    Write-Output ''
    foreach ($port in $activePorts) {
        $ruleName = "posh-webserver-$port"
        $existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Write-Output "  Port $port  - rule '$ruleName' already exists, skipping."
        } else {
            try {
                $null = New-NetFirewallRule `
                    -Name        $ruleName `
                    -DisplayName "posh-webserver Port $port" `
                    -Description 'PowerShell web server — inbound HTTP/HTTPS traffic' `
                    -Direction   Inbound `
                    -Protocol    TCP `
                    -LocalPort   $port `
                    -Action      Allow `
                    -Profile     Any `
                    -ErrorAction Stop
                Write-Output "  Port $port  - rule '$ruleName' created."
            } catch {
                Write-Output "  Port $port  - WARNING: firewall rule could not be created: $_"
                # No exit 1 — firewall failure should not abort the setup.
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Remove existing task (clean update)
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ' Scheduled Task'
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ''

$existingTask = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Output "Removing existing task '$TASK_NAME'..."
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
}

# ---------------------------------------------------------------------------
# Resolve pwsh.exe path
# ---------------------------------------------------------------------------
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
    $pwshExe = 'C:\Program Files\PowerShell\7\pwsh.exe'
}
if (-not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
    Write-Output ''
    Write-Output 'ERROR: pwsh.exe not found. Is PowerShell 7 installed?'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# Build task action arguments
# Start-WebServer.ps1 receives all relevant parameters directly.
# -HttpsEnabled as a switch: just specify it, no ':$true' needed.
# -HttpPort 0 signals: HTTP disabled.
# ---------------------------------------------------------------------------
$scriptArgs = '-NonInteractive -NoProfile -ExecutionPolicy Bypass'
$scriptArgs += " -File `"$SCRIPT_PATH`""
$scriptArgs += " -HttpPort $httpPort"

if ($httpsEnabled) {
    $scriptArgs += ' -HttpsEnabled'
    $scriptArgs += " -HttpsPort $httpsPort"
    if ($httpDisabled) {
        # HttpPort 0 = HTTP disabled — guard in Start-WebServer.ps1: if ($HttpPort -gt 0)
        $scriptArgs = $scriptArgs -replace "-HttpPort $httpPort", '-HttpPort 0'
    }
}

# ---------------------------------------------------------------------------
# Task components
# ---------------------------------------------------------------------------
$action = New-ScheduledTaskAction `
    -Execute          $pwshExe `
    -Argument         $scriptArgs `
    -WorkingDirectory $WORK_DIR

$trigger = New-ScheduledTaskTrigger -AtStartup

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

$settings.RestartCount    = 3
$settings.RestartInterval = 'PT1M'

# ---------------------------------------------------------------------------
# Register task
# ---------------------------------------------------------------------------
try {
    $task = Register-ScheduledTask `
        -TaskName    $TASK_NAME `
        -Description 'PowerShell HTTP/HTTPS web server — executes .ps1 scripts via HTTP requests' `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -User        $taskUser `
        -Password    $taskPassword `
        -RunLevel    Highest `
        -Force

    Write-Output "Task '$TASK_NAME' registered successfully."
    Write-Output ''
    Write-Output "Status      : $($task.State)"
    Write-Output "User        : $taskUser"
    Write-Output "Shell       : $pwshExe"
    Write-Output "Arguments   : $scriptArgs"
    Write-Output ''

    # Network configuration summary
    Write-Output 'Network configuration:'
    if (-not $httpsEnabled -or -not $httpDisabled) {
        Write-Output "  HTTP  : http://+:$httpPort/  (active)"
    } else {
        Write-Output "  HTTP  : disabled"
    }
    if ($httpsEnabled) {
        Write-Output "  HTTPS : https://+:$httpsPort/ (active)"
        Write-Output "  Cert. : $certThumbprint (until $($cert.NotAfter.ToString('yyyy-MM-dd')))"
    }
    Write-Output ''
    Write-Output 'Start immediately (without rebooting):'
    Write-Output "  Start-ScheduledTask -TaskName '$TASK_NAME'"
    Write-Output ''
    Write-Output 'Remove task:'
    Write-Output "  Unregister-ScheduledTask -TaskName '$TASK_NAME' -Confirm:`$false"
    Write-Output ''

} catch {
    Write-Output ''
    Write-Output "ERROR registering the task: $_"
    Write-Output ''
    exit 1
} finally {
    # Clear password from memory in all code paths.
    $taskPassword = $null
}
