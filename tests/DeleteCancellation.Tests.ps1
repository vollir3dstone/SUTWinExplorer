param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class DeleteCancellationProbe : IDisposable
{
    private delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentProcessId();
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int maximum);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    private readonly uint process = GetCurrentProcessId();
    private readonly Timer timer;
    private int seen;
    public bool Seen => Volatile.Read(ref seen) != 0;

    public DeleteCancellationProbe() => timer = new Timer(Check, null, 50, 50);

    private void Check(object state)
    {
        EnumWindows((window, parameter) =>
        {
            GetWindowThreadProcessId(window, out var ownerProcess);
            if (ownerProcess != process) return true;
            var name = new StringBuilder(64);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "#32770") return true;
            if (GetDlgItem(window, 6) == IntPtr.Zero) return true;
            var button = GetDlgItem(window, 2);
            if (button != IntPtr.Zero && Interlocked.Exchange(ref seen, 1) == 0)
                PostMessage(button, 0x00F5, IntPtr.Zero, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
    }

    public void Dispose() => timer.Dispose();
}
'@

$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$delete = $shell.GetMethod('Delete', [Reflection.BindingFlags]'Static,NonPublic')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('SutDeleteCancel-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$path = Join-Path $directory 'cancel-test.txt'
[IO.File]::WriteAllText($path, 'test')
$probe = [DeleteCancellationProbe]::new()
try {
    $failure = $null
    try { $null = $delete.Invoke($null, [object[]] @([string[]] @($path), [IntPtr]::Zero)) }
    catch { $failure = $_.Exception.InnerException }
    if (-not $probe.Seen) { throw 'The delete confirmation dialog was not observed.' }
    if (-not [IO.File]::Exists($path)) { throw 'The file was deleted after declining confirmation.' }
    if ($failure -isnot [OperationCanceledException]) {
        throw "Expected an OperationCanceledException, got: $failure"
    }
    $failure = $null
    try { $null = $delete.Invoke($null, [object[]] @([string[]] @((Join-Path $directory 'missing.txt')), [IntPtr]::Zero)) }
    catch { $failure = $_.Exception.InnerException }
    if ($failure -isnot [InvalidOperationException]) {
        throw "Expected an error for a missing file, got: $failure"
    }
    Write-Host 'Delete cancellation test passed.'
} finally {
    $probe.Dispose()
    [IO.Directory]::Delete($directory, $true)
}