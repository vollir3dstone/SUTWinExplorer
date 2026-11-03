using System.Runtime.InteropServices;
using System.Text;

namespace SUTWinExplorer;

internal sealed class SutContextMenu : IDisposable
{
    private readonly IntPtr _owner;
    private readonly IntPtr _menu;
    private readonly IContextMenu _contextMenu;
    private readonly IReadOnlyList<ShellMenuAction>? _actions;
    private readonly Action? _rename;
    private readonly Func<uint, bool> _isRename;
    private readonly Func<IReadOnlyDictionary<string, int>>? _captureSnapshot;
    private readonly Action<IntPtr>? _filterSubmenu;
    private readonly Action _release;
    private bool _disposed;

    internal SutContextMenu(IntPtr owner, IntPtr menu, IContextMenu contextMenu,
        IReadOnlyList<ShellMenuAction>? actions, Action? rename, Func<uint, bool> isRename,
        Func<IReadOnlyDictionary<string, int>>? captureSnapshot, Action<IntPtr>? filterSubmenu, Action release)
    {
        _owner = owner;
        _menu = menu;
        _contextMenu = contextMenu;
        _actions = actions;
        _rename = rename;
        _isRename = isRename;
        _captureSnapshot = captureSnapshot;
        _filterSubmenu = filterSubmenu;
        _release = release;
    }

    internal IReadOnlyDictionary<string, int>? Show(Func<int, int, bool, bool, bool>? secondRightClick = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        SubclassProc? subclassProc = null;
        MenuMessageFilter? menuFilter = null;
        IntPtr menuHook = IntPtr.Zero;
        var subclassInstalled = false;
        try
        {
            var menu3 = _contextMenu as IContextMenu3;
            var menu2 = _contextMenu as IContextMenu2;
            subclassProc = (window, message, wParam, lParam, subclassId, referenceData) =>
            {
                try
                {
                    if (message is 0x0117 or 0x002B or 0x002C or 0x0120)
                    {
                        var handled = false;
                        var result = IntPtr.Zero;
                        if (menu3 is not null)
                            handled = menu3.HandleMenuMsg2(message, wParam, lParam, out result) >= 0;
                        else if (menu2 is not null && menu2.HandleMenuMsg(message, wParam, lParam) >= 0)
                            handled = true;
                        if (message == 0x0117 && wParam != IntPtr.Zero)
                            _filterSubmenu?.Invoke(wParam);
                        if (handled)
                            return result;
                    }
                }
                catch (Exception exception)
                {
                    System.Diagnostics.Trace.TraceError("Context menu message forwarding failed: {0}", exception);
                }
                return DefSubclassProc(window, message, wParam, lParam);
            };
            if (!SetWindowSubclass(_owner, subclassProc, UIntPtr.Zero, UIntPtr.Zero))
                throw new InvalidOperationException("Could not install the native menu message handler.");
            subclassInstalled = true;
            if (!GetCursorPos(out var point))
                throw new InvalidOperationException("Could not read the pointer position.");
            if (secondRightClick is not null)
            {
                menuFilter = (code, wParam, lParam) =>
                {
                    if (code == 2 && lParam != IntPtr.Zero && Marshal.PtrToStructure<MenuMessage>(lParam) is { Message: 0x0204 or 0x0206 } message)
                    {
                        try
                        {
                            var clickPoint = message.Point;
                            var targetWindow = WindowFromPoint(clickPoint);
                            var overOwner = targetWindow == _owner || IsChild(_owner, targetWindow);
                            if (!overOwner &&
                                Math.Abs(clickPoint.X - point.X) <= GetSystemMetrics(36) / 2 &&
                                Math.Abs(clickPoint.Y - point.Y) <= GetSystemMetrics(37) / 2 &&
                                GetWindowThreadProcessId(targetWindow, out _) == GetCurrentThreadId())
                            {
                                var className = new StringBuilder(32);
                                _ = GetClassName(targetWindow, className, className.Capacity);
                                overOwner = className.ToString() == "#32768" &&
                                    SendMessage(targetWindow, 0x01E1, IntPtr.Zero, IntPtr.Zero) == _menu;
                            }
                            if (secondRightClick(clickPoint.X, clickPoint.Y, overOwner, (message.WParam.ToInt64() & 0x0004) != 0))
                            {
                                _ = PostMessage(_owner, 0x001F, IntPtr.Zero, IntPtr.Zero);
                                return new IntPtr(1);
                            }
                        }
                        catch (Exception exception)
                        {
                            System.Diagnostics.Trace.TraceError("Context menu right-click handling failed: {0}", exception);
                        }
                    }
                    return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
                };
                menuHook = SetWindowsHookEx(-1, menuFilter, IntPtr.Zero, GetCurrentThreadId());
                if (menuHook == IntPtr.Zero)
                    throw new InvalidOperationException("Could not monitor the native menu for a second right-click.");
            }

            _ = SetForegroundWindow(_owner);
            var flags = _filterSubmenu is not null ? 0x0100u : 0x0102u;
            var commandId = TrackPopupMenuEx(_menu, flags, point.X, point.Y, _owner, IntPtr.Zero);
            var snapshot = _captureSnapshot?.Invoke();
            _ = PostMessage(_owner, 0, IntPtr.Zero, IntPtr.Zero);
            if (commandId != 0)
            {
                if (_actions is not null && commandId >= 0x8000)
                {
                    var index = commandId - 0x8000;
                    if (index < _actions.Count && _actions[(int)index].IsEnabled)
                        _actions[(int)index].Invoke();
                }
                else if (_rename is not null && _isRename(commandId - 1))
                    _rename();
                else
                {
                    var invokeInfo = new ShellCommandInvokeInfo
                    {
                        Size = (uint)Marshal.SizeOf<ShellCommandInvokeInfo>(),
                        Mask = 0x00004000,
                        Owner = _owner,
                        Verb = new IntPtr(commandId - 1),
                        VerbW = new IntPtr(commandId - 1),
                        Show = 1
                    };
                    Marshal.ThrowExceptionForHR(_contextMenu.InvokeCommand(ref invokeInfo));
                }
            }
            return snapshot;
        }
        finally
        {
            if (menuHook != IntPtr.Zero) _ = UnhookWindowsHookEx(menuHook);
            GC.KeepAlive(menuFilter);
            if (subclassInstalled && subclassProc is not null)
                _ = RemoveWindowSubclass(_owner, subclassProc, UIntPtr.Zero);
        }
    }

    internal IReadOnlyDictionary<string, int> CaptureSnapshot()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _captureSnapshot?.Invoke() ?? throw new InvalidOperationException("This menu does not provide a snapshot.");
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _release();
    }

    [DllImport("user32.dll", SetLastError = true)] private static extern uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(NativePoint point);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder className, int maximum);
    [DllImport("user32.dll")] private static extern bool IsChild(IntPtr parent, IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int hook, MenuMessageFilter callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("comctl32.dll", SetLastError = true)] private static extern bool SetWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId, UIntPtr referenceData);
    [DllImport("comctl32.dll", SetLastError = true)] private static extern bool RemoveWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr SubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, UIntPtr referenceData);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr MenuMessageFilter(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MenuMessage
    {
        public IntPtr Window;
        public uint Message;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public NativePoint Point;
    }
}