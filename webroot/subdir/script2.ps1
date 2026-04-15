#Requires -Version 7.0
<#
.SYNOPSIS
    Example script in a subdirectory: Lists files in a directory.

.DESCRIPTION
    Demonstrates scripts in subdirectories of webroot.
    Call: http://localhost/subdir/script2.ps1?Path=C:\Windows\Temp&Filter=*.log

.PARAMETER Path
    Directory to list (default: TEMP)

.PARAMETER Filter
    File filter (default: * = all files)
#>
param(
    [string] $Path   = $env:TEMP,
    [string] $Filter = '*'
)

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Error "Directory not found: $Path"
    exit 1
}

$items = Get-ChildItem -Path $Path -Filter $Filter -ErrorAction SilentlyContinue

Write-Output "=== Directory Listing ==="
Write-Output "Path    : $Path"
Write-Output "Filter  : $Filter"
Write-Output "Count   : $($items.Count) entries"
Write-Output ""

if ($items.Count -eq 0) {
    Write-Output "(No files found)"
} else {
    foreach ($item in $items | Sort-Object Name) {
        $type = if ($item.PSIsContainer) { '[DIR] ' } else { '[FILE]' }
        $size = if ($item.PSIsContainer) { '' } else { "$([math]::Round($item.Length / 1KB, 1)) KB" }
        Write-Output "$type $($item.Name.PadRight(40)) $($size.PadLeft(10))  $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
    }
}

Write-Output ""
Write-Output "Done."
