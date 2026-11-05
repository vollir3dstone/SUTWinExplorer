. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$workflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
$copy = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('Copy', [Reflection.BindingFlags]'Static,NonPublic')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-copy-actions-' + [guid]::NewGuid().ToString('N'))
try {
    $source = Join-Path $directory 'source'
    $destination = Join-Path $directory 'destination'
    $folder = Join-Path $source 'folder'
    [void] [IO.Directory]::CreateDirectory($folder)
    [void] [IO.Directory]::CreateDirectory($destination)
    $first = Join-Path $source 'first.txt'
    $second = Join-Path $source 'second.txt'
    [IO.File]::WriteAllText($first, 'first')
    [IO.File]::WriteAllText($second, 'second')
    [IO.File]::WriteAllText((Join-Path $folder 'nested.txt'), 'nested')
    $failed = $false
    try { $workflow.Prepare([string[]] @()) } catch { $failed = $true }
    Assert-True ($failed -and -not $workflow.IsPrepared) 'Copy accepted an empty selection.'
    $workflow.Prepare([string[]] @($first, $first.ToUpperInvariant(), $second))
    $prepared = @($workflow.PreparedPaths)
    Assert-True ($workflow.IsPrepared -and $prepared.Count -eq 2 -and $first -in $prepared -and $second -in $prepared) 'Copy did not retain the distinct selected paths.'
    $failed = $false
    try { $workflow.Prepare([string[]] @($second)) } catch { $failed = $true }
    Assert-True ($failed -and @($workflow.PreparedPaths).Count -eq 2) 'Preparing Copy again changed the active workflow.'
    $workflow.Abort()
    Assert-True (-not $workflow.IsPrepared) 'Copy abort did not clear the workflow.'
    $workflow.Prepare([string[]] @($first, $second))
    $inserted = [Collections.Generic.List[string]]::new()
    $null = $copy.Invoke($null, [object[]] @([string[]] @($workflow.PreparedPaths), [string] $destination, [IntPtr]::Zero, $inserted))
    $workflow.CompleteExecute()
    Assert-True ($inserted.Count -eq 2 -and (Join-Path $destination 'first.txt') -in $inserted -and
        (Join-Path $destination 'second.txt') -in $inserted -and [IO.File]::Exists($first) -and [IO.File]::Exists($second) -and
        -not $workflow.IsPrepared) 'Copy did not return both destinations, retain its sources and clear the workflow.'
    $inserted.Clear()
    $null = $copy.Invoke($null, [object[]] @([string[]] @($folder), [string] $destination, [IntPtr]::Zero, $inserted))
    Assert-True ($inserted.Count -eq 1 -and $inserted[0] -eq (Join-Path $destination 'folder') -and
        [IO.File]::Exists((Join-Path $folder 'nested.txt')) -and [IO.File]::Exists((Join-Path $inserted[0] 'nested.txt'))) 'Copy returned an incorrect directory destination or lost its contents.'
    'Copy action tests passed.'
} finally {
    $workflow.Abort()
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
}