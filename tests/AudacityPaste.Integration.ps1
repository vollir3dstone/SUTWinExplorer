param(
    [ValidateSet('Audacity', 'IrfanView')]
    [string] $Application = 'Audacity',
    [ValidateSet('Paste', 'Drop', 'Both', 'Menu')]
    [string] $Transfer = 'Paste',
    [switch] $UseExisting
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
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
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
    public static bool ActivateTestWindow(IntPtr window)
    {
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        uint current = GetCurrentThreadId();
        bool attached = foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
        try { BringWindowToTop(window); return SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
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
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if ($null -eq $root) { return @() }
    $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($element in $elements) {
        try { $element.Current.Name } catch [System.Windows.Automation.ElementNotAvailableException] { }
    }
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
    $wpfApplication = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
    $wpfApplication.InitializeComponent()
    $wpfApplication.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $parseErrors = $null
    $suiteAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1'), [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw $parseErrors[0] }
    $suiteHelpers = $suiteAst.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('public sealed class SutShellTestSignal') }, $true)
    Add-Type -TypeDefinition $suiteHelpers.Value
}
$extension = if ($Application -eq 'Audacity') { '.wav' } else { '.jpg' }
$executableNames = if ($Application -eq 'Audacity') { @('Audacity.exe') } else { @('i_view64.exe', 'i_view32.exe') }
$processNames = if ($Application -eq 'Audacity') { @('audacity') } else { @('i_view64', 'i_view32') }
$registered = @($accessor.GetMethod('GetRegisteredApps').Invoke($null, @([string] "test$extension")) |
    Where-Object { [IO.Path]::GetFileName($_.Id) -in $executableNames -and [IO.File]::Exists($_.Id) })
Assert-True ($registered.Count -eq 1) "Expected exactly one registered $Application executable for $extension files."
$applicationPath = [string] $registered[0].Id

$existing = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
if ($UseExisting) {
    Assert-True ($existing.Count -eq 1) "UseExisting requires exactly one running $Application process."
    $process = $existing[0]
} else {
    foreach ($instance in $existing) {
        if (-not $instance.CloseMainWindow() -or -not $instance.WaitForExit(5000)) {
            throw "$Application did not close normally. Resolve any open dialogs or unsaved work and retry."
        }
    }
    $process = Start-Process -FilePath $applicationPath -PassThru
}
$previousClipboard = $null
$clipboardChanged = $false
$trackName = $null
$testContentLoaded = $false
try {
    Wait-Until { $process.Refresh(); -not $process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero } "$Application did not open a window."
    Assert-True (@(Get-Process -Name $processNames -ErrorAction SilentlyContinue).Count -eq 1) "Expected exactly one $Application process."
    Assert-True ([PasteWindowProbe]::IsWindowEnabled($process.MainWindowHandle)) "$Application has a blocking dialog. Resolve it before running the test."
    $pasteNotBefore = [DateTime]::UtcNow.AddSeconds(5)

    $directory = Join-Path ([IO.Path]::GetTempPath()) 'KIS-File-Paste-Test'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $trackName = 'KIS-Paste-' + [guid]::NewGuid().ToString('N')
    $filePath = Join-Path $directory ($trackName + $extension)
    if ($Application -eq 'Audacity') {
    $sampleRate = 44100
    $sampleCount = $sampleRate
    $writer = [IO.BinaryWriter]::new([IO.File]::Create($filePath))
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32] (36 + $sampleCount * 2))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([uint32] 16)
        $writer.Write([uint16] 1)
        $writer.Write([uint16] 1)
        $writer.Write([uint32] $sampleRate)
        $writer.Write([uint32] ($sampleRate * 2))
        $writer.Write([uint16] 2)
        $writer.Write([uint16] 16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32] ($sampleCount * 2))
        for ($sample = 0; $sample -lt $sampleCount; $sample++) {
            $writer.Write([int16] (10000 * [Math]::Sin(2 * [Math]::PI * 440 * $sample / $sampleRate)))
        }
    } finally { $writer.Dispose() }
    Write-Host "WAV file: $filePath"
    $player = [System.Windows.Media.MediaPlayer]::new()
    try {
        $player.Open([Uri]::new($filePath))
        Wait-Until { $player.NaturalDuration.HasTimeSpan } 'Windows could not decode the test WAV file.'
        Assert-True ([Math]::Abs($player.NaturalDuration.TimeSpan.TotalSeconds - 1) -lt 0.01) 'The test WAV file does not have the expected duration.'
        Write-Host 'Windows decoded the WAV file: one second of 440 Hz PCM audio.'
    } finally { $player.Close() }
    } else {
        $visual = [System.Windows.Media.DrawingVisual]::new()
        $drawing = $visual.RenderOpen()
        try {
            $drawing.DrawRectangle([System.Windows.Media.Brushes]::CornflowerBlue, $null, [System.Windows.Rect]::new(0, 0, 160, 100))
            $drawing.DrawEllipse([System.Windows.Media.Brushes]::Gold, $null, [System.Windows.Point]::new(80, 50), 30, 30)
        } finally { $drawing.Close() }
        $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(160, 100, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $encoder = [System.Windows.Media.Imaging.JpegBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create($filePath)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $decoder = [System.Windows.Media.Imaging.JpegBitmapDecoder]::new([Uri]::new($filePath),
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        Assert-True ($decoder.Frames.Count -eq 1 -and $decoder.Frames[0].PixelWidth -eq 160 -and $decoder.Frames[0].PixelHeight -eq 100) 'The test JPEG could not be decoded at the expected size.'
        Write-Host "JPEG file: $filePath (160 x 100 pixels)"
    }

    $running = @($accessor.GetMethod('GetRunningApps').Invoke($null, @([string] $filePath)))
    $matchingApps = @($running | Where-Object { $_.App.Id -ieq $applicationPath })
    Assert-True ($matchingApps.Count -eq 1) "Expected exactly one $Application application."
    $mainWindows = @($matchingApps[0].Windows | Where-Object { $_.Handle -eq $process.MainWindowHandle })
    Assert-True ($mainWindows.Count -eq 1) "The started $Application main window was not found exactly once."
    $window = $mainWindows[0].PSObject.BaseObject
    Assert-True (@(Get-WindowNames $window.Handle | Where-Object { $_ -like "*$trackName*" }).Count -eq 0) 'The test track was already present before paste.'
    if ($Application -eq 'IrfanView' -and $Transfer -eq 'Paste') {
        $emptyImageStatus = @(Get-WindowNames $window.Handle | Where-Object { $_ -match '(?i)kein bild geladen|no image loaded' })
        Assert-True ($emptyImageStatus.Count -eq 1) 'IrfanView must start without a loaded image for this test.'
    }

    Wait-Until { [DateTime]::UtcNow -ge $pasteNotBefore } "The $Application startup wait did not complete."
    Assert-True ([PasteWindowProbe]::ActivateTestWindow($window.Handle)) "Could not activate the $Application test window."
    if ($Transfer -eq 'Menu') {
        $previousClipboard = [System.Windows.Clipboard]::GetDataObject()
        $clipboardChanged = $true
        $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
        $createActions = $view.GetType().GetMethod('CreateRunningAppActions', [Reflection.BindingFlags]'Instance,NonPublic')
        $actions = $createActions.Invoke($view, [object[]] @(,[string[]] @($filePath)))
        $title = if ([string]::IsNullOrWhiteSpace($window.Title)) { 'Untitled window' } else { $window.Title }
        $label = "$($matchingApps[0].App.Name) - $title".Replace('&', '&&')
        $action = @($actions | Where-Object { $_.Label -ceq $label })
        Assert-True ($action.Count -eq 1) 'The selected application window was not found exactly once in the menu actions.'
        $errorProbe = [SutShellPropertiesProbe]::new('Open in running app')
        try {
            $action[0].Invoke.Invoke()
            Assert-True (-not $errorProbe.Opened) 'The running-app menu action reported a transfer error.'
        } finally { $errorProbe.Dispose() }
    } elseif ($Transfer -eq 'Both') {
        $previousClipboard = [System.Windows.Clipboard]::GetDataObject()
        $files = [Collections.Specialized.StringCollection]::new()
        $null = $files.Add($filePath)
        [System.Windows.Clipboard]::SetFileDropList($files)
        $clipboardChanged = $true
        $result = $accessor.GetMethod('OpenInRunningAppResourcefully').Invoke($null, [object[]] @($window, [string[]] @([string] $filePath)))
        Assert-True ($result.Paste.Sent) "Ctrl+V could not be sent: $($result.Paste.Error)"
        Assert-True ($result.Drop.Dropped) "The file drop failed: $($result.Drop.Error)"
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
    if ($Application -eq 'IrfanView' -and $Transfer -eq 'Paste') {
        $observationEnds = [DateTime]::UtcNow.AddSeconds(10)
        Wait-Until { [DateTime]::UtcNow -ge $observationEnds } 'The IrfanView observation period did not complete.'
        $namesAfterPaste = @(Get-WindowNames $window.Handle)
        Assert-True ($emptyImageStatus[0] -in $namesAfterPaste -and @($namesAfterPaste | Where-Object { $_ -like "*$trackName*" }).Count -eq 0) 'IrfanView no longer reports an empty image after pasting a JPEG file.'
        Write-Host 'IrfanView did not load the JPEG from a clipboard file list, as expected.'
    } else {
        Write-Host "$Transfer was sent; checking $Application for the opened file."
        Wait-Until { @(Get-WindowNames $window.Handle | Where-Object { $_ -like "*$trackName*" }).Count -gt 0 } "$Application did not show the file after $Transfer." 10
        $testContentLoaded = $true
        Write-Host "$Application opened the file: $trackName"
    }
} finally {
    try {
        if ($clipboardChanged) {
            if ($null -eq $previousClipboard) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($previousClipboard, $true) }
        }
    } finally {
        $process.Refresh()
        try {
            if (-not $process.HasExited) {
                if (-not $process.CloseMainWindow()) {
                    throw "$Application did not close normally. Resolve any open dialogs or unsaved work."
                }
                $promptHandled = $false
                Wait-Until {
                    $process.Refresh()
                    if ($process.HasExited) { return $true }
                    if ($Application -eq 'Audacity' -and -not $UseExisting -and $testContentLoaded -and -not $promptHandled) {
                        $promptHandled = Close-TestSavePrompt $process.Id $trackName
                    }
                    return $false
                } "$Application did not close normally. Resolve any open dialogs or unsaved work." 10
                Write-Host "$Application closed normally."
            }
        } finally { $process.Dispose() }
    }
}