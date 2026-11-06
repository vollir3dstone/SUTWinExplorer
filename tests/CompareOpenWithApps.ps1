param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path
)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Run this script in an STA process, for example: pwsh -NoProfile -STA -File tests/CompareOpenWithApps.ps1 -Path .wav'
}
$assemblyPath = Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
$accessor = $assembly.GetType('SUTWinExplorer.RunningAppsAccessor', $true)
$all = @($accessor.GetMethod('GetRegisteredApps').Invoke($null, @($Path)))
$chosen = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @($Path)))
"All handlers: $($all.Count); apps to choose from: $($chosen.Count)"
@($all + $chosen) | Sort-Object Id -Unique | Sort-Object Name, Id | ForEach-Object {
    [PSCustomObject]@{ AllHandlers = $_.Id -in $all.Id; Chosen = $_.Id -in $chosen.Id; Name = $_.Name; Id = $_.Id }
} | Format-List