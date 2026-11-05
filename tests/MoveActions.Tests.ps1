. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$workflow = $assembly.GetType('SUTWinExplorer.MoveWorkflowState', $true).GetProperty('Shared').GetValue($null)
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-move-actions-' + [guid]::NewGuid().ToString('N'))
try {
    $source = Join-Path $directory 'source'
    $destination = Join-Path $directory 'destination'
    [void] [IO.Directory]::CreateDirectory($source)
    [void] [IO.Directory]::CreateDirectory($destination)
    $first = Join-Path $source 'first.txt'
    $second = Join-Path $source 'second.txt'
    [IO.File]::WriteAllText($first, 'first')
    [IO.File]::WriteAllText($second, 'second')
    $failed = $false
    try { $workflow.Prepare([string[]] @()) } catch { $failed = $true }
    Assert-True ($failed -and -not $workflow.IsPrepared) 'Move accepted an empty selection.'
    $workflow.Prepare([string[]] @($first, $first.ToUpperInvariant(), $second))
    $prepared = @($workflow.PreparedPaths)
    Assert-True ($workflow.IsPrepared -and $prepared.Count -eq 2 -and $first -in $prepared -and $second -in $prepared) 'Move did not retain the distinct selected paths.'
    $failed = $false
    try { $workflow.Prepare([string[]] @($second)) } catch { $failed = $true }
    Assert-True ($failed -and @($workflow.PreparedPaths).Count -eq 2) 'Preparing Move again changed the active workflow.'
    $workflow.Abort()
    Assert-True (-not $workflow.IsPrepared) 'Move abort did not clear the workflow.'
    $workflow.Prepare([string[]] @($first))
    $inserted = [Collections.Generic.List[string]]::new()
    $null = $shell.GetMethod('Move', $flags).Invoke($null, [object[]] @([string[]] @($workflow.PreparedPaths), [string] $destination, [IntPtr]::Zero, $inserted))
    $workflow.CompleteExecute()
    Assert-True ($inserted.Count -eq 1 -and $inserted[0] -eq (Join-Path $destination 'first.txt') -and
        -not [IO.File]::Exists($first) -and [IO.File]::Exists($inserted[0]) -and -not $workflow.IsPrepared) 'Move did not return the destination, move the file and clear the workflow.'
    $folder = Join-Path $source 'folder'
    [void] [IO.Directory]::CreateDirectory($folder)
    [IO.File]::WriteAllText((Join-Path $folder 'nested.txt'), 'nested')
    $inserted.Clear()
    $directoryChanges = [Collections.Generic.List[System.ValueTuple[string,string]]]::new()
    $null = $shell.GetMethod('MoveWithDirectoryChanges', $flags).Invoke($null, [object[]] @([string[]] @($folder), [string] $destination, [IntPtr]::Zero, $inserted, $directoryChanges))
    $movedFolder = Join-Path $destination 'folder'
    Assert-True ($inserted.Count -eq 1 -and $inserted[0] -ceq $movedFolder -and $directoryChanges.Count -eq 1 -and
        $directoryChanges[0].Item1 -ceq $folder -and $directoryChanges[0].Item2 -ceq $movedFolder -and
        -not [IO.Directory]::Exists($folder) -and [IO.File]::Exists((Join-Path $movedFolder 'nested.txt'))) 'Move did not preserve the directory contents or report its path change.'
    'Move action tests passed.'
} finally {
    $workflow.Abort()
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
}