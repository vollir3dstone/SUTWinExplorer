Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class ClipboardFeedbackSource : IDataObject
{
    private readonly IDataObject inner;
    public int Notifications;
    public int Effect;
    public ClipboardFeedbackSource(IDataObject inner) { this.inner = inner; }
    public static ClipboardFeedbackSource Install(string path)
    {
        var assembly = Array.Find(AppDomain.CurrentDomain.GetAssemblies(), item => item.GetName().Name == "SUTWinExplorer");
        var method = assembly.GetType("SUTWinExplorer.ShellDragDrop", true).GetMethod("CreateDataObject", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
        var data = (IDataObject)method.Invoke(null, new object[] { new string[] { path }, IntPtr.Zero });
        var source = new ClipboardFeedbackSource(data);
        Marshal.ThrowExceptionForHR(OleSetClipboard(source));
        return source;
    }
    public void GetData(ref FORMATETC format, out STGMEDIUM medium)
    {
        if (format.cfFormat != unchecked((short)RegisterClipboardFormat("Preferred DropEffect"))) { inner.GetData(ref format, out medium); return; }
        var memory = GlobalAlloc(0x0042, 4);
        var pointer = GlobalLock(memory);
        try { Marshal.WriteInt32(pointer, 2); } finally { GlobalUnlock(memory); }
        medium = new STGMEDIUM { tymed = TYMED.TYMED_HGLOBAL, unionmember = memory };
    }
    public void GetDataHere(ref FORMATETC format, ref STGMEDIUM medium) => inner.GetDataHere(ref format, ref medium);
    public int QueryGetData(ref FORMATETC format) => format.cfFormat == unchecked((short)RegisterClipboardFormat("Preferred DropEffect")) ? 0 : inner.QueryGetData(ref format);
    public int GetCanonicalFormatEtc(ref FORMATETC format, out FORMATETC result) => inner.GetCanonicalFormatEtc(ref format, out result);
    public void SetData(ref FORMATETC format, ref STGMEDIUM medium, bool release)
    {
        if (format.cfFormat != unchecked((short)RegisterClipboardFormat("Paste Succeeded"))) throw new NotImplementedException();
        IntPtr pointer = GlobalLock(medium.unionmember);
        try { Effect = Marshal.ReadInt32(pointer); Notifications++; }
        finally { GlobalUnlock(medium.unionmember); if (release) ReleaseStgMedium(ref medium); }
    }
    public IEnumFORMATETC EnumFormatEtc(DATADIR direction) => direction == DATADIR.DATADIR_GET ? new FeedbackFormats(inner.EnumFormatEtc(direction)) : inner.EnumFormatEtc(direction);
    public int DAdvise(ref FORMATETC format, ADVF flags, IAdviseSink sink, out int connection) => inner.DAdvise(ref format, flags, sink, out connection);
    public void DUnadvise(int connection) => inner.DUnadvise(connection);
    public int EnumDAdvise(out IEnumSTATDATA data) => inner.EnumDAdvise(out data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormat(string format);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("ole32.dll")] private static extern void ReleaseStgMedium(ref STGMEDIUM medium);
    [DllImport("ole32.dll")] public static extern int OleGetClipboard(out IDataObject data);
    [DllImport("ole32.dll")] public static extern int OleSetClipboard(IDataObject data);
}

public sealed class FeedbackFormats : IEnumFORMATETC
{
    private readonly System.Collections.Generic.List<FORMATETC> formats = new();
    private int index;
    public FeedbackFormats(IEnumFORMATETC inner)
    {
        var buffer = new FORMATETC[1];
        var fetched = new int[1];
        while (inner.Next(1, buffer, fetched) == 0) formats.Add(buffer[0]);
        formats.Add(new FORMATETC { cfFormat = unchecked((short)RegisterClipboardFormat("Preferred DropEffect")), dwAspect = DVASPECT.DVASPECT_CONTENT, lindex = -1, tymed = TYMED.TYMED_HGLOBAL });
    }
    private FeedbackFormats(System.Collections.Generic.List<FORMATETC> formats, int index) { this.formats = formats; this.index = index; }
    public int Next(int count, FORMATETC[] result, int[] fetched)
    {
        int copied = 0;
        while (copied < count && index < formats.Count) result[copied++] = formats[index++];
        if (fetched != null && fetched.Length > 0) fetched[0] = copied;
        return copied == count ? 0 : 1;
    }
    public int Skip(int count) { index = Math.Min(formats.Count, index + count); return index < formats.Count ? 0 : 1; }
    public int Reset() { index = 0; return 0; }
    public void Clone(out IEnumFORMATETC result) { result = new FeedbackFormats(formats, index); }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormat(string format);
}
'@
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$paste = $shell.GetMethod('PasteFromClipboard', $flags)
$original = [System.Windows.Clipboard]::GetDataObject()
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-clipboard-test-' + [guid]::NewGuid().ToString('N'))
try {
    $source = Join-Path $root 'source'
    $destination = Join-Path $root 'destination'
    [IO.Directory]::CreateDirectory($source) | Out-Null
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    foreach ($supportsFeedback in @($true, $false)) {
        $path = Join-Path $source "move-$supportsFeedback.txt"
        [IO.File]::WriteAllText($path, 'move')
        $data = [System.Windows.DataObject]::new()
        $paths = [System.Collections.Specialized.StringCollection]::new()
        $null = $paths.Add($path)
        $data.SetFileDropList($paths)
        $data.SetData('Preferred DropEffect', [IO.MemoryStream]::new([BitConverter]::GetBytes([uint32] 2)))
        [System.Windows.Clipboard]::SetDataObject($data, $false)
        $feedback = $null
        if ($supportsFeedback) {
            $feedback = [ClipboardFeedbackSource]::Install($path)
        }
        try {
            $null = $paste.Invoke($null, [object[]] @([string] $destination, [IntPtr]::Zero))
            if (-not $supportsFeedback) { throw 'Expected a notification failure.' }
        } catch {
            if ($supportsFeedback -or -not $_.Exception.ToString().Contains('The items were moved, but the clipboard source did not accept')) { throw }
        }
        if ([IO.File]::Exists($path) -or -not [IO.File]::Exists((Join-Path $destination ([IO.Path]::GetFileName($path))))) {
            throw "Move with supportsFeedback=$supportsFeedback did not move the file."
        }
        if ($supportsFeedback -and ($feedback.Notifications -ne 1 -or $feedback.Effect -ne 2)) { throw 'Incorrect Shell completion feedback.' }
    }
    $path = Join-Path $source 'unavailable.txt'
    [IO.File]::WriteAllText($path, 'unavailable')
    $feedback = [ClipboardFeedbackSource]::Install($path)
    [IO.File]::Delete($path)
    $failed = $false
    try { $null = $paste.Invoke($null, [object[]] @([string] $destination, [IntPtr]::Zero)) }
    catch { if (-not $_.Exception.ToString().Contains('Cannot move')) { throw }; $failed = $true }
    if (-not $failed) { throw 'An unavailable source was accepted.' }
    if ($feedback.Notifications -ne 0) { throw 'A failed move reported success.' }
    $folder = Join-Path $source 'folder'
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $feedback = [ClipboardFeedbackSource]::Install($folder)
    $inserted = [System.Collections.Generic.List[string]]::new()
    $moved = [System.Collections.Generic.List[System.ValueTuple[string,string]]]::new()
    $execute = $shell.GetMethod('ExecuteClipboardTransfer', $flags)
    $null = $execute.Invoke($null, [object[]] @([string] $destination, [IntPtr]::Zero, $null, $null, $inserted, $moved))
    if ($moved.Count -ne 1 -or $moved[0].Item1 -cne $folder -or $moved[0].Item2 -cne (Join-Path $destination 'folder') -or $feedback.Notifications -ne 1) {
        throw 'The clipboard folder move did not report its directory mapping and completion.'
    }
    $shellCut = Join-Path $source 'shell-cut.txt'
    [IO.File]::WriteAllText($shellCut, 'cut')
    $factory = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
    $menu = $factory.GetMethod('GetItemMenu', $flags).Invoke($null, [object[]] @([string[]] @($shellCut), [IntPtr]::Zero, $null))
    try { $null = $menu.GetType().GetMethod('InvokeVerb', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($menu, [object[]] @('cut')) }
    finally { ([IDisposable] $menu).Dispose() }
    $null = $paste.Invoke($null, [object[]] @([string] $destination, [IntPtr]::Zero))
    if ([IO.File]::Exists($shellCut) -or -not [IO.File]::Exists((Join-Path $destination 'shell-cut.txt'))) { throw 'Shell Cut did not complete.' }
    Write-Output 'Clipboard transfer tests passed.'
} finally {
    if ($null -eq $original) { [System.Windows.Clipboard]::Clear() }
    else { [System.Windows.Clipboard]::SetDataObject($original, $true) }
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}