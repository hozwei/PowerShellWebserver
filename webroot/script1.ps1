#Requires -Version 7.0
<#
.SYNOPSIS
    Beispielskript: Gibt Systeminformationen zurueck.

.DESCRIPTION
    Demonstriert die Parameteruebertragung via Query-String.
    Aufruf: http://localhost/script1.ps1?ComputerName=localhost&Detail=true

.PARAMETER ComputerName
    Name des Computers (Standard: lokaler Computer)

.PARAMETER Detail
    Bei $true werden zusaetzliche Details ausgegeben
#>
param(
    [string] $ComputerName = $env:COMPUTERNAME,
    [string] $Detail       = 'false'
)

$showDetail = $Detail -eq 'true' -or $Detail -eq '1'

Write-Output "=== Systeminformation ==="
Write-Output "Hostname    : $ComputerName"
Write-Output "Zeitstempel : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Aufgerufen  : $($MyInvocation.MyCommand.Path)"

if ($showDetail) {
    Write-Output ""
    Write-Output "=== Details ==="

    # Einmaliger WMI-Aufruf - Ergebnis wird fuer OS-Info, Uptime und RAM wiederverwendet
    $os = Get-CimInstance Win32_OperatingSystem

    Write-Output "OS          : $($os.Caption)"
    Write-Output "Uptime      : $((Get-Date) - $os.LastBootUpTime)"
    Write-Output "CPU-Last    : $((Get-CimInstance Win32_Processor).LoadPercentage)%"

    $ramUsedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
    $ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    Write-Output "RAM         : $ramUsedGB GB / $ramTotalGB GB belegt"
}

Write-Output ""
Write-Output "Fertig."
