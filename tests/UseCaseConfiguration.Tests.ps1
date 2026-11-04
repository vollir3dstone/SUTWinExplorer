$ErrorActionPreference = 'Stop'

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Invoke-Store($store, [string] $method, [object[]] $arguments = @()) {
    return $store.GetType().GetMethod($method).Invoke($store, $arguments)
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
$storeType = $assembly.GetType('SUTWinExplorer.UseCaseStore', $true)
$entryType = $assembly.GetType('SUTWinExplorer.UseCasePathview', $true)
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-use case-test-' + [guid]::NewGuid().ToString('N'))
$filePath = Join-Path $directory "Use case $([char]0x201e)default$([char]0x201c).kisexplorer.json"

try {
    $constructor = $storeType.GetConstructor([type[]] @([string], [string]))
    $store = $constructor.Invoke([object[]] @([string] $directory, 'default'))
    $useCase = Invoke-Store $store 'LoadOrCreate'
    Assert-True (Test-Path -LiteralPath $filePath) 'Default use case file was not created.'
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json._type -eq 'KIS Explorer use case' -and $json.UseCaseName -eq 'default' -and $json.Pathviews.Count -eq 0) 'Invalid default use case.'
    $keys = @($json.Keys)
    Assert-True ($keys[0] -ceq '_type' -and $keys[1] -ceq 'UseCaseName') 'Use case header fields are out of order.'

    $entry = [Activator]::CreateInstance($entryType, $true)
    $entry.Type = 'Pathview'
    $entryType.GetProperty('Name').SetValue($entry, $null)
    $entry.Path = Join-Path $directory 'first'
    $entry.ActionOnUseCaseActivation = 'open'
    $useCase.Pathviews.Add($entry)
    Invoke-Store $store 'Save' @($useCase)
    $useCase = Invoke-Store $store 'LoadOrCreate'
    Assert-True ($useCase.Pathviews.Count -eq 1 -and $null -eq $useCase.Pathviews[0].Name) 'Pathview did not round-trip with a null name.'

    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json.Pathviews[0].ContainsKey('TabColor') -and $null -eq $json.Pathviews[0].TabColor) 'Default TabColor was not saved as null.'
    $json.Pathviews[0].Remove('TabColor')
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $useCase = Invoke-Store $store 'Load'
    Assert-True ($null -eq $useCase.Pathviews[0].TabColor) 'A legacy Pathview without TabColor did not load.'
    $useCase.Pathviews[0].TabColor = '#FF85ADE9'
    Invoke-Store $store 'Save' @($useCase)
    $useCase = Invoke-Store $store 'Load'
    Assert-True ($useCase.Pathviews[0].TabColor -ceq '#FF85ADE9') 'Pathview color did not round-trip.'
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    $json.Pathviews[0].TabColor = '#invalid'
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $before = [System.IO.File]::ReadAllText($filePath)
    $failed = $false
    try { Invoke-Store $store 'Load' } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($filePath) -ceq $before) 'Invalid TabColor was accepted or overwritten.'
    Invoke-Store $store 'Save' @($useCase)

    $useCase.Pathviews[0].Name = 'Custom name'
    Invoke-Store $store 'Save' @($useCase)
    $useCase = Invoke-Store $store 'Load'
    Assert-True ($useCase.Pathviews[0].Name -eq 'Custom name') 'Custom Pathview name did not round-trip.'
    $entryType.GetProperty('Name').SetValue($useCase.Pathviews[0], $null)
    Invoke-Store $store 'Save' @($useCase)
    $useCase = Invoke-Store $store 'Load'
    Assert-True ($null -eq $useCase.Pathviews[0].Name) 'Cleared Pathview name did not round-trip as null.'

    $useCase.Pathviews[0].Path = Join-Path $directory 'renamed'
    Invoke-Store $store 'Save' @($useCase)
    Assert-True ((Invoke-Store $store 'LoadOrCreate').Pathviews[0].Path -eq (Join-Path $directory 'renamed')) 'Renamed path was not saved.'

    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    $json['FutureSetting'] = @{ value = 42 }
    $json.Pathviews[0]['FuturePathviewSetting'] = 'kept'
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $useCase = Invoke-Store $store 'LoadOrCreate'
    Invoke-Store $store 'Save' @($useCase)
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json.FutureSetting.value -eq 42 -and $json.Pathviews[0].FuturePathviewSetting -eq 'kept') 'Unknown properties were lost.'

    $locked = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $failed = $false
        try { Invoke-Store $store 'Save' @($useCase) } catch { $failed = $true }
        Assert-True $failed 'A locked use case unexpectedly saved.'
    } finally { $locked.Dispose() }
    Assert-True ((Invoke-Store $store 'LoadOrCreate').Pathviews.Count -eq 1) 'Save failure damaged the previous use case.'

    $useCase.Pathviews.Clear()
    Invoke-Store $store 'Save' @($useCase)
    Assert-True ((Invoke-Store $store 'LoadOrCreate').Pathviews.Count -eq 0) 'Removed Pathview returned.'

    $otherStore = $constructor.Invoke([object[]] @([string] $directory, 'other'))
    $otherUseCase = Invoke-Store $otherStore 'LoadOrCreate'
    Assert-True ($otherUseCase.UseCaseName -eq 'other' -and (Test-Path -LiteralPath (Join-Path $directory "Use case $([char]0x201e)other$([char]0x201c).kisexplorer.json"))) 'A second use case could not be stored independently.'
    $otherPath = Join-Path $directory "Use case $([char]0x201e)other$([char]0x201c).kisexplorer.json"
    $otherJson = Get-Content -LiteralPath $otherPath -Raw | ConvertFrom-Json -AsHashtable
    $otherJson.FutureSetting = @{ value = 42 }
    $otherJson.Pathviews = @($json.Pathviews[0])
    $otherJson | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $otherPath -Encoding utf8
    $otherUseCase = Invoke-Store $otherStore 'Load'
    $beforeOther = [System.IO.File]::ReadAllText($otherPath)
    $failed = $false
    try { Invoke-Store $otherStore 'Create' @($otherUseCase) } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($otherPath) -ceq $beforeOther) 'Creating an existing use case overwrote it.'
    $names = @(Invoke-Store $store 'GetUseCaseNames')
    Assert-True ($names.Count -eq 2 -and 'default' -in $names -and 'other' -in $names) 'Use case discovery did not return both use case names.'
    $missingStore = Invoke-Store $store 'ForUseCase' @('missing')
    $failed = $false
    try { Invoke-Store $missingStore 'Load' } catch { $failed = $true }
    Assert-True ($failed -and @(Invoke-Store $store 'GetUseCaseNames').Count -eq 2) 'Loading a missing use case unexpectedly created it.'

    $failed = $false
    try { Invoke-Store $store 'Delete' } catch { $failed = $true }
    Assert-True ($failed -and (Test-Path -LiteralPath $filePath)) 'The default use case could be deleted.'
    $failed = $false
    try { Invoke-Store $store 'Rename' @($useCase, 'renamed-default') } catch { $failed = $true }
    Assert-True ($failed -and (Test-Path -LiteralPath $filePath)) 'The default use case could be renamed.'

    $failed = $false
    try { Invoke-Store $otherStore 'Rename' @($otherUseCase, 'default') } catch { $failed = $true }
    Assert-True ($failed -and $otherUseCase.UseCaseName -eq 'other' -and (Test-Path -LiteralPath $filePath)) 'Renaming overwrote an existing use case.'
    $failed = $false
    try { Invoke-Store $otherStore 'Rename' @($otherUseCase, 'new') } catch { $failed = $true }
    Assert-True ($failed -and $otherUseCase.UseCaseName -eq 'other') 'The reserved name was accepted.'

    $otherStore = Invoke-Store $otherStore 'Rename' @($otherUseCase, 'renamed')
    Assert-True ($otherUseCase.UseCaseName -eq 'renamed' -and (Invoke-Store $otherStore 'Load').UseCaseName -eq 'renamed') 'Use case rename did not update the filename and JSON name.'
    $renamedPath = Join-Path $directory "Use case $([char]0x201e)renamed$([char]0x201c).kisexplorer.json"
    $renamedJson = Get-Content -LiteralPath $renamedPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($renamedJson.FutureSetting.value -eq 42 -and $renamedJson.Pathviews[0].FuturePathviewSetting -eq 'kept') 'Use case rename lost Pathviews or unknown properties.'
    $otherStore = Invoke-Store $otherStore 'Rename' @($otherUseCase, 'RENAMED')
    Assert-True ($otherUseCase.UseCaseName -eq 'RENAMED' -and (Invoke-Store $otherStore 'Load').UseCaseName -eq 'RENAMED') 'Case-only use case rename failed.'
    Invoke-Store $otherStore 'Delete'
    Assert-True (@(Invoke-Store $store 'GetUseCaseNames').Count -eq 1) 'Deleted use case remains in discovery.'

    $savedPath = $json.Pathviews[0].Path
    $json.Pathviews[0].Path = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $failed = $false
    try { Invoke-Store $store 'LoadOrCreate' } catch { $failed = $true }
    Assert-True $failed 'A virtual This PC location was accepted as a filesystem path.'
    $json.Pathviews[0].Path = $savedPath

    $json.Pathviews += $json.Pathviews[0]
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $before = [System.IO.File]::ReadAllText($filePath)
    $failed = $false
    try { Invoke-Store $store 'LoadOrCreate' } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($filePath) -ceq $before) 'Duplicate paths were accepted or overwritten.'

    [System.IO.File]::WriteAllText($filePath, '{invalid json')
    $failed = $false
    try { Invoke-Store $store 'LoadOrCreate' } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($filePath) -ceq '{invalid json') 'Malformed use case was accepted or overwritten.'
    Write-Output 'Use case configuration tests passed.'
} finally {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}