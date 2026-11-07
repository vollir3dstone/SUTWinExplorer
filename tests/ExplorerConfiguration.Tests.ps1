$ErrorActionPreference = 'Stop'

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
$storeType = $assembly.GetType('SUTWinExplorer.ExplorerConfigurationStore', $true)
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-configuration-test-' + [guid]::NewGuid().ToString('N'))
$filePath = Join-Path $directory 'KIS Explorer Configuration.kisexplorer.json'

try {
    $store = [Activator]::CreateInstance($storeType, [object[]] @([string] $directory))
    $configuration = $store.LoadOrCreate()
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json._type -ceq 'KIS Explorer Configuration' -and $json._version -ceq '1.01' -and
        -not $json.Interface.ShowDirectoryRowActionButtons -and -not $json.Interface.ShowSelectedItemsActionButtons -and
        -not $json.Interface.ShowDirectoryColumnActionButtons -and -not $json.Interface.EnableInternalItemTransfers) 'Default configuration is incorrect.'
    Assert-True (@($json.Keys)[0] -ceq '_type' -and @($json.Keys)[1] -ceq '_version') 'Configuration header order is incorrect.'
    Assert-True (($json.Interface.Keys -join '|') -ceq 'ShowDirectoryRowActionButtons|ShowDirectoryColumnActionButtons|ShowSelectedItemsActionButtons|EnableInternalItemTransfers') 'Interface property names or order are incorrect.'

    $json.Interface.Remove('EnableInternalItemTransfers')
    $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filePath -Encoding utf8
    $configuration = $store.Load()
    Assert-True (-not $configuration.Interface.EnableInternalItemTransfers) 'A missing transfer setting did not default to false.'

    $configuration.Interface.ShowDirectoryRowActionButtons = $true
    $configuration.Interface.ShowDirectoryColumnActionButtons = $true
    $configuration.Interface.EnableInternalItemTransfers = $true
    $store.Save($configuration)
    $configuration = $store.Load()
    Assert-True ($configuration.Interface.ShowDirectoryRowActionButtons -and -not $configuration.Interface.ShowSelectedItemsActionButtons -and
        $configuration.Interface.ShowDirectoryColumnActionButtons -and $configuration.Interface.EnableInternalItemTransfers) 'Configuration did not round-trip.'

    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    $json.FutureSetting = @{ Value = 42 }
    $json.Interface.FutureSetting = 'retained'
    $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filePath -Encoding utf8
    $configuration = $store.Load()
    $store.Save($configuration)
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json.FutureSetting.Value -eq 42 -and $json.Interface.FutureSetting -ceq 'retained') 'Unknown configuration properties were lost.'

    $locked = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $failed = $false
        try { $store.Save($configuration) } catch { $failed = $true }
        Assert-True $failed 'A locked configuration unexpectedly saved.'
    } finally { $locked.Dispose() }
    Assert-True ($store.Load().Interface.ShowDirectoryRowActionButtons) 'A failed save damaged the existing configuration.'

    foreach ($case in @('version', 'type', 'missing', 'wrong-type', 'wrong-transfer-type', 'null-interface')) {
        $invalid = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
        switch ($case) {
            'version' { $invalid._version = '2.0' }
            'type' { $invalid._type = 'Other' }
            'missing' { $invalid.Interface.Remove('ShowSelectedItemsActionButtons') }
            'wrong-type' { $invalid.Interface.ShowSelectedItemsActionButtons = 'false' }
            'wrong-transfer-type' { $invalid.Interface.EnableInternalItemTransfers = 'false' }
            'null-interface' { $invalid.Interface = $null }
        }
        $invalid | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filePath -Encoding utf8
        $before = [System.IO.File]::ReadAllText($filePath)
        $failed = $false
        try { $null = $store.LoadOrCreate() } catch { $failed = $true }
        Assert-True ($failed -and [System.IO.File]::ReadAllText($filePath) -ceq $before) "Invalid configuration ($case) was accepted or overwritten."
        $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filePath -Encoding utf8
    }
    'Explorer configuration tests passed.'
} finally {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}