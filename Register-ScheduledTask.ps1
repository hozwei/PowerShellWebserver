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
# Benutzername und Passwort interaktiv abfragen
# Der Task laeuft unter diesem User - muss ein lokaler Administrator sein.
# Standard: Administrator - kann fuer andere User angepasst werden.
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output 'PowerShell Webserver - Scheduled Task Registration'
Write-Output "Task-Name   : $TASK_NAME"
Write-Output "Skript      : $SCRIPT_PATH"
Write-Output "Arbeitsverz.: $WORK_DIR"
Write-Output ''
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
# Machine-Scope: gilt fuer alle Prozesse auf dem System inkl. Scheduled Tasks
# Der Key wird nicht im Klartext ausgegeben - Read-Host ohne -AsSecureString
# damit der Wert direkt verwendet werden kann ohne Marshal-Konvertierung
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
Write-Output ''
Write-Output "Benutzer    : $taskUser"
Write-Output ''

# ---------------------------------------------------------------------------
# Vorhandenen Task entfernen (sauberes Update)
# ---------------------------------------------------------------------------
$existingTask = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Output "Vorhandener Task '$TASK_NAME' wird entfernt..."
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
}

# ---------------------------------------------------------------------------
# Task-Komponenten
# ---------------------------------------------------------------------------

# pwsh.exe-Pfad auflösen - im Scheduled-Task-Kontext ist PATH nicht garantiert
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

# Aktion: pwsh.exe (PowerShell 7) mit dem Webserver-Skript
# -NonInteractive : kein Prompt, kein Warten auf Input
# -NoProfile      : schneller Start, kein Benutzerprofil
# -ExecutionPolicy Bypass : keine Probleme mit signierten Skripten
# -File            : Skriptpfad
$action = New-ScheduledTaskAction `
    -Execute          $pwshExe `
    -Argument         "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$SCRIPT_PATH`"" `
    -WorkingDirectory $WORK_DIR

# Trigger: beim Systemstart
$trigger = New-ScheduledTaskTrigger -AtStartup

# Einstellungen
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

# RestartCount und RestartInterval sind Eigenschaften des Objekts, keine Parameter des Cmdlets
$settings.RestartCount    = 3
$settings.RestartInterval = 'PT1M'

# ---------------------------------------------------------------------------
# Task registrieren
# ---------------------------------------------------------------------------
try {
    $task = Register-ScheduledTask `
        -TaskName    $TASK_NAME `
        -Description 'PowerShell HTTP-Webserver - fuehrt .ps1-Skripte per HTTP-Request aus' `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -User        $taskUser `
        -Password    $taskPassword `
        -RunLevel    Highest `
        -Force

    Write-Output ''
    Write-Output "Task '$TASK_NAME' erfolgreich registriert."
    Write-Output ''
    Write-Output "Status      : $($task.State)"
    Write-Output "Benutzer    : $taskUser"
    Write-Output 'Trigger     : Beim Systemstart'
    Write-Output 'Shell       : pwsh.exe (PowerShell 7)'
    Write-Output 'Timeout     : keiner (laeuft dauerhaft)'
    Write-Output 'Neustarts   : 3x nach je 1 Minute bei Absturz'
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
