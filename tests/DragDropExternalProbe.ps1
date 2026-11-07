param([string] $Title, [string] $Path, [string] $Mode, [string] $ResultPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
if ($Mode -eq 'source-all') {
    Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
[ComVisible(true), Guid("00000121-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IFeedbackDropSource
{
    [PreserveSig] int QueryContinueDrag([MarshalAs(UnmanagedType.Bool)] bool escape, uint keys);
    [PreserveSig] int GiveFeedback(uint effect);
}
[ComImport, Guid("DE5BF786-477A-11D2-839D-00C04FD918D0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITestDragSourceHelper
{
    [PreserveSig] int InitializeFromBitmap(ref TestDragImage image, IDataObject data);
    [PreserveSig] int InitializeFromWindow(IntPtr window, IntPtr point, IDataObject data);
}
[StructLayout(LayoutKind.Sequential)]
public struct TestDragImage
{
    public int width, height, offsetX, offsetY;
    public IntPtr bitmap;
    public uint colorKey;
}
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class FeedbackDropSource : IFeedbackDropSource
{
    private readonly string path;
    private readonly IDataObject data;
    public FeedbackDropSource(string path, IDataObject data) { this.path = path; this.data = data; }
    public int QueryContinueDrag(bool escape, uint keys) => escape ? 0x40101 : (keys & 1) == 0 ? 0x40100 : 0;
    public int GiveFeedback(uint effect)
    {
        File.WriteAllText(path, ((System.Windows.DragDropEffects)effect).ToString());
        var format = DescriptionFormat();
        try
        {
            data.GetData(ref format, out var medium);
            try
            {
                var pointer = GlobalLock(medium.unionmember);
                try
                {
                    var description = Marshal.ReadInt32(pointer) + ":" + Marshal.PtrToStringUni(IntPtr.Add(pointer, 4));
                    File.WriteAllText(path + ".description", description);
                    File.AppendAllText(path + ".history", ((System.Windows.DragDropEffects)effect) + "|" + description + "\n");
                }
                finally { GlobalUnlock(medium.unionmember); }
            }
            finally { ReleaseStgMedium(ref medium); }
        }
        catch (COMException) { File.WriteAllText(path + ".description", "missing"); }
        return 0x40102;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormat(string format);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("ole32.dll")] private static extern void ReleaseStgMedium(ref STGMEDIUM medium);
    private static FORMATETC DescriptionFormat() => new FORMATETC { cfFormat = unchecked((short)RegisterClipboardFormat("DropDescription")), dwAspect = DVASPECT.DVASPECT_CONTENT, lindex = -1, tymed = TYMED.TYMED_HGLOBAL };
    private static void SeedCopyDescription(IDataObject data)
    {
        var memory = GlobalAlloc(0x42, (UIntPtr)1044);
        var pointer = GlobalLock(memory);
        Marshal.WriteInt32(pointer, 1);
        var text = "Copy to %1\0".ToCharArray();
        Marshal.Copy(text, 0, IntPtr.Add(pointer, 4), text.Length);
        GlobalUnlock(memory);
        var format = DescriptionFormat();
        var medium = new STGMEDIUM { tymed = TYMED.TYMED_HGLOBAL, unionmember = memory };
        data.SetData(ref format, ref medium, true);
    }
    [DllImport("gdi32.dll")] private static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, IntPtr bits);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);
    public static uint Start(object data, string path)
    {
        var shellData = (IDataObject)data;
        var helper = (ITestDragSourceHelper)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("4657278A-411B-11D2-839A-00C04FD918D0")));
        var image = new TestDragImage { width = 32, height = 32, offsetX = 8, offsetY = 8, bitmap = CreateBitmap(32, 32, 1, 32, IntPtr.Zero), colorKey = 0xFFFFFFFF };
        try { Marshal.ThrowExceptionForHR(helper.InitializeFromBitmap(ref image, shellData)); }
        finally { DeleteObject(image.bitmap); Marshal.ReleaseComObject(helper); }
        SeedCopyDescription(shellData);
        uint effect; DoDragDrop(shellData, new FeedbackDropSource(path, shellData), 7, out effect); return effect;
    }
    [DllImport("ole32.dll", PreserveSig = true)]
    public static extern int DoDragDrop(IDataObject data, IFeedbackDropSource source, uint allowed, out uint effect);
}
'@ -ReferencedAssemblies PresentationCore, PresentationFramework, WindowsBase
    $assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
}
$application = [System.Windows.Application]::new()
$window = [System.Windows.Window]::new()
$window.Title = $Title
$window.Left = 1100; $window.Top = 500; $window.Width = 240; $window.Height = 120
$window.Topmost = $true
$surface = [System.Windows.Controls.Border]::new()
$surface.Background = [System.Windows.Media.Brushes]::LightGray
$label = [System.Windows.Controls.TextBlock]::new()
$label.Text = $Title
$surface.Child = $label
$window.Content = $surface
$window.AllowDrop = $true
$window.add_ContentRendered({ [IO.File]::WriteAllText($ResultPath + '.ready', 'ready') })
if ($Mode -in @('source', 'source-all', 'right-source', 'text')) {
    $window.add_GiveFeedback({ [IO.File]::WriteAllText($ResultPath + '.feedback', $_.Effects.ToString()) })
    $window.add_PreviewMouseMove({
        $button = if ($Mode -eq 'right-source') { [System.Windows.Input.Mouse]::RightButton } else { [System.Windows.Input.Mouse]::LeftButton }
        if ($button -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        [IO.File]::WriteAllText($ResultPath + '.started', 'started')
        if ($Mode -eq 'source-all') {
            $method = $assembly.GetType('SUTWinExplorer.ShellDragDrop', $true).GetMethod('CreateDataObject', [Reflection.BindingFlags]'Static,NonPublic')
            $data = $method.Invoke($null, [object[]] @([string[]] @($Path), [System.Windows.Interop.WindowInteropHelper]::new($window).Handle))
            try {
                $effect = [System.Windows.DragDropEffects] [FeedbackDropSource]::Start($data, $ResultPath + '.feedback')
            } finally { if ([Runtime.InteropServices.Marshal]::IsComObject($data)) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($data) } }
        } else {
            $data = [System.Windows.DataObject]::new()
            if ($Mode -ne 'text') { $data.SetData([System.Windows.DataFormats]::FileDrop, [string[]] @($Path)) }
            else { $data.SetData([System.Windows.DataFormats]::UnicodeText, 'not a file') }
            $effect = [System.Windows.DragDrop]::DoDragDrop($window, $data, [System.Windows.DragDropEffects]::Copy)
        }
        [IO.File]::WriteAllText($ResultPath, $effect.ToString())
        $window.Close()
    })
} else {
    $window.add_PreviewDragOver({
        if ($_.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $_.Effects = [System.Windows.DragDropEffects]::Copy }
        else { $_.Effects = [System.Windows.DragDropEffects]::None }
        $_.Handled = $true
    })
    $window.add_PreviewDrop({
        $paths = [string[]] $_.Data.GetData([System.Windows.DataFormats]::FileDrop)
        foreach ($source in $paths) { Copy-Item -LiteralPath $source -Destination $Path -Recurse }
        $_.Effects = [System.Windows.DragDropEffects]::Copy
        $_.Handled = $true
        [IO.File]::WriteAllText($ResultPath, 'Copy')
        $window.Close()
    })
}
$null = $application.Run($window)