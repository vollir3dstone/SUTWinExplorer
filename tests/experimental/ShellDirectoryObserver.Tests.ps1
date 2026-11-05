param([string[]] $Scenarios)

$parameters = @{ Modes = @('shell') }
if ($PSBoundParameters.ContainsKey('Scenarios')) {
    $parameters.Scenarios = $Scenarios
}
& (Join-Path $PSScriptRoot '..\DirectoryObservers.Tests.ps1') @parameters