param(
    [ValidateSet('Audacity', 'IrfanView', 'Word', 'VLC', 'AcrobatReader')]
    [string] $Application = 'Audacity',
    [ValidateSet('Paste', 'Drop', 'Resourceful', 'Menu', 'OpenDialog', 'OpenDialogO', 'OpenDialogCtrlF12')]
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
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr window, uint command);
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
$extension, $executableNames, $processNames = switch ($Application) {
    'Audacity' { '.wav'; ,@('Audacity.exe'); ,@('audacity') }
    'IrfanView' { '.jpg'; ,@('i_view64.exe', 'i_view32.exe'); ,@('i_view64', 'i_view32') }
    'Word' { '.docx'; ,@('WINWORD.EXE'); ,@('WINWORD') }
    'VLC' { '.mp4'; ,@('vlc.exe'); ,@('vlc') }
    'AcrobatReader' { '.pdf'; ,@('AcroRd32.exe', 'Acrobat.exe'); ,@('AcroRd32', 'Acrobat') }
}
$registered = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @([string] "test$extension")) |
    Where-Object { [IO.Path]::GetFileName($_.Id) -in $executableNames -and [IO.File]::Exists($_.Id) })
Assert-True ($registered.Count -eq 1) "Expected exactly one registered $Application executable for $extension files."
$applicationPath = [string] $registered[0].Id

$existing = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
if ($UseExisting) {
    $existingWindows = @($existing | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    Assert-True ($existingWindows.Count -eq 1) "UseExisting requires exactly one running $Application main window."
    $process = $existingWindows[0]
} else {
    if ($existing.Count -gt 0) {
        throw "$Application is already running. Close it yourself or explicitly use -UseExisting."
    }
    $process = Start-Process -FilePath $applicationPath -PassThru
}
$previousClipboard = $null
$clipboardChanged = $false
$trackName = $null
$testContentLoaded = $false
try {
    if ($Application -eq 'AcrobatReader' -and -not $UseExisting) {
        Wait-Until { @(Get-Process -Name $processNames -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }).Count -eq 1 } "$Application did not open exactly one main window." 30
        $windowProcess = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })[0]
        $process.Dispose()
        $process = $windowProcess
    } else {
        Wait-Until { $process.Refresh(); -not $process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero } "$Application did not open a window."
    }
    if ($Application -ne 'AcrobatReader') {
        Assert-True (@(Get-Process -Name $processNames -ErrorAction SilentlyContinue).Count -eq 1) "Expected exactly one $Application process."
    }
    Assert-True ([PasteWindowProbe]::IsWindowEnabled($process.MainWindowHandle)) "$Application has a blocking dialog. Resolve it before running the test."
    $pasteNotBefore = [DateTime]::UtcNow.AddSeconds(5)

    $directory = Join-Path ([IO.Path]::GetTempPath()) 'KIS-File-Paste-Test'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $trackName = $(if ($Transfer -in @('OpenDialog', 'OpenDialogO', 'OpenDialogCtrlF12')) { 'KIS Öffnen ' } else { 'KIS-Paste-' }) + [guid]::NewGuid().ToString('N')
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
    } elseif ($Application -eq 'Word') {
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
    } elseif ($Application -eq 'VLC') {
        [IO.File]::Copy((Join-Path $PSScriptRoot 'RunningAppTest.mp4'), $filePath)
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

    Wait-Until {
        $process.Refresh()
        $apps = @($accessor.GetMethod('GetRunningApps').Invoke($null, @([string] $filePath)) | Where-Object { $_.App.Id -ieq $applicationPath })
        return $apps.Count -eq 1 -and @($apps[0].Windows | Where-Object { $_.Handle -eq $process.MainWindowHandle }).Count -eq 1
    } "The $Application main window was not found among the running apps." 20
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
    if ($Transfer -in @('OpenDialog', 'OpenDialogO', 'OpenDialogCtrlF12')) {
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
    } elseif ($Transfer -eq 'Resourceful') {
        $task = $accessor.GetMethod('OpenInRunningAppResourcefully').Invoke($null, [object[]] @($window, [string[]] @([string] $filePath)))
        Wait-Until { $task.IsCompleted } 'The resourceful operation did not complete.' 15
        $result = $task.GetAwaiter().GetResult()
        Assert-True (-not $result.Error) "The resourceful operation failed: $($result.Error)"
        if ($Application -eq 'Audacity') {
            Assert-True ($result.Dialogs.Count -eq 1 -and $result.Dialogs[0].Submitted -and $null -eq $result.Drop) 'The Open dialog did not replace the drop.'
        } elseif ($Application -eq 'IrfanView') {
            Assert-True ($result.Dialogs.Count -eq 1 -and -not $result.Dialogs[0].Submitted -and $result.Drop.Dropped) "The fallback drop failed: $($result.Drop.Error)"
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
    if ($Application -eq 'IrfanView' -and $Transfer -eq 'Paste') {
        $observationEnds = [DateTime]::UtcNow.AddSeconds(10)
        Wait-Until { [DateTime]::UtcNow -ge $observationEnds } 'The IrfanView observation period did not complete.'
        $namesAfterPaste = @(Get-WindowNames $window.Handle)
        Assert-True ($emptyImageStatus[0] -in $namesAfterPaste -and @($namesAfterPaste | Where-Object { $_ -like "*$trackName*" }).Count -eq 0) 'IrfanView no longer reports an empty image after pasting a JPEG file.'
        Write-Host 'IrfanView did not load the JPEG from a clipboard file list, as expected.'
    } else {
        Write-Host "$Transfer was sent; checking $Application for the opened file."
        Wait-Until {
            $process.Refresh()
            $currentHandle = $process.MainWindowHandle
            if ($currentHandle -eq [IntPtr]::Zero -or -not [PasteWindowProbe]::IsWindowEnabled($currentHandle)) { return $false }
            if (@(Get-WindowNames $currentHandle | Where-Object { $_ -like "*$trackName*" }).Count -eq 0) { return $false }
            if ($Application -eq 'Word') {
                $root = [System.Windows.Automation.AutomationElement]::FromHandle($currentHandle)
                $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
                foreach ($document in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                    $pattern = $null
                    if ($document.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref] $pattern) -and $pattern.DocumentRange.GetText(-1) -like '*Integration test document*') { return $true }
                }
                return $false
            }
            return $true
        } "$Application did not show the opened file after $Transfer, or a dialog is blocking it." 15
        $testContentLoaded = $true
        Write-Host "$Application opened the file: $trackName"
    }
} catch {
    Write-Host "Test error: $_"
    throw
} finally {
    try {
        if ($clipboardChanged) {
            if ($null -eq $previousClipboard) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($previousClipboard, $true) }
        }
    } finally {
        $process.Refresh()
        try {
            if (-not $process.HasExited -and -not $UseExisting) {
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
                if ($Application -eq 'Word' -and $process.MainWindowTitle -like "*$trackName*") {
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
                if (-not $process.CloseMainWindow()) {
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
        } finally { $process.Dispose() }
    }
}