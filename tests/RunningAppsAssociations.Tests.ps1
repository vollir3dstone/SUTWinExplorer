$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RecommendedAssociationProbe
{
    [ComImport, Guid("973810ae-9599-4b88-9e4d-6ee98c9552da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumAssocHandlers
    {
        [PreserveSig] int Next(uint count, [MarshalAs(UnmanagedType.Interface)] out IAssocHandler handler, out uint fetched);
    }
    [ComImport, Guid("f04061ac-1659-4a3f-a954-775aa57fc083"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAssocHandler
    {
        [PreserveSig] int GetName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int GetUIName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int GetIconLocation([MarshalAs(UnmanagedType.LPWStr)] out string path, out int index);
        [PreserveSig] int IsRecommended();
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHAssocEnumHandlers(string extension, uint filter, out IEnumAssocHandlers handlers);

    public static string[] GetRecommendedIds(string extension)
    {
        Marshal.ThrowExceptionForHR(SHAssocEnumHandlers(extension, 0, out var enumerator));
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            while (true)
            {
                Marshal.ThrowExceptionForHR(enumerator.Next(1, out var handler, out uint fetched));
                if (fetched == 0) break;
                try
                {
                    int recommended = handler.IsRecommended();
                    Marshal.ThrowExceptionForHR(recommended);
                    if (recommended == 0 && handler.GetName(out string name) >= 0 && !string.IsNullOrWhiteSpace(name))
                        ids.Add(name);
                }
                finally { Marshal.ReleaseComObject(handler); }
            }
        }
        finally { Marshal.ReleaseComObject(enumerator); }
        return new List<string>(ids).ToArray();
    }
}
'@
$assemblyPath = Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
$accessor = $assembly.GetType('SUTWinExplorer.RunningAppsAccessor', $true)
$allMethod = $accessor.GetMethod('GetRegisteredApps')
$recommendedMethod = $accessor.GetMethod('GetRecommendedApps')
$chooseMethod = $accessor.GetMethod('GetAppsToChooseFrom')
foreach ($extension in @('.wav', '.jpg', '.txt', '.kisunknown' + [guid]::NewGuid().ToString('N'))) {
    $all = @($allMethod.Invoke($null, @([string] $extension)))
    $recommended = @($recommendedMethod.Invoke($null, @([string] $extension)))
    $expectedIds = @([RecommendedAssociationProbe]::GetRecommendedIds($extension))
    $actualIds = @($recommended | ForEach-Object { $_.Id })
    if ($actualIds.Count -ne $expectedIds.Count -or @($actualIds | Where-Object { $_ -notin $expectedIds }).Count -ne 0) {
        throw "Recommended handlers do not match IAssocHandler.IsRecommended for $extension."
    }
    if (@($actualIds | Where-Object { $_ -notin $all.Id }).Count -ne 0) { throw "Recommended handlers are missing from the unfiltered list for $extension." }
    $chosen = @($chooseMethod.Invoke($null, @([string] $extension)))
    $chosenIds = @($chosen | ForEach-Object { $_.Id })
    if (@($chosen | Where-Object { [string]::IsNullOrWhiteSpace($_.Id) -or [string]::IsNullOrWhiteSpace($_.Name) }).Count -ne 0) { throw "A chosen handler has no ID or name for $extension." }
    if (@($chosenIds | Sort-Object -Unique).Count -ne $chosenIds.Count) { throw "Duplicate chosen handlers for $extension." }
    $pathResults = @($chooseMethod.Invoke($null, @([string] "C:\example\test$extension")))
    if ($pathResults.Count -ne $chosenIds.Count -or @($pathResults | Where-Object { $_.Id -notin $chosenIds }).Count -ne 0) { throw "Path and extension results differ for $extension." }
}
$empty = $chooseMethod.Invoke($null, @('C:\example\no-extension'))
if ($empty.Count -ne 0) { throw 'An extensionless path returned applications to choose from.' }
'Running app association tests passed.'