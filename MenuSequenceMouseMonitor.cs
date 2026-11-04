using System.ComponentModel;
using System.Runtime.InteropServices;

namespace SUTWinExplorer;

internal sealed class MenuSequenceMouseMonitor : IDisposable
{
    private static MenuSequenceMouseMonitor? _active;
    private readonly HookProc _callback;
    private readonly Action _onExit;
    private readonly Point _origin;
    private readonly int _halfWidth;
    private readonly int _halfHeight;
    private IntPtr _hook;

    private MenuSequenceMouseMonitor(Action onExit)
    {
        _onExit = onExit;
        if (!GetCursorPos(out _origin))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        _halfWidth = GetSystemMetrics(36) / 2;
        _halfHeight = GetSystemMetrics(37) / 2;
        _callback = OnMouse;
        _hook = SetWindowsHookEx(14, _callback, IntPtr.Zero, 0);
        if (_hook == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    internal static MenuSequenceMouseMonitor Start(Action onExit)
    {
        _active?.Invalidate();
        return _active = new MenuSequenceMouseMonitor(onExit);
    }

    private IntPtr OnMouse(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && message == (IntPtr)0x0200 && data != IntPtr.Zero)
        {
            var point = Marshal.PtrToStructure<Point>(data);
            if (Math.Abs((long)point.X - _origin.X) > _halfWidth || Math.Abs((long)point.Y - _origin.Y) > _halfHeight)
                Invalidate();
        }
        return CallNextHookEx(IntPtr.Zero, code, message, data);
    }

    private void Invalidate()
    {
        Dispose();
        _onExit();
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero)
        {
            _ = UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        if (ReferenceEquals(_active, this)) _active = null;
        GC.KeepAlive(_callback);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }
    private delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int hook, HookProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
}