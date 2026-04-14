#Requires -Version 7.0
<#
.SYNOPSIS
    Beispielskript in einem Unterordner: Listet Dateien in einem Verzeichnis.

.DESCRIPTION
    Demonstriert Skripte in Unterverzeichnissen des webroot.
    Aufruf: http://localhost/subdir/script2.ps1?Path=C:\Windows\Temp&Filter=*.log

.PARAMETER Path
    Verzeichnis das aufgelistet werden soll (Standard: TEMP)

.PARAMETER Filter
    Dateifilter (Standard: * = alle Dateien)
#>
param(
    [string] $Path   = $env:TEMP,
    [string] $Filter = '*'
)

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Error "Verzeichnis nicht gefunden: $Path"
    exit 1
}

$items = Get-ChildItem -Path $Path -Filter $Filter -ErrorAction SilentlyContinue

Write-Output "=== Verzeichnisliste ==="
Write-Output "Pfad    : $Path"
Write-Output "Filter  : $Filter"
Write-Output "Anzahl  : $($items.Count) Eintraege"
Write-Output ""

if ($items.Count -eq 0) {
    Write-Output "(Keine Dateien gefunden)"
} else {
    foreach ($item in $items | Sort-Object Name) {
        $type = if ($item.PSIsContainer) { '[DIR] ' } else { '[FILE]' }
        $size = if ($item.PSIsContainer) { '' } else { "$([math]::Round($item.Length / 1KB, 1)) KB" }
        Write-Output "$type $($item.Name.PadRight(40)) $($size.PadLeft(10))  $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
    }
}

Write-Output ""
Write-Output "Fertig."
