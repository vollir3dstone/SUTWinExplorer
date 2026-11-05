param(
    [string] $Directory = '',
    [int] $Passes = 7,
    [int] $MaxItems = 0,
    [switch] $CompareFlags
)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this benchmark with pwsh -STA.' }
if ($Passes -lt 1 -or $MaxItems -lt 0) { throw 'Passes must be positive and MaxItems must be nonnegative.' }
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class IconTimingNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShellFileInfo
    {
        public IntPtr Icon;
        public int IconIndex;
        public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }

    public sealed class Result
    {
        public double BaseMilliseconds;
        public double OverlayMilliseconds;
        public bool Success;
        public int OverlaySlot;
        public double PlainIconMilliseconds;
        public double OverlayIndexMilliseconds;
        public double CombinedMilliseconds;
        public bool FlagCallsSuccess;
        public bool OverlayIndexMatches;
        public bool CombinedMatches;
    }

    private static double MeasureFlags(string path, uint flags, out ShellFileInfo info, out bool success)
    {
        info = new ShellFileInfo();
        long start = Stopwatch.GetTimestamp();
        IntPtr callResult = SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf<ShellFileInfo>(), flags);
        double milliseconds = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        success = callResult != IntPtr.Zero;
        if (info.Icon != IntPtr.Zero) DestroyIcon(info.Icon);
        return milliseconds;
    }

    public static Result Measure(string path, bool compareFlags, int order)
    {
        var result = new Result();
        ShellFileInfo baseInfo, overlayInfo;
        bool baseSuccess, overlaySuccess;
        result.BaseMilliseconds = MeasureFlags(path, 0x4001, out baseInfo, out baseSuccess);
        result.OverlayMilliseconds = MeasureFlags(path, 0x0161, out overlayInfo, out overlaySuccess);
        result.OverlaySlot = (int)(unchecked((uint)overlayInfo.IconIndex) >> 24);
        result.Success = baseSuccess && overlaySuccess;
        if (compareFlags)
        {
            var flags = new uint[] { 0x0101, 0x0141, 0x4161 };
            var times = new double[3];
            var infos = new ShellFileInfo[3];
            var successes = new bool[3];
            for (int offset = 0; offset < flags.Length; offset++)
            {
                int index = (order + offset) % flags.Length;
                times[index] = MeasureFlags(path, flags[index], out infos[index], out successes[index]);
            }
            result.PlainIconMilliseconds = times[0];
            result.OverlayIndexMilliseconds = times[1];
            result.CombinedMilliseconds = times[2];
            result.FlagCallsSuccess = successes[0] && successes[1] && successes[2];
            result.OverlayIndexMatches = (unchecked((uint)infos[1].IconIndex) >> 24) == (uint)result.OverlaySlot;
            result.CombinedMatches = (unchecked((uint)infos[2].IconIndex) >> 24) == (uint)result.OverlaySlot &&
                (unchecked((uint)infos[2].IconIndex) & 0x00ffffff) == unchecked((uint)baseInfo.IconIndex);
        }
        return result;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint attributes, ref ShellFileInfo info, uint size, uint flags);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
}
'@

function Get-Percentile([double[]] $values, [double] $fraction) {
    $sorted = @($values | Sort-Object)
    if ($sorted.Count -eq 0) { return [double]::NaN }
    $index = [Math]::Max(0, [int][Math]::Ceiling($fraction * $sorted.Count) - 1)
    return [double] $sorted[$index]
}

function Write-Stats([string] $name, [double[]] $values) {
    if ($values.Count -eq 0) { Write-Output "$name`: no successful samples"; return }
    $sum = ($values | Measure-Object -Sum).Sum
    Write-Output ('{0,-29} n={1,5} mean={2,9:F3} median={3,8:F3} p90={4,8:F3} p95={5,8:F3} p99={6,8:F3} max={7,9:F3} sum={8,10:F1} ms' -f `
        $name, $values.Count, ($sum / $values.Count), (Get-Percentile $values 0.5), (Get-Percentile $values 0.9), `
        (Get-Percentile $values 0.95), (Get-Percentile $values 0.99), (($values | Measure-Object -Maximum).Maximum), $sum)
}

if (-not $Directory) { $Directory = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path }
$paths = [string[]] @([IO.Directory]::EnumerateFileSystemEntries($Directory) | Sort-Object)
if ($MaxItems -gt 0 -and $paths.Length -gt $MaxItems) { $paths = [string[]] $paths[0..($MaxItems - 1)] }
if ($paths.Length -eq 0) { throw 'The benchmark directory has no entries.' }
$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
$staticFlags = [Reflection.BindingFlags]'Static,NonPublic'
$instanceFlags = [Reflection.BindingFlags]'Instance,NonPublic'
$provider = $assembly.GetType('SUTWinExplorer.ShellIconProvider', $true)
$cacheType = $assembly.GetType('SUTWinExplorer.IconCache', $true)
$iconsType = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true)
$overlayKnownProperty = $iconsType.GetProperty('OverlayKnown', $instanceFlags)
$overlaySlotProperty = $iconsType.GetProperty('OverlaySlot', $instanceFlags)
$baseIndexProperty = $iconsType.GetProperty('BaseIconIndex', $instanceFlags)
$initialize = $provider.GetMethod('InitializeCache', $staticFlags)
$uncached = $provider.GetMethod('GetSmallIconsUncached', $staticFlags)
$getSmall = $provider.GetMethod('GetSmallIcons')
$store = $cacheType.GetMethod('Store', $instanceFlags)
$prepare = $cacheType.GetMethod('PrepareImage', $staticFlags)
$cachePath = Join-Path ([IO.Path]::GetTempPath()) ('kis-icon-benchmark-' + [guid]::NewGuid().ToString('N') + '.json')
$samples = [Collections.Generic.List[object]]::new()
$passResults = [Collections.Generic.List[object]]::new()
$random = [Random]::new(20261105)
$failures = 0
$nativeFailures = 0
$overlayCount = 0
$sampleIndex = 0

Write-Output "Directory entries: $($paths.Length); passes: $Passes; OS: $([Environment]::OSVersion.VersionString)"
Write-Output 'First pass is not guaranteed cold; later passes and separately timed native calls use warmed Windows caches.'
Write-Output 'Real cache is not modified; each pass uses a fresh in-memory application cache and does not save it.'
Write-Output 'Native base/overlay timings are separate repeated calls after the production lookup, not additive to its time.'

for ($pass = 1; $pass -le $Passes; $pass++) {
    $initialize.Invoke($null, [object[]] @([string] $cachePath))
    $cache = $provider.GetField('_cache', $staticFlags).GetValue($null)
    $order = [string[]] $paths.Clone()
    for ($index = $order.Length - 1; $index -gt 0; $index--) {
        $other = $random.Next($index + 1)
        $swap = $order[$index]; $order[$index] = $order[$other]; $order[$other] = $swap
    }
    $passUncached = 0.0
    $passStore = 0.0
    $passSuccess = 0
    foreach ($path in $order) {
        $start = [Diagnostics.Stopwatch]::GetTimestamp()
        $icons = $uncached.Invoke($null, [object[]] @([string] $path))
        $uncachedMs = [Diagnostics.Stopwatch]::GetElapsedTime($start).TotalMilliseconds
        if ($null -eq $icons -or $null -eq $icons.BaseIcon -or -not $overlayKnownProperty.GetValue($icons)) { $failures++; continue }
        $hasOverlay = $overlaySlotProperty.GetValue($icons) -gt 0
        if ($hasOverlay) { $overlayCount++ }
        $start = [Diagnostics.Stopwatch]::GetTimestamp()
        $store.Invoke($cache, [object[]] @([string] $path, [string] 'small', [int] 16, [int] 16, $icons.BaseIcon, [bool] $hasOverlay, [int] $baseIndexProperty.GetValue($icons)))
        $storeMs = [Diagnostics.Stopwatch]::GetElapsedTime($start).TotalMilliseconds
        $start = [Diagnostics.Stopwatch]::GetTimestamp()
        [void] $prepare.Invoke($null, [object[]] @($icons.BaseIcon, [bool] $hasOverlay))
        $prepareMs = [Diagnostics.Stopwatch]::GetElapsedTime($start).TotalMilliseconds
        $start = [Diagnostics.Stopwatch]::GetTimestamp()
        $hit = $getSmall.Invoke($null, [object[]] @([string] $path))
        $hitMs = [Diagnostics.Stopwatch]::GetElapsedTime($start).TotalMilliseconds
        if ($null -eq $hit) { throw 'A cache hit returned no icon.' }
        $native = [IconTimingNative]::Measure($path, [bool] $CompareFlags, ($sampleIndex % 3))
        $sampleIndex++
        if (-not $native.Success) { $nativeFailures++ }
        $passUncached += $uncachedMs
        $passStore += $storeMs
        $passSuccess++
        $samples.Add([pscustomobject] @{ Pass = $pass; Uncached = $uncachedMs; Store = $storeMs; Prepare = $prepareMs; Hit = $hitMs;
            NativeBase = $native.BaseMilliseconds; NativeOverlay = $native.OverlayMilliseconds; NativeSuccess = $native.Success; Overlay = $hasOverlay;
            PlainIcon = $native.PlainIconMilliseconds; OverlayIndex = $native.OverlayIndexMilliseconds; Combined = $native.CombinedMilliseconds;
            FlagCallsSuccess = $native.FlagCallsSuccess; OverlayIndexMatches = $native.OverlayIndexMatches; CombinedMatches = $native.CombinedMatches })
    }
    $passResults.Add([pscustomobject] @{ Pass = $pass; Count = $passSuccess; Uncached = $passUncached; Store = $passStore })
    Write-Output ('Pass {0}: successful={1}; production uncached={2:F1} ms; cache store={3:F1} ms; combined/item={4:F3} ms' -f `
        $pass, $passSuccess, $passUncached, $passStore, $(if ($passSuccess) { ($passUncached + $passStore) / $passSuccess } else { 0 }))
}

Write-Output "Failures: production=$failures; native=$nativeFailures; overlay samples=$overlayCount"
Write-Output 'Pooled sample statistics (milliseconds/item; repeated observations are not independent):'
Write-Stats 'Production uncached total' ([double[]] @($samples | ForEach-Object Uncached))
Write-Stats 'Application cache Store' ([double[]] @($samples | ForEach-Object Store))
Write-Stats '  PNG/hash preparation only' ([double[]] @($samples | ForEach-Object Prepare))
Write-Stats 'Application cache hit' ([double[]] @($samples | ForEach-Object Hit))
$successfulNative = @($samples | Where-Object NativeSuccess)
Write-Stats '  SHGetFileInfo base index' ([double[]] @($successfulNative | ForEach-Object NativeBase))
Write-Stats '  SHGetFileInfo overlay' ([double[]] @($successfulNative | ForEach-Object NativeOverlay))
if ($CompareFlags) {
    $flagSamples = @($successfulNative | Where-Object FlagCallsSuccess)
    Write-Output "Flag comparison: successful=$($flagSamples.Count); failed=$($samples.Count - $flagSamples.Count); overlay-index mismatches=$(@($flagSamples | Where-Object { -not $_.OverlayIndexMatches }).Count); combined-index mismatches=$(@($flagSamples | Where-Object { -not $_.CombinedMatches }).Count)"
    Write-Stats '  SHGetFileInfo plain icon' ([double[]] @($flagSamples | ForEach-Object PlainIcon))
    Write-Stats '  Overlay index no ADDOVERLAYS' ([double[]] @($flagSamples | ForEach-Object OverlayIndex))
    Write-Stats '  Combined base and overlay' ([double[]] @($flagSamples | ForEach-Object Combined))
}
Write-Stats 'Paired uncached + Store' ([double[]] @($samples | ForEach-Object { $_.Uncached + $_.Store }))
if ($Passes -gt 1) {
    $passMeans = [double[]] @($passResults | Where-Object { $_.Count -gt 0 } | ForEach-Object { ($_.Uncached + $_.Store) / $_.Count })
    Write-Stats 'Per-pass combined means' $passMeans
}