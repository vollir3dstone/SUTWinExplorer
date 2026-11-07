using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace SUTWinExplorer;

internal sealed class ClipboardChangeMonitor : IDisposable
{
    private const int ClipboardUpdate = 0x031D;
    private readonly HwndSource _source;
    private readonly Action _changed;

    public ClipboardChangeMonitor(Action changed)
    {
        _changed = changed;
        _source = new HwndSource(new HwndSourceParameters("ClipboardChangeMonitor") { ParentWindow = new IntPtr(-3) });
        _source.AddHook(WindowProc);
        if (!AddClipboardFormatListener(_source.Handle))
        {
            var error = Marshal.GetLastWin32Error();
            _source.Dispose();
            throw new Win32Exception(error, "Could not observe clipboard changes.");
        }
    }

    private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == ClipboardUpdate) _changed();
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        _ = RemoveClipboardFormatListener(_source.Handle);
        _source.RemoveHook(WindowProc);
        _source.Dispose();
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
}