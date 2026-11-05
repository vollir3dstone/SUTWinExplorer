param([switch] $ListOnly)

$ErrorActionPreference = 'Stop'
$directoryObserverName = 'DirectoryObservers.Tests.ps1'
$discovered = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)
$directoryObserver = @($discovered | Where-Object Name -eq $directoryObserverName)
if ($directoryObserver.Count -ne 1) { throw "Expected exactly one $directoryObserverName." }
$tests = @($discovered | Where-Object Name -ne $directoryObserverName) + $directoryObserver

if ($ListOnly) {
    $tests | ForEach-Object { $_.Name }
    return
}

$failed = [Collections.Generic.List[string]]::new()
$previousObserver = [Environment]::GetEnvironmentVariable('KIS_DIRECTORY_OBSERVER')
try {
    [Environment]::SetEnvironmentVariable('KIS_DIRECTORY_OBSERVER', 'filesystem')
    foreach ($test in $tests) {
        Write-Host "Running $($test.Name)..."
        & pwsh -NoProfile -STA -File $test.FullName
        if ($LASTEXITCODE -eq 0) {
            Write-Host "PASS $($test.Name)"
        } else {
            Write-Host "FAIL $($test.Name) (exit $LASTEXITCODE)"
            $failed.Add($test.Name)
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable('KIS_DIRECTORY_OBSERVER', $previousObserver)
}

Write-Host "Tests: $($tests.Count), passed: $($tests.Count - $failed.Count), failed: $($failed.Count)."
if ($failed.Count -gt 0) {
    Write-Host "Failed: $($failed -join ', ')"
    exit 1
}