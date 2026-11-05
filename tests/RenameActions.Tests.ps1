. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$rename = $shell.GetMethod('Rename', [Reflection.BindingFlags]'Static,NonPublic')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-rename-action-' + [guid]::NewGuid().ToString('N'))
try {
    [void] [IO.Directory]::CreateDirectory((Join-Path $directory 'folder'))
    $file = Join-Path $directory 'notes.txt'
    [IO.File]::WriteAllText($file, 'content')
    [IO.File]::WriteAllText((Join-Path $directory 'existing.txt'), 'existing')
    foreach ($invalidName in @('', '..', 'invalid/name', 'existing.txt')) {
        $failed = $false
        try { $null = $rename.Invoke($null, [object[]] @([string] $file, [string] $invalidName, [IntPtr]::Zero)) }
        catch {
            $expected = if ($invalidName -eq 'existing.txt') { [IO.IOException] } else { [ArgumentException] }
            $failed = $expected.IsInstanceOfType($_.Exception.InnerException)
        }
        Assert-True ($failed -and [IO.File]::ReadAllText($file) -ceq 'content') "Invalid or conflicting rename was accepted: $invalidName"
    }
    $renamedFile = $rename.Invoke($null, [object[]] @([string] $file, [string] 'renamed.txt', [IntPtr]::Zero))
    Assert-True ($renamedFile -ceq (Join-Path $directory 'renamed.txt') -and -not [IO.File]::Exists($file) -and
        [IO.File]::ReadAllText($renamedFile) -ceq 'content') 'File rename did not preserve the content and return the new path.'
    $caseFile = $rename.Invoke($null, [object[]] @([string] $renamedFile, [string] 'RENAMED.txt', [IntPtr]::Zero))
    $names = @([IO.Directory]::EnumerateFileSystemEntries($directory) | ForEach-Object { [IO.Path]::GetFileName($_) })
    Assert-True ($caseFile -ceq (Join-Path $directory 'RENAMED.txt') -and $names -ccontains 'RENAMED.txt') 'Case-only rename did not preserve the requested name.'
    $folder = Join-Path $directory 'folder'
    [IO.File]::WriteAllText((Join-Path $folder 'child.txt'), 'child')
    $renamedFolder = $rename.Invoke($null, [object[]] @([string] $folder, [string] 'renamed-folder', [IntPtr]::Zero))
    Assert-True ($renamedFolder -ceq (Join-Path $directory 'renamed-folder') -and -not [IO.Directory]::Exists($folder) -and
        [IO.File]::ReadAllText((Join-Path $renamedFolder 'child.txt')) -ceq 'child') 'Directory rename did not preserve its contents and return the new path.'
    'Rename action tests passed.'
} finally {
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
}