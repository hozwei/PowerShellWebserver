#Requires -Version 7.0
<#
.SYNOPSIS
    Registriert Start-WebServer.ps1 als Windows Scheduled Task.

.DESCRIPTION
    Erstellt einen Scheduled Task der:
    - Beim Systemstart automatisch ausgefuehrt wird
    - Als konfigurierter Administrator-User laeuft
    - Den Webserver dauerhaft am Laufen haelt (kein Timeout)
    - Bei Absturz bis zu 3x nach je 1 Minute automatisch neu startet

    Optional: HTTPS-Konfiguration mit Self-Signed Zertifikat oder
    bestehendem Zertifikat (Thumbprint oder PFX-Import), netsh-Bindung
    und Windows-Firewall-Regeln.

    Erfordert PowerShell 7 (pwsh.exe).
    Muss als Administrator ausgefuehrt werden.

.EXAMPLE
    .\Register-ScheduledTask.ps1

    # Sofort starten ohne Neustart:
    Start-ScheduledTask -TaskName 'PowerShell-Webserver'

    # Task entfernen:
    Unregister-ScheduledTask -TaskName 'PowerShell-Webserver' -Confirm:$false
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Basispfad - robust gegen leeres $PSScriptRoot
# ---------------------------------------------------------------------------
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $baseDir = $PSScriptRoot
} else {
    $baseDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)
}

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
$TASK_NAME   = 'PowerShell-Webserver'
$SCRIPT_PATH = Join-Path $baseDir 'Start-WebServer.ps1'
$WORK_DIR    = $baseDir

# Feste AppID-GUID fuer netsh sslcert - identisch bei Re-Installation,
# damit alte Bindungen sauber ersetzt werden koennen
$POSH_APP_GUID = 'a3b2c1d0-4e5f-6a7b-8c9d-0e1f2a3b4c5d'

# ---------------------------------------------------------------------------
# Admin-Pruefung
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output ''
    Write-Output 'FEHLER: Dieses Skript muss als Administrator ausgefuehrt werden.'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# Start-WebServer.ps1 muss vorhanden sein
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $SCRIPT_PATH -PathType Leaf)) {
    Write-Output ''
    Write-Output "FEHLER: Start-WebServer.ps1 nicht gefunden unter: $SCRIPT_PATH"
    Write-Output 'Beide Skripte muessen im selben Verzeichnis liegen.'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Eingabe mit Default-Wert
# Zeigt "[Default]" an und gibt Default zurueck wenn Eingabe leer ist.
# ---------------------------------------------------------------------------
function Read-HostWithDefault {
    param(
        [string] $Prompt,
        [string] $Default
    )
    $input = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
    return $input.Trim()
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Ja/Nein-Abfrage
# Gibt $true zurueck bei J/j/Y/y, $false bei N/n und allem anderen.
# ---------------------------------------------------------------------------
function Read-YesNo {
    param(
        [string] $Prompt,
        [bool]   $Default = $false
    )
    $defaultHint = if ($Default) { 'J/n' } else { 'j/N' }
    $input = (Read-Host "$Prompt ($defaultHint)").Trim()
    if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
    return $input -match '^[JjYy]'
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Thumbprint bereinigen
# Entfernt unsichtbare Unicode-Zeichen (U+200E u.a.) und Leerzeichen.
# netsh schlaegt bei verunreinigten Thumbprints mit kryptischem Fehler fehl.
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
Write-Output "Task-Name   : $TASK_NAME"
Write-Output "Skript      : $SCRIPT_PATH"
Write-Output "Arbeitsverz.: $WORK_DIR"
Write-Output ''

# ---------------------------------------------------------------------------
# Benutzername und Passwort interaktiv abfragen
# ---------------------------------------------------------------------------
Write-Output 'Der Task wird unter einem lokalen Administrator-Account ausgefuehrt.'
Write-Output 'Benutzername leer lassen = "Administrator" verwenden.'
Write-Output ''

$inputUser = Read-Host 'Benutzername (Standard: Administrator)'
if ([string]::IsNullOrWhiteSpace($inputUser)) {
    $taskUser = 'Administrator'
} else {
    $taskUser = $inputUser.Trim()
}

$securePwd = Read-Host "Passwort fuer '$taskUser'" -AsSecureString
$bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
$taskPassword = $null
try {
    $taskPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    # BSTR immer nullen - unabhaengig davon ob die Konvertierung erfolgreich war
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrEmpty($taskPassword)) {
    Write-Output ''
    Write-Output 'FEHLER: Passwort darf nicht leer sein.'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# API-Key abfragen und als System-Umgebungsvariable setzen
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output 'API-Key fuer POSH_API_KEY (Eingabe wird angezeigt - Fenster beobachten):'
$apiKey = Read-Host 'API-Key'

if ([string]::IsNullOrEmpty($apiKey)) {
    Write-Output ''
    Write-Output 'FEHLER: API-Key darf nicht leer sein.'
    Write-Output ''
    exit 1
}

[Environment]::SetEnvironmentVariable('POSH_API_KEY', $apiKey, 'Machine')
$apiKey = $null   # sofort aus Speicher loeschen
Write-Output "POSH_API_KEY als System-Umgebungsvariable gesetzt."

# ---------------------------------------------------------------------------
# HTTPS-Konfiguration
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ' HTTPS-Konfiguration'
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ''

$httpsEnabled = Read-YesNo -Prompt 'HTTPS aktivieren?' -Default $false

# Ports abfragen - immer (HTTP-Port benoetigt auch ohne HTTPS)
Write-Output ''
$httpPortStr  = Read-HostWithDefault -Prompt 'HTTP-Port'  -Default '80'
$httpPort     = [int]$httpPortStr

# HTTPS-spezifische Konfiguration
$httpsPort      = 443
$httpDisabled   = $false
$certThumbprint = $null

if ($httpsEnabled) {
    $httpsPortStr = Read-HostWithDefault -Prompt 'HTTPS-Port' -Default '443'
    $httpsPort    = [int]$httpsPortStr

    # ------------------------------------------------------------------
    # Zertifikat-Quelle auswaehlen
    # ------------------------------------------------------------------
    Write-Output ''
    Write-Output 'Zertifikat-Quelle:'
    Write-Output '  1) Neues Self-Signed Zertifikat erstellen'
    Write-Output '  2) Bestehendes Zertifikat verwenden'
    Write-Output ''
    $certSource = Read-HostWithDefault -Prompt 'Auswahl' -Default '1'

    if ($certSource -eq '1') {
        # --------------------------------------------------------------
        # Option 1: Self-Signed Zertifikat erstellen
        # --------------------------------------------------------------
        Write-Output ''
        $certYearsStr = Read-HostWithDefault -Prompt 'Zertifikat-Laufzeit in Jahren' -Default '10'
        $certYears    = [int]$certYearsStr
        if ($certYears -lt 1) { $certYears = 1 }

        Write-Output ''
        Write-Output 'Erstelle Self-Signed Zertifikat...'

        # Lokale IPv4-Adressen ermitteln (kein Loopback, kein Link-Local)
        $localIPs = @(Get-NetIPAddress `
            -AddressFamily IPv4 `
            -AddressState  Preferred `
            -ErrorAction   SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike '127.*' -and
                $_.IPAddress -notlike '169.254.*'
            } |
            Select-Object -ExpandProperty IPAddress)

        # SAN-String aufbauen: DNS-Eintraege zuerst, dann IPs
        # 127.0.0.1 immer einschliessen - auch wenn nicht in localIPs
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
            # -DnsName darf nicht kombiniert mit -TextExtension (SAN-OID 2.5.29.17) verwendet werden -
            # Windows lehnt beide SAN-Quellen gleichzeitig ab ("DnsName-Parameter steht in Konflikt").
            # Alle SANs (DNS + IP) werden ausschliesslich ueber -TextExtension gesetzt.
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
            Write-Output "FEHLER: Zertifikat konnte nicht erstellt werden: $_"
            Write-Output ''
            exit 1
        }

        $certThumbprint = Get-CleanThumbprint -Thumbprint $cert.Thumbprint

        Write-Output "  Subject    : $($cert.Subject)"
        Write-Output "  SAN        : $env:COMPUTERNAME, localhost, $($localIPs -join ', ')"
        Write-Output "  Gueltig    : $certYears Jahr(e) (bis $($certNotAfter.ToString('yyyy-MM-dd')))"
        Write-Output "  Store      : LocalMachine\My"
        Write-Output "  Thumbprint : $certThumbprint"

    } else {
        # --------------------------------------------------------------
        # Option 2: Bestehendes Zertifikat verwenden
        # --------------------------------------------------------------
        Write-Output ''
        Write-Output 'Zertifikat angeben:'
        Write-Output '  A) Thumbprint (Zertifikat bereits in LocalMachine\My installiert)'
        Write-Output '  B) PFX-Datei importieren'
        Write-Output ''
        $certInputMethod = (Read-HostWithDefault -Prompt 'Auswahl' -Default 'A').ToUpper()

        if ($certInputMethod -eq 'A') {
            # ----------------------------------------------------------
            # Option 2A: Thumbprint direkt eingeben
            # ----------------------------------------------------------
            Write-Output ''
            $rawThumb = Read-Host 'Thumbprint'
            if ([string]::IsNullOrWhiteSpace($rawThumb)) {
                Write-Output ''
                Write-Output 'FEHLER: Thumbprint darf nicht leer sein.'
                Write-Output ''
                exit 1
            }

            $certThumbprint = Get-CleanThumbprint -Thumbprint $rawThumb

            # Zertifikat im Store suchen
            Write-Output ''
            Write-Output 'Suche Zertifikat in LocalMachine\My...'
            $cert = Get-ChildItem 'Cert:\LocalMachine\My' |
                Where-Object { (Get-CleanThumbprint -Thumbprint $_.Thumbprint) -eq $certThumbprint } |
                Select-Object -First 1

            if ($null -eq $cert) {
                Write-Output ''
                Write-Output "FEHLER: Zertifikat mit Thumbprint '$certThumbprint' nicht in Cert:\LocalMachine\My gefunden."
                Write-Output 'Loesung: Zertifikat zuerst in den Store importieren oder Option B (PFX) waehlen.'
                Write-Output ''
                exit 1
            }

            # Ablaufdatum pruefen
            if ($cert.NotAfter -lt (Get-Date)) {
                Write-Output ''
                Write-Output "FEHLER: Zertifikat ist abgelaufen (NotAfter: $($cert.NotAfter.ToString('yyyy-MM-dd')))."
                Write-Output 'Loesung: Ein gueltiges Zertifikat verwenden.'
                Write-Output ''
                exit 1
            }

            Write-Output "  Gefunden   : $($cert.Subject)"
            Write-Output "  Gueltig bis: $($cert.NotAfter.ToString('yyyy-MM-dd'))"
            Write-Output "  Thumbprint : $certThumbprint"

        } else {
            # ----------------------------------------------------------
            # Option 2B: PFX-Datei importieren
            # ----------------------------------------------------------
            Write-Output ''
            $pfxPath = Read-Host 'Pfad zur PFX-Datei'
            if ([string]::IsNullOrWhiteSpace($pfxPath)) {
                Write-Output ''
                Write-Output 'FEHLER: Pfad darf nicht leer sein.'
                Write-Output ''
                exit 1
            }
            $pfxPath = $pfxPath.Trim('"').Trim()

            if (-not (Test-Path -LiteralPath $pfxPath -PathType Leaf)) {
                Write-Output ''
                Write-Output "FEHLER: Datei nicht gefunden: $pfxPath"
                Write-Output ''
                exit 1
            }

            $pfxPassword = Read-Host 'PFX-Passwort (leer lassen wenn kein Passwort)' -AsSecureString

            Write-Output ''
            Write-Output 'Importiere Zertifikat...'

            try {
                $imported = Import-PfxCertificate `
                    -FilePath          $pfxPath `
                    -CertStoreLocation 'Cert:\LocalMachine\My' `
                    -Password          $pfxPassword `
                    -Exportable `
                    -ErrorAction       Stop
            } catch {
                Write-Output ''
                Write-Output "FEHLER: PFX konnte nicht importiert werden: $_"
                Write-Output 'Moegliche Ursachen: falsches Passwort, beschaedigte Datei, kein privater Schluessel.'
                Write-Output ''
                exit 1
            } finally {
                # SecureString aus dem Speicher loeschen
                if ($null -ne $pfxPassword) {
                    $pfxPassword.Dispose()
                    $pfxPassword = $null
                }
            }

            # Bei PFX-Ketten gibt Import-PfxCertificate ein Array zurueck.
            # Das Endentitaets-Zertifikat (mit privatem Schluessel) verwenden.
            $cert = @($imported) | Where-Object { $_.HasPrivateKey } | Select-Object -First 1

            if ($null -eq $cert) {
                Write-Output ''
                Write-Output 'FEHLER: Kein Zertifikat mit privatem Schluessel in der PFX-Datei gefunden.'
                Write-Output ''
                exit 1
            }

            # Ablaufdatum pruefen
            if ($cert.NotAfter -lt (Get-Date)) {
                Write-Output ''
                Write-Output "FEHLER: Importiertes Zertifikat ist abgelaufen (NotAfter: $($cert.NotAfter.ToString('yyyy-MM-dd')))."
                Write-Output ''
                exit 1
            }

            $certThumbprint = Get-CleanThumbprint -Thumbprint $cert.Thumbprint

            Write-Output "  Importiert : $($cert.Subject)"
            Write-Output "  Gueltig bis: $($cert.NotAfter.ToString('yyyy-MM-dd'))"
            Write-Output "  Thumbprint : $certThumbprint"
        }
    }

    # ------------------------------------------------------------------
    # netsh sslcert-Bindung setzen
    # Erst vorhandene Bindung loeschen (sauberes Re-Install),
    # dann neue Bindung hinzufuegen.
    # ------------------------------------------------------------------
    Write-Output ''
    Write-Output "Binde Zertifikat an Port $httpsPort (netsh sslcert)..."

    # Vorhandene Bindung entfernen - Exit-Code immer ignorieren (1 = nicht vorhanden = ok)
    $null = netsh http delete sslcert "ipport=0.0.0.0:$httpsPort" 2>&1

    # Neue Bindung setzen
    $addOut = netsh http add sslcert "ipport=0.0.0.0:$httpsPort" "certhash=$certThumbprint" "appid={$POSH_APP_GUID}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output ''
        Write-Output "FEHLER: netsh sslcert add fehlgeschlagen (Exit: $LASTEXITCODE): $addOut"
        Write-Output "Pruefen: netsh http show sslcert ipport=0.0.0.0:$httpsPort"
        Write-Output ''
        exit 1
    }

    Write-Output "  OK - Zertifikat gebunden an 0.0.0.0:$httpsPort"

    # Thumbprint als Machine-Env fuer Diagnostics (kein Secret - nur Fingerabdruck)
    [Environment]::SetEnvironmentVariable('POSH_CERT_THUMBPRINT', $certThumbprint, 'Machine')

    # ------------------------------------------------------------------
    # HTTP deaktivieren?
    # ------------------------------------------------------------------
    Write-Output ''
    $httpDisabled = Read-YesNo -Prompt "HTTP (Port $httpPort) deaktivieren?" -Default $false
    if ($httpDisabled) {
        Write-Output "  HTTP wird deaktiviert - nur HTTPS (Port $httpsPort) aktiv."
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

# Aktive Ports zusammenstellen
$activePorts = [System.Collections.Generic.List[int]]::new()
if (-not $httpsEnabled -or -not $httpDisabled) {
    $null = $activePorts.Add($httpPort)
}
if ($httpsEnabled) {
    $null = $activePorts.Add($httpsPort)
}

$openFirewall = Read-YesNo -Prompt "Ports ($($activePorts -join ', ')) in Windows Firewall oeffnen?" -Default $false

if ($openFirewall) {
    Write-Output ''
    foreach ($port in $activePorts) {
        $ruleName = "posh-webserver-$port"
        $existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Write-Output "  Port $port  - Regel '$ruleName' existiert bereits, wird uebersprungen."
        } else {
            try {
                $null = New-NetFirewallRule `
                    -Name        $ruleName `
                    -DisplayName "posh-webserver Port $port" `
                    -Description 'PowerShell Webserver - eingehender HTTP/HTTPS-Verkehr' `
                    -Direction   Inbound `
                    -Protocol    TCP `
                    -LocalPort   $port `
                    -Action      Allow `
                    -Profile     Any `
                    -ErrorAction Stop
                Write-Output "  Port $port  - Regel '$ruleName' angelegt."
            } catch {
                Write-Output "  Port $port  - WARNUNG: Firewall-Regel konnte nicht angelegt werden: $_"
                # Kein exit 1 - Firewall-Fehler soll Setup nicht abbrechen
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Vorhandenen Task entfernen (sauberes Update)
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ' Scheduled Task'
Write-Output '─────────────────────────────────────────────────────────────────────────'
Write-Output ''

$existingTask = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Output "Vorhandener Task '$TASK_NAME' wird entfernt..."
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
}

# ---------------------------------------------------------------------------
# pwsh.exe-Pfad aufloesen
# ---------------------------------------------------------------------------
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
    $pwshExe = 'C:\Program Files\PowerShell\7\pwsh.exe'
}
if (-not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
    Write-Output ''
    Write-Output 'FEHLER: pwsh.exe nicht gefunden. Ist PowerShell 7 installiert?'
    Write-Output ''
    exit 1
}

# ---------------------------------------------------------------------------
# Task-Action-Argument aufbauen
# Start-WebServer.ps1 erhaelt alle relevanten Parameter direkt.
# -HttpsEnabled als Switch: einfach angeben, kein ':$true' noetig.
# -HttpPort 0 signalisiert: HTTP deaktiviert.
# ---------------------------------------------------------------------------
$scriptArgs = '-NonInteractive -NoProfile -ExecutionPolicy Bypass'
$scriptArgs += " -File `"$SCRIPT_PATH`""
$scriptArgs += " -HttpPort $httpPort"

if ($httpsEnabled) {
    $scriptArgs += ' -HttpsEnabled'
    $scriptArgs += " -HttpsPort $httpsPort"
    if ($httpDisabled) {
        # HttpPort 0 = HTTP deaktiviert - Guard in Start-WebServer.ps1: if ($HttpPort -gt 0)
        $scriptArgs = $scriptArgs -replace "-HttpPort $httpPort", '-HttpPort 0'
    }
}

# ---------------------------------------------------------------------------
# Task-Komponenten
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
# Task registrieren
# ---------------------------------------------------------------------------
try {
    $task = Register-ScheduledTask `
        -TaskName    $TASK_NAME `
        -Description 'PowerShell HTTP/HTTPS-Webserver - fuehrt .ps1-Skripte per HTTP-Request aus' `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -User        $taskUser `
        -Password    $taskPassword `
        -RunLevel    Highest `
        -Force

    Write-Output "Task '$TASK_NAME' erfolgreich registriert."
    Write-Output ''
    Write-Output "Status      : $($task.State)"
    Write-Output "Benutzer    : $taskUser"
    Write-Output "Shell       : $pwshExe"
    Write-Output "Argumente   : $scriptArgs"
    Write-Output ''

    # Zusammenfassung der Netzwerk-Konfiguration
    Write-Output 'Netzwerk-Konfiguration:'
    if (-not $httpsEnabled -or -not $httpDisabled) {
        Write-Output "  HTTP  : http://+:$httpPort/  (aktiv)"
    } else {
        Write-Output "  HTTP  : deaktiviert"
    }
    if ($httpsEnabled) {
        Write-Output "  HTTPS : https://+:$httpsPort/ (aktiv)"
        Write-Output "  Zert. : $certThumbprint (bis $($cert.NotAfter.ToString('yyyy-MM-dd')))"
    }
    Write-Output ''
    Write-Output 'Jetzt sofort starten (ohne Neustart):'
    Write-Output "  Start-ScheduledTask -TaskName '$TASK_NAME'"
    Write-Output ''
    Write-Output 'Task entfernen:'
    Write-Output "  Unregister-ScheduledTask -TaskName '$TASK_NAME' -Confirm:`$false"
    Write-Output ''

} catch {
    Write-Output ''
    Write-Output "FEHLER beim Registrieren des Tasks: $_"
    Write-Output ''
    exit 1
} finally {
    # Passwort in allen Pfaden aus dem Speicher loeschen
    $taskPassword = $null
}
