#Requires -Version 7.0
<#
.SYNOPSIS
    Returns OS and host information for the local machine.

.DESCRIPTION
    Demonstrates a webroot script in a subdirectory — reachable via
    `/subdir/system-info.ps1`. Pulls one CIM snapshot of
    `Win32_OperatingSystem` and reports hostname, uptime, OS caption,
    PowerShell version, and free / total RAM. The `-Detail` switch
    extends the output with current CPU load and a per-drive disk
    listing.

.PARAMETER ComputerName
    Target host. Defaults to the local machine. Pass any reachable name
    that supports CIM/WMI remoting.

.PARAMETER Detail
    When 'true', adds CPU load and disk usage to the response.

.EXAMPLE
    Invoke-RestMethod -Uri 'http://localhost/subdir/system-info.ps1?Detail=true' `
        -Headers @{ 'X-Api-Key' = 'your-key' }
#>
param(
    [string] $ComputerName = $env:COMPUTERNAME,
    [string] $Detail       = 'false'
)

$ErrorActionPreference = 'Stop'
$showDetail = $Detail -eq 'true' -or $Detail -eq '1'

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ComputerName
} catch {
    Write-Error "Could not query CIM on '$ComputerName': $($_.Exception.Message)"
    exit 1
}

$ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$ramUsedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)

$result = [ordered]@{
    hostname     = $ComputerName
    timestamp    = (Get-Date).ToString('o')
    os           = $os.Caption
    osVersion    = $os.Version
    psVersion    = $PSVersionTable.PSVersion.ToString()
    uptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    ramUsedGB    = $ramUsedGB
    ramTotalGB   = $ramTotalGB
    ramFreePct   = [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
}

if ($showDetail) {
    $cpu = Get-CimInstance -ClassName Win32_Processor -ComputerName $ComputerName |
           Select-Object -First 1
    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -ComputerName $ComputerName -Filter 'DriveType = 3' |
        ForEach-Object {
            [ordered]@{
                drive    = $_.DeviceID
                totalGB  = [math]::Round($_.Size / 1GB, 2)
                freeGB   = [math]::Round($_.FreeSpace / 1GB, 2)
                freePct  = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
            }
        }
    $result.cpuModel    = $cpu.Name.Trim()
    $result.cpuLoadPct  = $cpu.LoadPercentage
    $result.disks       = @($disks)
}

$result | ConvertTo-Json -Depth 5
exit 0
