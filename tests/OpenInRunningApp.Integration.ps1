param(
    [ValidateSet('Audacity', 'IrfanView', 'Word', 'VLC', 'AcrobatReader', 'LibreOffice', 'Excel', 'Calc', 'PowerPoint', 'Impress', 'Draw', 'Math', 'Access', 'Base', 'Resonic', 'WindowsMediaPlayerLegacy')]
    [string] $Application = 'Audacity',
    [ValidateSet('Paste', 'Drop', 'Resourceful', 'Menu', 'OpenDialog', 'OpenDialogO', 'OpenDialogCtrlF12', 'ShellOpen')]
    [string] $Transfer = 'Paste',
    [switch] $UseExisting,
    [switch] $NonDefault,
    [switch] $StartWithImage
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PasteWindowProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X, Y; }
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr window, ref Point point);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")]
    public static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint thread, uint other, bool attach);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    public static extern int AssocQueryString(uint flags, uint kind, string association, string extra, System.Text.StringBuilder output, ref uint length);
    public static bool ActivateTestWindow(IntPtr window)
    {
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        uint current = GetCurrentThreadId();
        bool attached = foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
        try { BringWindowToTop(window); return SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
    }
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class AudioDeviceEnumerator { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITestAudioDeviceEnumerator
{
    void EnumAudioEndpoints();
    void GetDefaultAudioEndpoint(int flow, int role, out ITestAudioDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITestAudioDevice
{
    void Activate(ref Guid iid, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object result);
}

[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITestAudioSessionManager
{
    void GetAudioSessionControl();
    void GetSimpleAudioVolume();
    void GetSessionEnumerator(out ITestAudioSessionEnumerator sessions);
}

[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITestAudioSessionEnumerator
{
    void GetCount(out int count);
    void GetSession(int index, out ITestAudioSessionControl session);
}

[ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITestAudioSessionControl
{
    void GetState(out int state);
}

[ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITestAudioSessionControl2
{
    void GetState(out int state);
    void GetDisplayName();
    void SetDisplayName();
    void GetIconPath();
    void SetIconPath();
    void GetGroupingParam();
    void SetGroupingParam();
    void RegisterAudioSessionNotification();
    void UnregisterAudioSessionNotification();
    void GetSessionIdentifier();
    void GetSessionInstanceIdentifier();
    void GetProcessId(out uint processId);
}

public static class PlaybackSessionProbe
{
    public static bool IsActive(uint processId)
    {
        var enumerator = (ITestAudioDeviceEnumerator)new AudioDeviceEnumerator();
        try
        {
            enumerator.GetDefaultAudioEndpoint(0, 1, out var device);
            try
            {
                Guid iid = typeof(ITestAudioSessionManager).GUID;
                device.Activate(ref iid, 23, IntPtr.Zero, out object managerObject);
                try
                {
                    var manager = (ITestAudioSessionManager)managerObject;
                    manager.GetSessionEnumerator(out var sessions);
                    try
                    {
                        sessions.GetCount(out int count);
                        for (int index = 0; index < count; index++)
                        {
                            sessions.GetSession(index, out var session);
                            try
                            {
                                var extended = (ITestAudioSessionControl2)session;
                                extended.GetProcessId(out uint sessionProcessId);
                                session.GetState(out int state);
                                if (sessionProcessId == processId && state == 1) return true;
                            }
                            finally { Marshal.ReleaseComObject(session); }
                        }
                        return false;
                    }
                    finally { Marshal.ReleaseComObject(sessions); }
                }
                finally { Marshal.ReleaseComObject(managerObject); }
            }
            finally { Marshal.ReleaseComObject(device); }
        }
        finally { Marshal.ReleaseComObject(enumerator); }
    }
}
'@

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Wait-Until([scriptblock] $condition, [string] $message, [int] $seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        if (& $condition) { return }
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(250)
        $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $message
}

function Get-WindowNames([IntPtr] $handle) {
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        if ($null -eq $root) { return @() }
        $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
    } catch [System.Windows.Automation.ElementNotAvailableException] { return @() }
    foreach ($element in $elements) {
        try { $element.Current.Name } catch [System.Windows.Automation.ElementNotAvailableException] { }
    }
}

function Get-IrfanRedPixelCount([IntPtr] $handle) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'IrfanViewerClass')
    $viewer = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    Assert-True ($null -ne $viewer) 'The IrfanView image area was not found.'
    $bounds = $viewer.Current.BoundingRectangle
    $bitmap = [System.Drawing.Bitmap]::new([int] $bounds.Width, [int] $bounds.Height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen([int] $bounds.X, [int] $bounds.Y, 0, 0, $bitmap.Size) } finally { $graphics.Dispose() }
        $count = 0
        for ($y = 0; $y -lt $bitmap.Height; $y += 4) {
            for ($x = 0; $x -lt $bitmap.Width; $x += 4) {
                $pixel = $bitmap.GetPixel($x, $y)
                if ($pixel.R -gt 160 -and $pixel.G -lt 85 -and $pixel.B -lt 100) { $count++ }
            }
        }
        return $count
    } finally { $bitmap.Dispose() }
}

function Find-ShellDocument([string] $name, [string[]] $names) {
    $processIds = @(Get-Process -Name $names -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($root in $roots) {
        try {
            if ($root.Current.ProcessId -in $processIds -and $root.Current.NativeWindowHandle -ne 0 -and
                @(Get-WindowNames ([IntPtr] $root.Current.NativeWindowHandle) | Where-Object { $_ -like "*$name*" }).Count -gt 0) {
                return $true
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] { }
    }
    return $false
}

function Find-ProcessDocument([string] $name, [int] $processId, [string] $applicationName) {
    $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($root in $roots) {
        try {
            if ($root.Current.ProcessId -eq $processId -and $root.Current.NativeWindowHandle -ne 0 -and
                $root.Current.IsEnabled -and $root.Current.Name -like "*$name*$applicationName*") { return $true }
        } catch [System.Windows.Automation.ElementNotAvailableException] { }
    }
    return $false
}

function Convert-WithLibreOffice([string] $sourcePath, [string] $format, [string] $directory, [string] $outputPath) {
    $profile = Join-Path $directory ('LibreOffice-profile-' + [guid]::NewGuid().ToString('N'))
    $converter = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:ProgramFiles 'LibreOffice\program\soffice.exe'))
    $converter.UseShellExecute = $false
    $converter.RedirectStandardOutput = $true
    $converter.RedirectStandardError = $true
    foreach ($argument in @('--headless', "-env:UserInstallation=$([Uri]::new($profile).AbsoluteUri)", '--convert-to', $format, '--outdir', $directory, $sourcePath)) { $converter.ArgumentList.Add($argument) }
    $conversion = [Diagnostics.Process]::Start($converter)
    try {
        $output = $conversion.StandardOutput.ReadToEnd()
        $conversionError = $conversion.StandardError.ReadToEnd()
        $conversion.WaitForExit()
        Assert-True ($conversion.ExitCode -eq 0 -and [IO.File]::Exists($outputPath)) "Could not generate the $format fixture: $output $conversionError"
    } finally { $conversion.Dispose() }
}

function Close-TestSavePrompt([int] $processId, [string] $testName) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $processCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $processId)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $processCondition)
    $windowCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    foreach ($window in $windows) {
        if ($window.Current.Name -ne $testName) { continue }
        foreach ($dialog in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $windowCondition)) {
            try {
                if ($dialog.Current.Name -notlike "*$testName*") { continue }
                $noCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'CommandButton_7')
                $yesCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'CommandButton_6')
                $textCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'ContentText')
                $no = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $noCondition)
                $yes = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $yesCondition)
                $text = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $textCondition)
                if ($null -ne $no -and $null -ne $yes -and $null -ne $text -and $text.Current.Name -match '(?i)projekt.*speichern|save.*project') {
                    if ($no.Current.ClassName -eq 'CCPushButton' -and $no.Current.IsEnabled -and $no.Current.NativeWindowHandle -ne 0 -and
                        [PasteWindowProbe]::PostMessage([IntPtr] $no.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)) {
                        return $true
                    }
                }
            } catch [System.Windows.Automation.ElementNotAvailableException] { }
        }
    }
    return $false
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
$accessor = $assembly.GetType('SUTWinExplorer.RunningAppsAccessor', $true)
if ($Transfer -eq 'Menu') {
    [System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
    $wpfApplication = [System.Windows.Application]::new()
    $wpfApplication.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $resources = [System.Windows.Application]::LoadComponent([Uri]::new('/SUTWinExplorer;component/Styles/InputControlStyles.xaml', [UriKind]::Relative))
    $wpfApplication.Resources.MergedDictionaries.Add($resources)
    $buttonStyle = [System.Windows.Style]::new([System.Windows.Controls.Button], $resources[[System.Windows.Controls.Button]])
    $buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::HeightProperty, [double] 24))
    $buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::MinHeightProperty, [double] 24))
    $buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::VerticalAlignmentProperty, [System.Windows.VerticalAlignment]::Center))
    $buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::FocusVisualStyleProperty, $null))
    $wpfApplication.Resources['ContentPaneButtonStyle'] = $buttonStyle
    foreach ($key in @('ItemHoverBrush', 'ItemSelectionBrush', 'ItemSelectionBorderBrush', 'ItemRequestBrush')) {
        $wpfApplication.Resources[$key] = [System.Windows.Media.Brushes]::LightGray
    }
    $wpfApplication.Resources['ViewFrameBrush'] = [System.Windows.Media.Brushes]::LightGray
    $wpfApplication.Resources['ViewFrameThickness'] = [System.Windows.Thickness]::new(1)
    $wpfApplication.Resources['ShellIconTemplate'] = [System.Windows.DataTemplate]::new()
    $parseErrors = $null
    $suiteAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1'), [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw $parseErrors[0] }
    $suiteHelpers = $suiteAst.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('public sealed class SutShellTestSignal') }, $true)
    Add-Type -TypeDefinition $suiteHelpers.Value
}
$extension, $executableNames, $processNames = switch ($Application) {
    'Audacity' { '.wav'; ,@('Audacity.exe'); ,@('audacity') }
    'IrfanView' { '.jpg'; ,@('i_view64.exe', 'i_view32.exe'); ,@('i_view64', 'i_view32') }
    'Word' { '.docx'; ,@('WINWORD.EXE'); ,@('WINWORD') }
    'VLC' { '.mp4'; ,@('vlc.exe'); ,@('vlc') }
    'AcrobatReader' { '.pdf'; ,@('AcroRd32.exe', 'Acrobat.exe'); ,@('AcroRd32', 'Acrobat') }
    'LibreOffice' { '.docx'; ,@('swriter.exe'); ,@('soffice', 'soffice.bin') }
    'Excel' { '.xlsx'; ,@('EXCEL.EXE'); ,@('EXCEL') }
    'Calc' { '.xlsx'; ,@('scalc.exe'); ,@('soffice', 'soffice.bin') }
    'PowerPoint' { '.pptx'; ,@('POWERPNT.EXE'); ,@('POWERPNT') }
    'Impress' { '.pptx'; ,@('simpress.exe'); ,@('soffice', 'soffice.bin') }
    'Draw' { '.odg'; ,@('soffice.exe'); ,@('soffice', 'soffice.bin') }
    'Math' { '.odf'; ,@('soffice.exe'); ,@('soffice', 'soffice.bin') }
    'Access' { '.accdb'; ,@('MSACCESS.EXE'); ,@('MSACCESS') }
    'Base' { '.odb'; ,@('sbase.exe'); ,@('soffice', 'soffice.bin') }
    'Resonic' { '.wav'; ,@('Resonic.exe'); ,@('Resonic') }
    'WindowsMediaPlayerLegacy' { '.wav'; ,@('wmplayer.exe'); ,@('wmplayer') }
}
if ($Application -in @('LibreOffice', 'Excel', 'Calc', 'PowerPoint', 'Impress', 'Draw', 'Math', 'Access', 'Base')) {
    Assert-True ($Transfer -eq 'Resourceful' -and -not $UseExisting) "$Application integration requires Resourceful and a test-started instance."
}
if ($Application -eq 'WindowsMediaPlayerLegacy') {
    Assert-True ($Transfer -eq 'Resourceful' -and -not $UseExisting) "$Application integration requires Resourceful and a test-started instance."
}
if ($StartWithImage) {
    Assert-True ($Application -eq 'IrfanView' -and -not $UseExisting -and $Transfer -in @('Resourceful', 'Drop', 'Menu')) 'StartWithImage requires a test-started IrfanView and Resourceful, Drop or Menu transfer.'
}
if ($NonDefault) {
    Assert-True ($Application -eq 'Word' -and $Transfer -eq 'ShellOpen') 'NonDefault is supported for the Word ShellOpen test.'
    $extension = '.html'
}
$registered = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @([string] "test$extension")) |
    Where-Object { [IO.Path]::GetFileName($_.Id) -in $executableNames -and [IO.File]::Exists($_.Id) })
Assert-True ($registered.Count -eq 1) "Expected exactly one registered $Application executable for $extension files."
$applicationPath = [string] $registered[0].Id
$selectedApp = $registered[0].PSObject.BaseObject
if ($Transfer -eq 'ShellOpen') {
    Assert-True (-not $UseExisting) 'ShellOpen integration requires a test-started application instance.'
    if ($NonDefault) {
        $length = [uint32] 0
        [void] [PasteWindowProbe]::AssocQueryString(0, 2, $extension, 'open', $null, [ref] $length)
        Assert-True ($length -gt 0) "The default $extension application could not be determined."
        $defaultExecutable = [Text.StringBuilder]::new([int] $length)
        Assert-True ([PasteWindowProbe]::AssocQueryString(0, 2, $extension, 'open', $defaultExecutable, [ref] $length) -eq 0 -and $defaultExecutable.ToString() -ine $applicationPath) 'Word is the default application; the non-default test requires a different default.'
        Write-Host "Default application: $defaultExecutable; selected application: $applicationPath"
    }
}

$existing = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
if ($UseExisting) {
    $existingWindows = @($existing | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    Assert-True ($existingWindows.Count -eq 1) "UseExisting requires exactly one running $Application main window."
    $process = $existingWindows[0]
} else {
    if ($existing.Count -gt 0) {
        throw "$Application is already running. Close it yourself or explicitly use -UseExisting."
    }
    $startupPath = if ($Application -in @('Draw', 'Math')) { Join-Path (Split-Path $applicationPath) $(if ($Application -eq 'Draw') { 'sdraw.exe' } else { 'smath.exe' }) } else { $applicationPath }
    if ($Application -eq 'Base') {
        $startupFile = Join-Path ([IO.Path]::GetTempPath()) ('KIS-Base-Startup-' + [guid]::NewGuid().ToString('N') + '.odb')
        [IO.File]::Copy((Join-Path $env:ProgramFiles 'LibreOffice\presets\database\biblio.odb'), $startupFile)
    }
    $process = if ($Application -eq 'Base') { Start-Process -FilePath $startupPath -ArgumentList "`"$startupFile`"" -PassThru }
        elseif ($Application -in @('LibreOffice', 'Calc', 'Impress', 'Draw', 'Math')) { Start-Process -FilePath $startupPath -PassThru }
        elseif ($Application -eq 'WindowsMediaPlayerLegacy') { Start-Process -FilePath $applicationPath -ArgumentList '/Task','NowPlaying' -PassThru }
        elseif ($StartWithImage) { Start-Process -FilePath $startupPath -ArgumentList "`"$(Join-Path $PSScriptRoot 'resources\image.jpg')`"" -PassThru }
        else { Start-Process -FilePath $applicationPath -PassThru }
}
$previousClipboard = $null
$clipboardChanged = $false
$trackName = $null
$testContentLoaded = $false
$temporaryMediaPath = $null
$menuOwner = $null
try {
    if ($Application -in @('AcrobatReader', 'LibreOffice', 'Calc', 'Impress', 'Draw', 'Math', 'Base') -and -not $UseExisting) {
        Wait-Until { @(Get-Process -Name $processNames -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }).Count -eq 1 } "$Application did not open exactly one main window." 30
        $windowProcess = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })[0]
        $process.Dispose()
        $process = $windowProcess
    } else {
        Wait-Until { $process.Refresh(); -not $process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero } "$Application did not open a window."
    }
    if ($Application -notin @('AcrobatReader', 'LibreOffice', 'Calc', 'Impress', 'Draw', 'Math', 'Base')) {
        Assert-True (@(Get-Process -Name $processNames -ErrorAction SilentlyContinue).Count -eq 1) "Expected exactly one $Application process."
    }
    Assert-True ([PasteWindowProbe]::IsWindowEnabled($process.MainWindowHandle)) "$Application has a blocking dialog. Resolve it before running the test."
    if ($StartWithImage) {
        Wait-Until { $process.Refresh(); $process.MainWindowTitle -like '*image.jpg*' } 'IrfanView did not load the initial test image.'
        Write-Host 'IrfanView started with the initial test image.'
    }
    $directory = Join-Path ([IO.Path]::GetTempPath()) 'KIS-File-Paste-Test'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $trackName = $(if ($Transfer -in @('OpenDialog', 'OpenDialogO', 'OpenDialogCtrlF12')) { 'KIS Öffnen ' } else { 'KIS-Paste-' }) + [guid]::NewGuid().ToString('N')
    $filePath = Join-Path $directory ($trackName + $extension)
    if ($Application -in @('Audacity', 'Resonic', 'WindowsMediaPlayerLegacy')) {
    [IO.File]::Copy((Join-Path $PSScriptRoot 'resources\silence.wav'), $filePath)
    $temporaryMediaPath = $filePath
    Write-Host "WAV file: $filePath"
    $player = [System.Windows.Media.MediaPlayer]::new()
    try {
        $player.Open([Uri]::new($filePath))
        Wait-Until { $player.NaturalDuration.HasTimeSpan } 'Windows could not decode the test WAV file.'
        $expectedDuration = 10
        Assert-True ([Math]::Abs($player.NaturalDuration.TimeSpan.TotalSeconds - $expectedDuration) -lt 0.01) 'The test WAV file does not have the expected duration.'
        Write-Host "Windows decoded the WAV file: $expectedDuration seconds of PCM audio."
    } finally { $player.Close() }
    } elseif ($Application -eq 'Word' -and $extension -eq '.html') {
        [IO.File]::WriteAllText($filePath, '<!doctype html><html><body><p>Integration test document</p></body></html>', [Text.UTF8Encoding]::new($false))
        Write-Host "HTML file: $filePath"
    } elseif ($Application -in @('Word', 'LibreOffice')) {
        Add-Type -AssemblyName System.IO.Compression
        $archive = [System.IO.Compression.ZipFile]::Open($filePath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $parts = @{
                '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
                '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
                'word/document.xml' = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Integration test document</w:t></w:r></w:p></w:body></w:document>'
            }
            foreach ($part in $parts.GetEnumerator()) {
                $entry = $archive.CreateEntry($part.Key)
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write($part.Value) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
        Write-Host "DOCX file: $filePath"
        if ($Application -eq 'LibreOffice') {
            $firstTrackName = 'KIS-First-' + [guid]::NewGuid().ToString('N')
            $firstFilePath = Join-Path $directory ($firstTrackName + $extension)
            [IO.File]::Copy($filePath, $firstFilePath)
            Write-Host "Second DOCX file: $firstFilePath"
        }
    } elseif ($Application -in @('Excel', 'Calc')) {
        Add-Type -AssemblyName System.IO.Compression
        $archive = [System.IO.Compression.ZipFile]::Open($filePath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $parts = @{
                '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
                '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
                'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Integration test" sheetId="1" r:id="rId1"/></sheets></workbook>'
                'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
                'xl/worksheets/sheet1.xml' = '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Integration test</t></is></c></row></sheetData></worksheet>'
            }
            foreach ($part in $parts.GetEnumerator()) {
                $entry = $archive.CreateEntry($part.Key)
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write($part.Value) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
        $firstTrackName = 'KIS-First-' + [guid]::NewGuid().ToString('N')
        $firstFilePath = Join-Path $directory ($firstTrackName + $extension)
        [IO.File]::Copy($filePath, $firstFilePath)
        Write-Host "XLSX files: $firstFilePath; $filePath"
    } elseif ($Application -eq 'Base') {
        [IO.File]::Copy((Join-Path $env:ProgramFiles 'LibreOffice\presets\database\biblio.odb'), $filePath)
        Write-Host "Base file: $filePath"
    } elseif ($Application -eq 'Access') {
        $engine = New-Object -ComObject DAO.DBEngine.120
        try {
            $database = $engine.CreateDatabase($filePath, ';LANGID=0x0409;CP=1252;COUNTRY=0', 128)
            try { $database.Close() } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
        } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
        Write-Host "Access file: $filePath"
    } elseif ($Application -eq 'Math') {
        $sourcePath = [IO.Path]::ChangeExtension($filePath, '.mml')
        [IO.File]::WriteAllText($sourcePath, '<?xml version="1.0" encoding="UTF-8"?><math xmlns="http://www.w3.org/1998/Math/MathML"><mrow><mi>x</mi><mo>+</mo><mn>1</mn></mrow></math>', [Text.UTF8Encoding]::new($false))
        Convert-WithLibreOffice $sourcePath 'odf' $directory $filePath
        $firstTrackName = 'KIS-First-' + [guid]::NewGuid().ToString('N')
        $firstFilePath = Join-Path $directory ($firstTrackName + $extension)
        [IO.File]::Copy($filePath, $firstFilePath)
        Write-Host "Math files: $firstFilePath; $filePath"
    } elseif ($Application -eq 'Draw') {
        Add-Type -AssemblyName System.IO.Compression
        $mediaType = 'application/vnd.oasis.opendocument.graphics'
        $body = '<office:drawing><draw:page draw:name="Page 1"/></office:drawing>'
        $archive = [System.IO.Compression.ZipFile]::Open($filePath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $parts = [ordered] @{
                'mimetype' = $mediaType
                'content.xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><office:document-content xmlns:office=`"urn:oasis:names:tc:opendocument:xmlns:office:1.0`" xmlns:draw=`"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0`" xmlns:math=`"http://www.w3.org/1998/Math/MathML`" office:version=`"1.2`"><office:body>$body</office:body></office:document-content>"
                'META-INF/manifest.xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><manifest:manifest xmlns:manifest=`"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0`" manifest:version=`"1.2`"><manifest:file-entry manifest:full-path=`"/`" manifest:media-type=`"$mediaType`"/><manifest:file-entry manifest:full-path=`"content.xml`" manifest:media-type=`"text/xml`"/></manifest:manifest>"
            }
            foreach ($part in $parts.GetEnumerator()) {
                $entry = $archive.CreateEntry($part.Key, [System.IO.Compression.CompressionLevel]::NoCompression)
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write($part.Value) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
        $firstTrackName = 'KIS-First-' + [guid]::NewGuid().ToString('N')
        $firstFilePath = Join-Path $directory ($firstTrackName + $extension)
        [IO.File]::Copy($filePath, $firstFilePath)
        Write-Host "$Application files: $firstFilePath; $filePath"
    } elseif ($Application -in @('PowerPoint', 'Impress')) {
        $sourcePath = [IO.Path]::ChangeExtension($filePath, '.fodp')
        $flatPresentation = '<?xml version="1.0" encoding="UTF-8"?><office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.2" office:mimetype="application/vnd.oasis.opendocument.presentation"><office:body><office:presentation><draw:page draw:name="Slide 1"><draw:frame svg:x="2cm" svg:y="2cm" svg:width="10cm" svg:height="3cm"><draw:text-box><text:p>Integration test presentation</text:p></draw:text-box></draw:frame></draw:page></office:presentation></office:body></office:document>'
        [IO.File]::WriteAllText($sourcePath, $flatPresentation, [Text.UTF8Encoding]::new($false))
        Convert-WithLibreOffice $sourcePath 'pptx' $directory $filePath
        $firstTrackName = 'KIS-First-' + [guid]::NewGuid().ToString('N')
        $firstFilePath = Join-Path $directory ($firstTrackName + $extension)
        [IO.File]::Copy($filePath, $firstFilePath)
        Write-Host "PPTX files: $firstFilePath; $filePath"
    } elseif ($Application -eq 'VLC') {
        [IO.File]::Copy((Join-Path $PSScriptRoot 'resources\RunningAppTest.mp4'), $filePath)
        $temporaryMediaPath = $filePath
        Write-Host "MP4 file: $filePath"
    } elseif ($Application -eq 'AcrobatReader') {
        $content = "BT /F1 18 Tf 72 720 Td (Integration test document) Tj ET`n"
        $objects = @(
            '<< /Type /Catalog /Pages 2 0 R >>',
            '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
            '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
            "<< /Length $($content.Length) >>`nstream`n${content}endstream"
        )
        $pdf = [Text.StringBuilder]::new("%PDF-1.4`n")
        $offsets = [Collections.Generic.List[int]]::new()
        foreach ($object in $objects) {
            $offsets.Add($pdf.Length)
            [void] $pdf.Append("$($offsets.Count) 0 obj`n$object`nendobj`n")
        }
        $xref = $pdf.Length
        [void] $pdf.Append("xref`n0 6`n0000000000 65535 f `n")
        foreach ($offset in $offsets) { [void] $pdf.Append(('{0:D10} 00000 n ' -f $offset) + "`n") }
        [void] $pdf.Append("trailer`n<< /Size 6 /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n")
        [IO.File]::WriteAllText($filePath, $pdf.ToString(), [Text.Encoding]::ASCII)
        Write-Host "PDF file: $filePath"
    } else {
        $imageFixture = if ($StartWithImage) { 'resources\image-second.jpg' } else { 'resources\image.jpg' }
        [IO.File]::Copy((Join-Path $PSScriptRoot $imageFixture), $filePath)
        $temporaryMediaPath = $filePath
        if ($StartWithImage) {
            Assert-True ((Get-FileHash -LiteralPath $filePath).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'resources\image.jpg')).Hash) 'The initial and transferred images must differ.'
        }
        $decoder = [System.Windows.Media.Imaging.JpegBitmapDecoder]::new([Uri]::new($filePath),
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        Assert-True ($decoder.Frames.Count -eq 1 -and $decoder.Frames[0].PixelWidth -eq 160 -and $decoder.Frames[0].PixelHeight -eq 100) 'The test JPEG could not be decoded at the expected size.'
        Write-Host "JPEG file: $filePath (160 x 100 pixels)"
    }

    if ($Application -eq 'Resonic') {
        Wait-Until {
            $apps = @($accessor.GetMethod('GetRunningApps').Invoke($null, @([string] $filePath)) | Where-Object { $_.App.Id -ieq $applicationPath })
            $script:resonicWindows = @($apps.Windows | Where-Object { $_.Title -match '(?i)resonic player' })
            $script:resonicWindows.Count -eq 1
        } 'The Resonic player window was not found.' 20
        $targetHandle = $script:resonicWindows[0].Handle
    }
    Wait-Until {
        $process.Refresh()
        $apps = @($accessor.GetMethod('GetRunningApps').Invoke($null, @([string] $filePath)) | Where-Object { $_.App.Id -ieq $applicationPath })
        $expectedHandle = if ($Application -eq 'Resonic') { $targetHandle } else { $process.MainWindowHandle }
        return $apps.Count -eq 1 -and @($apps[0].Windows | Where-Object { $_.Handle -eq $expectedHandle }).Count -eq 1
    } "The $Application main window was not found among the running apps." 20
    $running = @($accessor.GetMethod('GetRunningApps').Invoke($null, @([string] $filePath)))
    $matchingApps = @($running | Where-Object { $_.App.Id -ieq $applicationPath })
    Assert-True ($matchingApps.Count -eq 1) "Expected exactly one $Application application."
    $expectedHandle = if ($Application -eq 'Resonic') { $targetHandle } else { $process.MainWindowHandle }
    $mainWindows = @($matchingApps[0].Windows | Where-Object { $_.Handle -eq $expectedHandle })
    Assert-True ($mainWindows.Count -eq 1) "The started $Application main window was not found exactly once."
    $window = $mainWindows[0].PSObject.BaseObject
    Assert-True (@(Get-WindowNames $window.Handle | Where-Object { $_ -like "*$trackName*" }).Count -eq 0) 'The test track was already present before paste.'
    if ($StartWithImage) {
        Add-Type -AssemblyName System.Drawing
        Assert-True ([PasteWindowProbe]::ActivateTestWindow($window.Handle)) 'Could not activate IrfanView before checking the initial image.'
        $initialRedPixels = Get-IrfanRedPixelCount $window.Handle
    }
    if ($Application -eq 'IrfanView' -and $Transfer -eq 'Paste') {
        $emptyImageStatus = @(Get-WindowNames $window.Handle | Where-Object { $_ -match '(?i)kein bild geladen|no image loaded' })
        Assert-True ($emptyImageStatus.Count -eq 1) 'IrfanView must start without a loaded image for this test.'
    }

    if ($Application -eq 'Impress' -and -not $UseExisting) {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($window.Handle)
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'SALSUBFRAME')
        foreach ($dialog in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
            if ($dialog.Current.Name -in @('Dokumentvorlage auswählen', 'Select a Template') -and $dialog.Current.ProcessId -eq $process.Id -and $dialog.Current.NativeWindowHandle -ne 0) {
                Assert-True ([PasteWindowProbe]::PostMessage([IntPtr] $dialog.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'Could not close the test Impress template selector.'
            }
        }
    }
    $pasteNotBefore = [DateTime]::UtcNow.AddSeconds(5)
    Wait-Until { [DateTime]::UtcNow -ge $pasteNotBefore } "The $Application startup wait did not complete."
    $process.Refresh()
    Assert-True (-not $process.HasExited -and [PasteWindowProbe]::IsWindowEnabled($window.Handle)) "The $Application test window is no longer ready."
    if ($Application -eq 'WindowsMediaPlayerLegacy') {
        Assert-True (-not [PlaybackSessionProbe]::IsActive([uint32] $process.Id)) 'The test player was already playing before the transfer.'
    }
    if ($Transfer -notin @('ShellOpen', 'Menu')) {
        Assert-True ([PasteWindowProbe]::ActivateTestWindow($window.Handle)) "Could not activate the $Application test window."
    }
    if ($Transfer -eq 'ShellOpen' -and $NonDefault) {
        $result = $accessor.GetMethod('OpenByShellOpen').Invoke($null, [object[]] @($selectedApp, [string] $filePath))
        Assert-True ($result.Dispatched) "Shell Open failed: $($result.Error)"
        Wait-Until {
            if (Find-ShellDocument $trackName $processNames) { return $true }
            $process.Refresh()
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'bosa_sdm_msword')
            return @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) | Where-Object {
                $_.Current.Name -in @('Datei konvertieren', 'Convert File') -and $_.Current.ProcessId -eq $process.Id
            }).Count -gt 0
        } 'The test Word instance did not show the document or a conversion dialog.' 20
        Write-Host 'The selected Word application received the HTML open request.'
    } elseif ($Transfer -eq 'ShellOpen') {
        $firstTrackName = 'KIS-First-' + [guid]::NewGuid().ToString('N')
        $firstFilePath = Join-Path $directory ($firstTrackName + $extension)
        [IO.File]::Copy($filePath, $firstFilePath)
        $firstResult = $accessor.GetMethod('OpenByShellOpen').Invoke($null, [object[]] @($selectedApp, [string] $firstFilePath))
        Assert-True ($firstResult.Dispatched) "Could not open the first test document: $($firstResult.Error)"
        Wait-Until { Find-ShellDocument $firstTrackName $processNames } "$Application did not show the first test document." 20
        Write-Host "First document opened: $firstTrackName"
        $beforeProcessIds = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        $result = $accessor.GetMethod('OpenByShellOpen').Invoke($null, [object[]] @($selectedApp, [string] $filePath))
        Assert-True ($result.Dispatched) "Shell Open failed: $($result.Error)"
    } elseif ($Transfer -in @('OpenDialog', 'OpenDialogO', 'OpenDialogCtrlF12')) {
        $method = switch ($Transfer) {
            'OpenDialogO' { 'LetOpenByDialogUsingO' }
            'OpenDialogCtrlF12' { 'LetOpenByDialogUsingCtrlF12' }
            default { 'LetOpenByDialog' }
        }
        $result = $accessor.GetMethod($method).Invoke($null, [object[]] @($window, [string] $filePath)).GetAwaiter().GetResult()
        if (-not $result.Submitted) {
            Write-Host "Open dialog error: $($result.Error)"
            $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
            $topWindows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
            foreach ($topWindow in $topWindows) {
                Write-Host "Window: $($topWindow.Current.Name); class=$($topWindow.Current.ClassName); handle=$($topWindow.Current.NativeWindowHandle)"
                $elements = $topWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($element in $elements | Where-Object { $_.Current.ClassName -eq '#32770' }) {
                    Write-Host "  Dialog: $($element.Current.Name); class=$($element.Current.ClassName)"
                }
            }
        }
        Assert-True ($result.Submitted) "The Open dialog was not submitted: $($result.Error)"
    } elseif ($Transfer -eq 'Menu') {
        $menuOwner = [System.Windows.Window]::new()
        $menuOwner.Title = 'Running app menu test'
        $menuOwner.Width = 400
        $menuOwner.Height = 200
        $menuOwner.Show()
        Assert-True ($menuOwner.Activate()) 'Could not activate the test menu owner.'
        $menuOwnerHandle = [System.Windows.Interop.WindowInteropHelper]::new($menuOwner).Handle
        Wait-Until { [PasteWindowProbe]::GetForegroundWindow() -eq $menuOwnerHandle } 'The test menu owner did not become foreground.'
        $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
        $createActions = $view.GetType().GetMethod('CreateRunningAppActions', [Reflection.BindingFlags]'Instance,NonPublic')
        $actions = $createActions.Invoke($view, [object[]] @(,[string[]] @($filePath)))
        $title = if ([string]::IsNullOrWhiteSpace($window.Title)) { 'Untitled window' } else { $window.Title }
        $label = "$($matchingApps[0].App.Name) - $title".Replace('&', '&&')
        $action = @($actions | Where-Object { $_.Label -ceq $label })
        Assert-True ($action.Count -eq 1) 'The selected application window was not found exactly once in the menu actions.'
        $instanceFlags = [Reflection.BindingFlags]'Instance,NonPublic'
        $staticFlags = [Reflection.BindingFlags]'Static,NonPublic'
        $factory = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
        $paths = [string[]] @($filePath)
        $createContextActions = $view.GetType().GetMethod('CreateContextMenuActions', $instanceFlags)
        $baseMenu = $factory.GetMethod('GetBaseMenu', $staticFlags).Invoke($null, [object[]] @($paths, $menuOwnerHandle, $createContextActions.Invoke($view, @())))
        try { $snapshot = $baseMenu.GetType().GetMethod('CaptureSnapshot', $instanceFlags).Invoke($baseMenu, @()) }
        finally { ([IDisposable] $baseMenu).Dispose() }
        $menu = $factory.GetMethod('GetContentMenuForContextWithRunningApps', $staticFlags).Invoke($null, [object[]] @($paths, $menuOwnerHandle, $snapshot, $false, $null, $null, $actions))
        $errorProbe = [SutShellPropertiesProbe]::new('Open in running app')
        $menuProbe = [SutShellMenuProbe]::new($menuOwnerHandle)
        try {
            $menuProbe.SelectLabel = $label
            $findSubmenu = [Func[IntPtr, IntPtr]] { param($nativeMenu) [PasteWindowProbe]::GetSubMenu($nativeMenu, 1) }
            $menu.GetType().GetMethod('ShowSubmenu', $instanceFlags).Invoke($menu, [object[]] @($findSubmenu, 150, 150))
            Assert-True ($menu.GetType().GetProperty('CommandInvoked', $instanceFlags).GetValue($menu)) 'The running-app menu command was not invoked.'
            Assert-True (-not $errorProbe.Opened) 'The running-app menu action reported a transfer error.'
        } finally { $menuProbe.Dispose(); $errorProbe.Dispose(); ([IDisposable] $menu).Dispose() }
    } elseif ($Transfer -eq 'Resourceful') {
        $resourcefulFiles = if ($Application -in @('LibreOffice', 'Excel', 'Calc', 'PowerPoint', 'Impress', 'Draw', 'Math')) { [string[]] @($firstFilePath, $filePath) } else { [string[]] @($filePath) }
        $task = $accessor.GetMethod('OpenInRunningAppResourcefully').Invoke($null, [object[]] @($window, [string[]] $resourcefulFiles, $selectedApp))
        Wait-Until { $task.IsCompleted } 'The resourceful operation did not complete.' 15
        $result = $task.GetAwaiter().GetResult()
        Assert-True (-not $result.Error) "The resourceful operation failed: $($result.Error)"
        if ($Application -in @('Audacity', 'Resonic', 'WindowsMediaPlayerLegacy')) {
            Assert-True ($result.Dialogs.Count -eq 1 -and $result.Dialogs[0].Submitted -and $null -eq $result.Drop) 'The Open dialog did not replace the drop.'
        } elseif ($Application -eq 'IrfanView') {
            Assert-True ($result.Dialogs.Count -eq 0 -and $null -ne $result.Drop -and $result.Drop.Dropped) "The configured drop failed: $($result.Drop.Error)"
        } elseif ($Application -in @('Word', 'AcrobatReader', 'LibreOffice', 'Excel', 'Calc', 'PowerPoint', 'Impress', 'Draw', 'Math', 'Access', 'Base')) {
            Assert-True ($result.ShellOpens.Count -eq $resourcefulFiles.Count -and @($result.ShellOpens | Where-Object { -not $_.Dispatched }).Count -eq 0 -and $null -eq $result.Drop -and $result.Dialogs.Count -eq 0) 'The selected Shell Open handler was not used for every file.'
        } else {
            Assert-True ($result.Dialogs.Count -eq 1 -and ($result.Dialogs[0].Submitted -or ($null -ne $result.Drop -and $result.Drop.Dropped))) 'Neither the Open dialog nor the fallback drop succeeded.'
            Write-Host "Dialog submitted: $($result.Dialogs[0].Submitted); drop accepted: $($null -ne $result.Drop -and $result.Drop.Dropped)"
        }
    } elseif ($Transfer -eq 'Drop') {
        if ($Application -eq 'IrfanView') {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($window.Handle)
            $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'IrfanViewerClass')
            $viewer = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            Assert-True ($null -ne $viewer) 'The IrfanView image area was not found.'
            $bounds = $viewer.Current.BoundingRectangle
            $point = [PasteWindowProbe+Point]::new()
            $point.X = [int] ($bounds.X + $bounds.Width / 2)
            $point.Y = [int] ($bounds.Y + $bounds.Height / 2)
            Assert-True ([PasteWindowProbe]::ScreenToClient($window.Handle, [ref] $point)) 'The image-area coordinates could not be converted.'
            $result = $accessor.GetMethod('DropToAppWindowAt').Invoke($null, [object[]] @($window, [string[]] @([string] $filePath), $point.X, $point.Y))
        } else {
            $result = $accessor.GetMethod('DropToAppWindow').Invoke($null, [object[]] @($window, [string[]] @([string] $filePath)))
        }
        Assert-True ($result.Dropped) "The file drop failed: $($result.Error)"
    } else {
        $previousClipboard = [System.Windows.Clipboard]::GetDataObject()
        $files = [Collections.Specialized.StringCollection]::new()
        $null = $files.Add($filePath)
        [System.Windows.Clipboard]::SetFileDropList($files)
        $clipboardChanged = $true
        $result = $accessor.GetMethod('PasteByInteractionToAppWindow').Invoke($null, @($window))
        Assert-True ($result.Sent) "Ctrl+V could not be sent: $($result.Error)"
    }
    if ($Transfer -eq 'ShellOpen' -and $NonDefault) {
        Write-Host 'Shell Open dispatch completed; the application handles the dialog.'
    } elseif ($Application -eq 'WindowsMediaPlayerLegacy') {
        Wait-Until { [PlaybackSessionProbe]::IsActive([uint32] $process.Id) } 'The Legacy player did not start an audio session after the transfer.' 15
        $testContentLoaded = $true
        Write-Host 'Windows Media Player Legacy started playing the test WAV.'
    } elseif ($Application -in @('Access', 'Base')) {
        $expectedPath = if ($Application -eq 'Base') { Join-Path (Split-Path $applicationPath) 'soffice.bin' } else { $applicationPath }
        Wait-Until {
            @((Get-Process -Name $processNames -ErrorAction SilentlyContinue) | Where-Object {
                $_.Path -ieq $expectedPath -and $_.MainWindowTitle -like "*$trackName*" -and
                $_.MainWindowHandle -ne [IntPtr]::Zero -and [PasteWindowProbe]::IsWindowEnabled($_.MainWindowHandle)
            }).Count -gt 0
        } "$Application did not show the Resourceful test document in an enabled window." 25
        $testContentLoaded = $true
        Write-Host "$Application opened the Resourceful test document: $trackName"
    } elseif ($Application -in @('LibreOffice', 'Excel', 'Calc', 'PowerPoint', 'Impress', 'Draw', 'Math')) {
        $windowApplicationName = switch ($Application) { 'LibreOffice' { 'LibreOffice Writer' } { $_ -in @('Calc', 'Impress', 'Draw', 'Math') } { "LibreOffice $Application" } default { $Application } }
        Wait-Until { (Find-ProcessDocument $firstTrackName $process.Id $windowApplicationName) -and (Find-ProcessDocument $trackName $process.Id $windowApplicationName) } "$Application did not show both Resourceful test documents in enabled windows." 25
        $testContentLoaded = $true
        Write-Host "$Application opened both Resourceful test documents: $firstTrackName; $trackName"
    } elseif ($Application -eq 'IrfanView' -and $Transfer -eq 'Paste') {
        $observationEnds = [DateTime]::UtcNow.AddSeconds(10)
        Wait-Until { [DateTime]::UtcNow -ge $observationEnds } 'The IrfanView observation period did not complete.'
        $namesAfterPaste = @(Get-WindowNames $window.Handle)
        Assert-True ($emptyImageStatus[0] -in $namesAfterPaste -and @($namesAfterPaste | Where-Object { $_ -like "*$trackName*" }).Count -eq 0) 'IrfanView no longer reports an empty image after pasting a JPEG file.'
        Write-Host 'IrfanView did not load the JPEG from a clipboard file list, as expected.'
    } else {
        Write-Host "$Transfer was sent; checking $Application for the opened file."
        Wait-Until {
            if ($Transfer -eq 'ShellOpen') {
                $currentProcesses = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
                $currentProcessIds = @($currentProcesses | Select-Object -ExpandProperty Id)
                $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
                $handles = @($roots | Where-Object { $_.Current.ProcessId -in $currentProcessIds -and $_.Current.NativeWindowHandle -ne 0 } | ForEach-Object { [IntPtr] $_.Current.NativeWindowHandle })
            } elseif ($Application -eq 'Resonic') {
                $handles = @($window.Handle)
            } else {
                $process.Refresh()
                $handles = @($process.MainWindowHandle)
            }
            foreach ($currentHandle in $handles) {
                if ($currentHandle -eq [IntPtr]::Zero -or -not [PasteWindowProbe]::IsWindowEnabled($currentHandle)) { continue }
                if (@(Get-WindowNames $currentHandle | Where-Object { $_ -like "*$trackName*" }).Count -eq 0) { continue }
                if ($Application -eq 'Word') {
                    $root = [System.Windows.Automation.AutomationElement]::FromHandle($currentHandle)
                    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
                    $hasContent = $false
                    foreach ($document in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                        $pattern = $null
                        if ($document.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref] $pattern) -and $pattern.DocumentRange.GetText(-1) -like '*Integration test document*') { $hasContent = $true; break }
                    }
                    if (-not $hasContent) { continue }
                }
                $script:shellDocumentProcessId = [uint32] 0
                [void] [PasteWindowProbe]::GetWindowThreadProcessId($currentHandle, [ref] $script:shellDocumentProcessId)
                return $true
            }
            return $false
        } "$Application did not show the opened file after $Transfer, or a dialog is blocking it." 15
        if ($StartWithImage) {
            Wait-Until { (Get-IrfanRedPixelCount $window.Handle) -gt ($initialRedPixels + 30) } 'IrfanView did not visibly show the second image.' 15
            Write-Host 'IrfanView visibly displayed the red marker from the second image.'
        }
        $testContentLoaded = $true
        Write-Host "$Application opened the file: $trackName"
        if ($Transfer -eq 'ShellOpen') {
            if ($Application -eq 'AcrobatReader') {
                Add-Type -AssemblyName System.Windows.Forms
                $process.Refresh()
                Assert-True ($process.MainWindowTitle -like "*$trackName*" -and [PasteWindowProbe]::ActivateTestWindow($process.MainWindowHandle)) 'Could not activate the second test PDF.'
                [System.Windows.Forms.SendKeys]::SendWait('^{TAB}')
                Wait-Until { $process.Refresh(); $process.MainWindowTitle -like "*$firstTrackName*" } 'The first test PDF was not found in the other tab.' 10
                [System.Windows.Forms.SendKeys]::SendWait('^{TAB}')
                Wait-Until { $process.Refresh(); $process.MainWindowTitle -like "*$trackName*" } 'The second test PDF was not found after switching back.' 10
                Write-Host 'Both test PDFs remain open in separate tabs.'
            } else {
                Assert-True (Find-ShellDocument $firstTrackName $processNames) 'The first document is no longer visible after opening the second.'
                Write-Host 'The first document remains visible after opening the second.'
            }
            $afterProcessIds = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
            $newProcessIds = @($afterProcessIds | Where-Object { $_ -notin $beforeProcessIds })
            Write-Host "Processes before: $($beforeProcessIds -join ', '); after: $($afterProcessIds -join ', '); new: $($newProcessIds -join ', ')"
            Write-Host "Document window process: $script:shellDocumentProcessId; existing process reused: $($script:shellDocumentProcessId -in $beforeProcessIds)"
            $observationEnds = [DateTime]::UtcNow.AddSeconds(3)
            Wait-Until { [DateTime]::UtcNow -ge $observationEnds } 'The shell process observation period did not complete.'
            $remainingProcesses = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
            $remainingNew = @($remainingProcesses | Where-Object { $_.Id -notin $beforeProcessIds })
            Write-Host "Processes after observation: $(($remainingProcesses.Id) -join ', '); new processes still running: $(($remainingNew.Id) -join ', ')"
            foreach ($instance in $remainingNew) { Write-Host "  New process $($instance.Id): window=$($instance.MainWindowHandle); title=$($instance.MainWindowTitle)" }
        }
    }
} catch {
    Write-Host "Test error: $_"
    throw
} finally {
    try {
        if ($null -ne $menuOwner) { $menuOwner.Close() }
        if ($clipboardChanged) {
            if ($null -eq $previousClipboard) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($previousClipboard, $true) }
        }
    } finally {
        try {
            $process.Refresh()
            if (-not $process.HasExited -and -not $UseExisting) {
                if ($Application -eq 'Access') {
                    foreach ($instance in @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)) {
                        if ($instance.Id -ne $process.Id -and $instance.Path -ieq $expectedPath -and $instance.MainWindowTitle -like "*$trackName*") {
                            Assert-True ($instance.CloseMainWindow()) "The test $Application document did not close normally."
                        }
                    }
                }
                if ($Application -eq 'Base') {
                    $startupName = [IO.Path]::GetFileNameWithoutExtension($startupFile)
                    $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
                    foreach ($root in $roots) {
                        try {
                            if ($root.Current.ProcessId -eq $process.Id -and $root.Current.NativeWindowHandle -ne 0 -and
                                ($root.Current.Name -like "*$trackName*" -or $root.Current.Name -like "*$startupName*")) {
                                [void] [PasteWindowProbe]::PostMessage([IntPtr] $root.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                            }
                        } catch [System.Windows.Automation.ElementNotAvailableException] { }
                    }
                    Wait-Until { $process.Refresh(); $process.HasExited -or (-not (Find-ShellDocument $trackName $processNames) -and -not (Find-ShellDocument $startupName $processNames)) } 'The test Base documents did not close.' 10
                    $process.Refresh()
                }
                if ($Application -in @('LibreOffice', 'Excel', 'Calc', 'PowerPoint', 'Impress', 'Draw', 'Math')) {
                    $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
                    foreach ($root in $roots) {
                        try {
                            if ($root.Current.ProcessId -eq $process.Id -and $root.Current.NativeWindowHandle -ne 0 -and
                                ($root.Current.Name -like "*$trackName*" -or $root.Current.Name -like "*$firstTrackName*")) {
                                [void] [PasteWindowProbe]::PostMessage([IntPtr] $root.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                            }
                        } catch [System.Windows.Automation.ElementNotAvailableException] { }
                    }
                    Wait-Until { $process.Refresh(); $process.HasExited -or (-not (Find-ShellDocument $trackName $processNames) -and -not (Find-ShellDocument $firstTrackName $processNames)) } "The test $Application documents did not close." 10
                    $process.Refresh()
                }
                if ($Transfer -eq 'ShellOpen' -and $Application -eq 'AcrobatReader' -and $testContentLoaded) {
                    $process.Refresh()
                    if ($process.MainWindowTitle -like "*$trackName*" -and [PasteWindowProbe]::ActivateTestWindow($process.MainWindowHandle)) {
                        [System.Windows.Forms.SendKeys]::SendWait('^{TAB}')
                        Wait-Until { $process.Refresh(); $process.MainWindowTitle -like "*$firstTrackName*" } 'Could not select the first test PDF for cleanup.' 10
                        [System.Windows.Forms.SendKeys]::SendWait('^w')
                        Wait-Until { $process.Refresh(); $process.MainWindowTitle -like "*$trackName*" } 'The first test PDF did not close.' 10
                    }
                }
                if ($Transfer -eq 'ShellOpen' -and -not $NonDefault -and $Application -eq 'Word') {
                    $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
                    foreach ($root in $roots) {
                        try {
                            if ($root.Current.ProcessId -eq $process.Id -and $root.Current.NativeWindowHandle -ne 0 -and
                                ($root.Current.Name -like "*$trackName*" -or $root.Current.Name -like "*$firstTrackName*")) {
                                [void] [PasteWindowProbe]::PostMessage([IntPtr] $root.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                            }
                        } catch [System.Windows.Automation.ElementNotAvailableException] { }
                    }
                    Wait-Until { -not (Find-ShellDocument $trackName $processNames) -and -not (Find-ShellDocument $firstTrackName $processNames) } 'The test Word documents did not close.' 10
                    $process.Refresh()
                    if (-not $process.HasExited -and $process.MainWindowHandle -eq [IntPtr]::Zero) {
                        Wait-Until { $process.Refresh(); $process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero } 'The test Word process did not finish closing.' 10
                    }
                }
                if ($Application -eq 'AcrobatReader' -and -not $testContentLoaded) {
                    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
                    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770')
                    foreach ($dialog in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                        $dialogHandle = [IntPtr] $dialog.Current.NativeWindowHandle
                        if ($dialog.Current.Name -in @('Open', 'Öffnen') -and $dialogHandle -ne [IntPtr]::Zero -and
                            [PasteWindowProbe]::GetWindow($dialogHandle, 4) -eq $process.MainWindowHandle) {
                            [void] [PasteWindowProbe]::PostMessage($dialogHandle, 0x0111, [IntPtr] 2, [IntPtr]::Zero)
                            Wait-Until { [PasteWindowProbe]::IsWindowEnabled($process.MainWindowHandle) } 'The test Open dialog did not close.' 5
                        }
                    }
                }
                if ($Application -eq 'Word' -and ($process.MainWindowTitle -like "*$trackName*" -or
                    ($Transfer -eq 'ShellOpen' -and -not $testContentLoaded -and $process.MainWindowTitle -eq 'Word'))) {
                    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
                    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'bosa_sdm_msword')
                    foreach ($dialog in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                        if ($dialog.Current.Name -in @('Datei konvertieren', 'Convert File') -and $dialog.Current.NativeWindowHandle -ne 0) {
                            [void] [PasteWindowProbe]::PostMessage([IntPtr] $dialog.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                            Wait-Until { [PasteWindowProbe]::IsWindowEnabled($process.MainWindowHandle) } 'The test document dialog did not close.' 5
                        }
                    }
                }
                if (-not $UseExisting -and $Transfer -in @('OpenDialog', 'OpenDialogO', 'Resourceful', 'Menu', 'OpenDialogCtrlF12') -and -not $testContentLoaded) {
                    $dialog = [PasteWindowProbe]::GetForegroundWindow()
                    $dialogProcessId = [uint32] 0
                    [void] [PasteWindowProbe]::GetWindowThreadProcessId($dialog, [ref] $dialogProcessId)
                    if ($dialogProcessId -eq $process.Id -and [PasteWindowProbe]::GetWindow($dialog, 4) -eq $process.MainWindowHandle) {
                        $dialogElement = [System.Windows.Automation.AutomationElement]::FromHandle($dialog)
                        if ($null -ne $dialogElement -and $dialogElement.Current.ClassName -eq '#32770') {
                            if ([PasteWindowProbe]::PostMessage($dialog, 0x0111, [IntPtr] 2, [IntPtr]::Zero)) {
                                Wait-Until { [PasteWindowProbe]::IsWindowEnabled($process.MainWindowHandle) } 'The test Open dialog did not close.' 5
                            }
                        }
                    }
                }
                if (-not $process.HasExited -and ($Application -notin @('LibreOffice', 'Excel', 'Calc', 'PowerPoint', 'Impress', 'Draw', 'Math', 'Access', 'Base') -or $process.MainWindowHandle -ne [IntPtr]::Zero) -and -not $process.CloseMainWindow()) {
                    throw "$Application did not close normally. Resolve any open dialogs or unsaved work."
                }
                $promptHandled = $false
                $script:wordStartClosed = $false
                Wait-Until {
                    $process.Refresh()
                    if ($process.HasExited) { return $true }
                    if ($Application -eq 'Word' -and -not $script:wordStartClosed -and $process.MainWindowTitle -eq 'Word') {
                        $script:wordStartClosed = $process.CloseMainWindow()
                    }
                    if ($Application -eq 'Audacity' -and -not $UseExisting -and $testContentLoaded -and -not $promptHandled) {
                        $promptHandled = Close-TestSavePrompt $process.Id $trackName
                    }
                    return $false
                } "$Application did not close normally. Resolve any open dialogs or unsaved work." 10
                Write-Host "$Application closed normally."
            }
        } finally {
            try { $process.Dispose() } finally {
                if ($null -ne $temporaryMediaPath) { [IO.File]::Delete($temporaryMediaPath) }
            }
        }
    }
}