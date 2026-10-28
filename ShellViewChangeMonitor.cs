using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Threading;

namespace SUTWinExplorer;

internal sealed class ShellViewChangeMonitor : IDisposable
{
    private const uint ObjectCreate = 0x8000;
    private const uint ObjectReorder = 0x8004;
    private const uint ObjectLocationChange = 0x800B;
    private readonly IntPtr _parentWindow;
    private readonly Dispatcher _dispatcher;
    private readonly Action<bool, bool> _changed;
    private readonly WinEventCallback _callback;
    private IntPtr _objectHook;
    private IntPtr _locationHook;
    private bool _itemsChanged;
    private bool _layoutChanged;
    private bool _queued;
    private bool _disposed;

    public ShellViewChangeMonitor(IntPtr parentWindow, Dispatcher dispatcher, Action<bool, bool> changed)
    {
        _parentWindow = parentWindow;
        _dispatcher = dispatcher;
        _changed = changed;
        _callback = OnWinEvent;
        var processId = (uint)Environment.ProcessId;
        _objectHook = SetWinEventHook(ObjectCreate, ObjectReorder, IntPtr.Zero, _callback, processId, 0, 0);
        if (_objectHook == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not observe Shell view changes.");

        _locationHook = SetWinEventHook(ObjectLocationChange, ObjectLocationChange, IntPtr.Zero, _callback, processId, 0, 0);
        if (_locationHook == IntPtr.Zero)
        {
            var error = Marshal.GetLastWin32Error();
            UnhookWinEvent(_objectHook);
            _objectHook = IntPtr.Zero;
            throw new Win32Exception(error, "Could not observe Shell layout changes.");
        }
    }

    private void OnWinEvent(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint eventThread, uint eventTime)
    {
        if (_disposed || window == IntPtr.Zero || !IsChild(_parentWindow, window))
            return;

        var name = new StringBuilder(64);
        if (GetClassName(window, name, name.Capacity) == 0)
            return;

        var className = name.ToString();
        // The Shell's DirectUI view reports its accessible child changes with positive object IDs.
        if (className == "DirectUIHWND" && objectId > 0 && eventType <= ObjectReorder)
            _itemsChanged = true;
        else if (className == "ScrollBar" && objectId == 0)
            _layoutChanged = true;
        else
            return;

        if (_queued || _dispatcher.HasShutdownStarted)
            return;
        _queued = true;
        _ = _dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(ProcessChanges));
    }

    private void ProcessChanges()
    {
        _queued = false;
        if (_disposed)
            return;
        var itemsChanged = _itemsChanged;
        var layoutChanged = _layoutChanged;
        _itemsChanged = false;
        _layoutChanged = false;
        _changed(itemsChanged, layoutChanged);
    }

    public void Dispose()
    {
        _disposed = true;
        if (_objectHook != IntPtr.Zero)
            UnhookWinEvent(_objectHook);
        if (_locationHook != IntPtr.Zero)
            UnhookWinEvent(_locationHook);
        _objectHook = IntPtr.Zero;
        _locationHook = IntPtr.Zero;
    }

    private delegate void WinEventCallback(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint eventThread, uint eventTime);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventCallback callback, uint processId, uint threadId, uint flags);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsChild(IntPtr parent, IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder className, int maximum);
}
