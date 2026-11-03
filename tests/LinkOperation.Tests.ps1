$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { throw 'Run this test in an STA process.' }
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
$operations = $assembly.GetType('SUTWinExplorer.ShellFileOperations', $true)
$link = $operations.GetMethod('Link', [Reflection.BindingFlags]'Static,Public')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('SutLinkTest-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $directory 'source'
$destination = Join-Path $directory 'destination'
[IO.Directory]::CreateDirectory($source) | Out-Null
[IO.Directory]::CreateDirectory($destination) | Out-Null
try {
    $file = Join-Path $source 'example.txt'
    $folder = Join-Path $source 'folder'
    [IO.File]::WriteAllText($file, 'original')
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $existing = Join-Path $destination 'example.txt - Shortcut.lnk'
    [IO.File]::WriteAllText($existing, 'keep')
    $inserted = [Collections.Generic.List[string]]::new()
    $arguments = [object[]]::new(3)
    $arguments[0] = [string[]] @($file, $folder)
    $arguments[1] = [string] $destination
    $arguments[2] = $inserted
    $null = $link.Invoke($null, $arguments)
    if ($inserted.Count -ne 2 -or [IO.File]::ReadAllText($existing) -cne 'keep') { throw 'Link creation did not preserve the existing item.' }
    if ($inserted[0] -cne (Join-Path $destination 'example.txt - Shortcut (2).lnk') -or
        @(Get-ChildItem -LiteralPath $destination -Filter '*.tmp').Count -ne 0) { throw 'Link creation chose an incorrect name or left a temporary file.' }
    $shell = New-Object -ComObject WScript.Shell
    try {
        for ($index = 0; $index -lt $inserted.Count; $index++) {
            $shortcut = $shell.CreateShortcut($inserted[$index])
            try {
                if ($shortcut.TargetPath -cne @($file, $folder)[$index]) { throw "Incorrect shortcut target: $($shortcut.TargetPath)." }
            } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        }
    } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    $getFolderTarget = $operations.GetMethod('GetFolderTarget', [Reflection.BindingFlags]'Static,Public')
    if ($getFolderTarget.Invoke($null, [object[]] @($inserted[1])) -cne $folder) { throw 'The folder shortcut did not resolve to its folder.' }
    $getLinkTarget = $operations.GetMethod('GetLinkTarget', [Reflection.BindingFlags]'Static,Public')
    if ($getLinkTarget.Invoke($null, [object[]] @($inserted[0])) -cne $file -or
        $getLinkTarget.Invoke($null, [object[]] @($inserted[1])) -cne $folder -or
        $null -ne $getLinkTarget.Invoke($null, [object[]] @([string] $file))) { throw 'Shortcut target resolution returned an incorrect target.' }
    [IO.File]::Delete($file)
    if ($null -ne $getLinkTarget.Invoke($null, [object[]] @($inserted[0]))) { throw 'A broken shortcut returned an available target.' }
    [IO.File]::WriteAllText($file, 'original')
    $before = @(Get-ChildItem -LiteralPath $destination).Count
    $rejected = $false
    try {
        $arguments[0] = [string[]] @($file, (Join-Path $source 'missing'))
        $arguments[2] = [Collections.Generic.List[string]]::new()
        $null = $link.Invoke($null, $arguments)
    } catch {
        if ($_.Exception.ToString() -notmatch 'Cannot link because this source') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Missing source was accepted.' }
    if (@(Get-ChildItem -LiteralPath $destination).Count -ne $before) { throw 'Preflight failure created a shortcut.' }
    $partialDestination = Join-Path $directory 'partial'
    [IO.Directory]::CreateDirectory($partialDestination) | Out-Null
    $longFile = Join-Path $source ('x' * 245)
    [IO.File]::WriteAllText($longFile, 'long name')
    $partial = [Collections.Generic.List[string]]::new()
    $arguments[0] = [string[]] @($file, $longFile)
    $arguments[1] = [string] $partialDestination
    $arguments[2] = $partial
    $failed = $false
    try { $null = $link.Invoke($null, $arguments) } catch { $failed = $true }
    if (-not $failed -or $partial.Count -ne 1 -or -not [IO.File]::Exists($partial[0]) -or
        @(Get-ChildItem -LiteralPath $partialDestination -Filter '*.tmp').Count -ne 0) {
        throw "A later link failure did not preserve completed shortcuts and clean up temporary files: failed=$failed, count=$($partial.Count), files=$(@(Get-ChildItem -LiteralPath $partialDestination | ForEach-Object Name) -join ',')."
    }
    'Link operation tests passed.'
} finally { Remove-Item -LiteralPath $directory -Recurse -Force }