$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
$flags = [System.Reflection.BindingFlags]'Static,NonPublic'
$newFixture = Join-Path ([IO.Path]::GetTempPath()) ('kis-new-item-test-' + [guid]::NewGuid().ToString('N'))
$suffix = [guid]::NewGuid().ToString('N')
$extensions = @(".kis${suffix}empty", ".kis${suffix}data", ".kis${suffix}template", ".kis${suffix}command", ".kis${suffix}missing")
$registryPaths = @($extensions | ForEach-Object { "Software\Classes\$_" })

try {
    [IO.Directory]::CreateDirectory($newFixture) | Out-Null
    $templatePath = Join-Path $newFixture 'template.bin'
    [IO.File]::WriteAllBytes($templatePath, [byte[]] @(4, 5, 6))
    for ($index = 0; $index -lt $registryPaths.Count; $index++) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPaths[$index] + '\ShellNew')
        try {
            switch ($index) {
                0 { $key.SetValue('NullFile', '') }
                1 { $key.SetValue('Data', [byte[]] @(1, 2, 3), [Microsoft.Win32.RegistryValueKind]::Binary) }
                2 { $key.SetValue('FileName', $templatePath) }
                3 { $key.SetValue('Command', 'not-executed'); $key.SetValue('NullFile', '') }
                4 { $key.SetValue('FileName', (Join-Path $newFixture 'missing-template')) }
            }
        } finally { $key.Dispose() }
    }
    $newOperations = $assembly.GetType('SUTWinExplorer.NewItemOperations', $true)
    $newTypes = @($newOperations.GetMethod('GetTypes', $flags).Invoke($null, @()))
    Assert-True ($newTypes[0].Kind.ToString() -eq 'Directory' -and $newTypes[1].Extension -eq '.txt') 'Folder and text-file types were not first.'
    $createNew = $newOperations.GetMethod('Create', $flags)
    for ($index = 0; $index -lt 3; $index++) {
        $type = @($newTypes | Where-Object { $_.Extension -eq $extensions[$index] })
        Assert-True ($type.Count -eq 1) "Direct ShellNew type was not discovered: $($extensions[$index])."
        $created = $createNew.Invoke($null, [object[]] @([string] $newFixture, [string] ("created" + $extensions[$index]), $type[0].PSObject.BaseObject))
        $bytes = [IO.File]::ReadAllBytes($created)
        $expected = switch ($index) { 0 { '' } 1 { '1,2,3' } 2 { '4,5,6' } }
        Assert-True (($bytes -join ',') -ceq $expected) "The ShellNew contents were wrong for $($extensions[$index])."
        $failed = $false
        try { $null = $createNew.Invoke($null, [object[]] @([string] $newFixture, [string] ("created" + $extensions[$index]), $type[0].PSObject.BaseObject)) } catch { $failed = $true }
        Assert-True ($failed -and (([IO.File]::ReadAllBytes($created) -join ',') -ceq $expected)) 'A name conflict overwrote an existing file.'
    }
    Assert-True (@($newTypes | Where-Object { $_.Extension -in $extensions[3..4] }).Count -eq 0) 'A command or missing template was offered as a direct type.'
    $folderType = @($newTypes | Where-Object { $_.Kind.ToString() -eq 'Directory' })[0]
    foreach ($badName in @('', '..', 'invalid/name', 'CON.txt', 'trailing.', 'trailing ')) {
        $failed = $false
        try { $null = $createNew.Invoke($null, [object[]] @([string] $newFixture, [string] $badName, $folderType.PSObject.BaseObject)) } catch { $failed = $true }
        Assert-True $failed "An invalid Windows name was accepted: $badName"
    }
    $null = $createNew.Invoke($null, [object[]] @([string] $newFixture, [string] 'folder', $folderType.PSObject.BaseObject))
    $failed = $false
    try { $null = $createNew.Invoke($null, [object[]] @([string] $newFixture, [string] 'folder', $folderType.PSObject.BaseObject)) } catch { $failed = $true }
    Assert-True $failed 'A folder name conflict was accepted.'
    'New item operation tests passed.'
} finally {
    foreach ($registryPath in $registryPaths) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false) }
    if ([IO.Directory]::Exists($newFixture)) { [IO.Directory]::Delete($newFixture, $true) }
}