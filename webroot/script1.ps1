#Requires -Version 7.0
<#
.SYNOPSIS
    Example script: Returns system information.

.DESCRIPTION
    Demonstrates parameter passing via query string.
    Call: http://localhost/script1.ps1?ComputerName=localhost&Detail=true

.PARAMETER ComputerName
    Name of the computer (default: local computer)

.PARAMETER Detail
    When $true, additional details are included in the output
#>
param(
    [string] $ComputerName = $env:COMPUTERNAME,
    [string] $Detail       = 'false'
)

$showDetail = $Detail -eq 'true' -or $Detail -eq '1'

Write-Output "=== System Information ==="
Write-Output "Hostname    : $ComputerName"
Write-Output "Timestamp   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Called from : $($MyInvocation.MyCommand.Path)"

if ($showDetail) {
    Write-Output ""
    Write-Output "=== Details ==="

    # Single WMI call — result reused for OS info, uptime, and RAM
    $os = Get-CimInstance Win32_OperatingSystem -ComputerName $ComputerName

    Write-Output "OS          : $($os.Caption)"
    Write-Output "Uptime      : $((Get-Date) - $os.LastBootUpTime)"
    Write-Output "CPU load    : $((Get-CimInstance Win32_Processor -ComputerName $ComputerName).LoadPercentage)%"

    $ramUsedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
    $ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    Write-Output "RAM         : $ramUsedGB GB / $ramTotalGB GB used"
}

Write-Output ""
Write-Output "Done."
