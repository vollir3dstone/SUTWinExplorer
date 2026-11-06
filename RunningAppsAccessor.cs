using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace SUTWinExplorer;

public sealed record RegisteredApp(string Id, string Name);
public sealed record AppWindow(IntPtr Handle, string Title);
public sealed record RunningApp(RegisteredApp App, IReadOnlyList<AppWindow> Windows);
public sealed record PasteClipboardResult(bool Sent, string? Error);
public sealed record DropToWindowResult(bool Dropped, string? Error);
public sealed record OpenFileDialogResult(bool Submitted, string? Error);
public sealed record ResourcefulOpenResult(PasteClipboardResult Paste, DropToWindowResult Drop);

public static class RunningAppsAccessor
{
    private const uint AllAssociationHandlers = 0;
    private const uint RecommendedAssociationHandlers = 1;

    public static IReadOnlyList<RegisteredApp> GetRegisteredApps(string filePath)
        => GetRegisteredApps(filePath, AllAssociationHandlers);

    public static IReadOnlyList<RegisteredApp> GetRecommendedApps(string filePath)
        => GetRegisteredApps(filePath, RecommendedAssociationHandlers);

    public static IReadOnlyList<RegisteredApp> GetAppsToChooseFrom(string filePath)
        => GetRecommendedApps(filePath);

    private static IReadOnlyList<RegisteredApp> GetRegisteredApps(string filePath, uint filter)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        string extension = Path.GetExtension(filePath);
        if (string.IsNullOrEmpty(extension) || extension == ".")
            return Array.Empty<RegisteredApp>();

        Marshal.ThrowExceptionForHR(SHAssocEnumHandlers(extension, filter, out var enumerator));
        var apps = new Dictionary<string, RegisteredApp>(StringComparer.OrdinalIgnoreCase);
        try
        {
            while (true)
            {
                int result = enumerator.Next(1, out var handler, out uint fetched);
                Marshal.ThrowExceptionForHR(result);
                if (fetched == 0)
                    break;
                try
                {
                    if (handler.GetName(out string? id) < 0 || string.IsNullOrWhiteSpace(id))
                        continue;
                    _ = handler.GetUIName(out string? name);
                    apps.TryAdd(id, new RegisteredApp(id, string.IsNullOrWhiteSpace(name) ? id : name));
                }
                finally
                {
                    Marshal.ReleaseComObject(handler);
                }
            }
        }
        finally
        {
            Marshal.ReleaseComObject(enumerator);
        }
        return apps.Values.ToArray();
    }

    public static IReadOnlyList<AppWindow> GetUserWindows(RegisteredApp app)
    {
        ArgumentNullException.ThrowIfNull(app);
        var windows = new List<AppWindow>();
        if (!EnumWindows((window, parameter) =>
        {
            if (!IsWindowVisible(window) || (GetWindowLong(window, -20) & 0x80) != 0)
                return true;
            if (DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
                return true;
            int length = GetWindowTextLength(window);
            var title = new StringBuilder(length + 1);
            _ = GetWindowText(window, title, title.Capacity);
            _ = GetWindowThreadProcessId(window, out uint processId);
            if (MatchesApp(app.Id, processId))
                windows.Add(new AppWindow(window, title.ToString()));
            return true;
        }, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return windows;
    }

    public static IReadOnlyList<RunningApp> GetRunningApps(string filePath)
    {
        return GetAppsToChooseFrom(filePath)
            .Select(app => new RunningApp(app, GetUserWindows(app)))
            .Where(app => app.Windows.Count != 0)
            .ToArray();
    }

    public static PasteClipboardResult PasteByInteractionToAppWindow(AppWindow window)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            return new(false, "Clipboard access requires an STA thread.");
        try
        {
            var clipboard = System.Windows.Clipboard.GetDataObject();
            if (clipboard is null || !clipboard.GetDataPresent(System.Windows.DataFormats.FileDrop, false) ||
                clipboard.GetData(System.Windows.DataFormats.FileDrop, false) is not string[] paths ||
                paths.Length == 0 || paths.Any(path => string.IsNullOrWhiteSpace(path) || !File.Exists(path)))
                return new(false, "The clipboard must contain one or more existing files.");
        }
        catch (ExternalException exception)
        {
            return new(false, $"Could not read the clipboard: {exception.Message}");
        }

        return SendPasteByInteractionToAppWindow(window);
    }

    private static PasteClipboardResult SendPasteByInteractionToAppWindow(AppWindow window)
    {
        IntPtr handle = window.Handle;
        if (handle == IntPtr.Zero || !IsWindow(handle) || !IsWindowVisible(handle) || GetAncestor(handle, 2) != handle)
            return new(false, "The target window is no longer available.");
        if (!IsWindowEnabled(handle))
            return new(false, "The target window is disabled, possibly by a dialog.");
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C, 0x56 }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0))
            return new(false, "Release the modifier keys and V before pasting.");
        if (IsIconic(handle))
            _ = ShowWindowAsync(handle, 9);
        if (GetForegroundWindow() != handle && !SetForegroundWindow(handle))
            return new(false, "Could not activate the target window.");
        if (GetForegroundWindow() != handle)
            return new(false, "The target window is not in the foreground.");

        Input[] inputs = [KeyInput(0x11, false), KeyInput(0x56, false), KeyInput(0x56, true), KeyInput(0x11, true)];
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length)
        {
            if (sent != 0)
                _ = SendInput(2, [KeyInput(0x56, true), KeyInput(0x11, true)], Marshal.SizeOf<Input>());
            return new(false, "Could not send the complete Ctrl+V keystroke.");
        }
        return new(true, null);
    }

    public static async Task<OpenFileDialogResult> LetOpenByDialog(AppWindow window, string filePath)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        string fullPath = Path.GetFullPath(filePath);
        if (!File.Exists(fullPath))
            return new(false, "The file does not exist.");
        IntPtr handle = window.Handle;
        if (handle == IntPtr.Zero || !IsWindow(handle) || !IsWindowVisible(handle) || GetAncestor(handle, 2) != handle || !IsWindowEnabled(handle))
            return new(false, "The target window is unavailable or disabled.");
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C, 0x4F }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0))
            return new(false, "Release the modifier keys and O before opening the dialog.");
        if (IsIconic(handle))
            _ = ShowWindowAsync(handle, 9);
        if (GetForegroundWindow() != handle && !SetForegroundWindow(handle))
            return new(false, "Could not activate the target window.");
        if (GetForegroundWindow() != handle)
            return new(false, "The target window is not in the foreground.");

        _ = GetWindowThreadProcessId(handle, out uint processId);
        var existingWindows = new HashSet<IntPtr>();
        if (!EnumWindows((candidate, _) =>
        {
            existingWindows.Add(candidate);
            return true;
        }, IntPtr.Zero))
            return new(false, "Could not inspect existing windows before opening the dialog.");
        if (GetForegroundWindow() != handle || !IsWindow(handle) || !IsWindowEnabled(handle))
            return new(false, "The target window is no longer active and available.");
        Input[] inputs = [KeyInput(0x11, false), KeyInput(0x4F, false), KeyInput(0x4F, true), KeyInput(0x11, true)];
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length)
        {
            if (sent != 0)
                _ = SendInput(2, [KeyInput(0x4F, true), KeyInput(0x11, true)], Marshal.SizeOf<Input>());
            return new(false, "Could not send the complete Ctrl+O keystroke.");
        }

        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < TimeSpan.FromSeconds(5))
        {
            await Task.Delay(100).ConfigureAwait(false);
            IntPtr dialog = GetForegroundWindow();
            if (dialog == handle || dialog == IntPtr.Zero || existingWindows.Contains(dialog))
                continue;
            _ = GetWindowThreadProcessId(dialog, out uint dialogProcessId);
            if (dialogProcessId != processId || GetWindow(dialog, 4) != handle || !IsWindowVisible(dialog) || !IsWindowEnabled(dialog))
                continue;
            var className = new StringBuilder(64);
            _ = GetClassName(dialog, className, className.Capacity);
            if (className.ToString() != "#32770")
                return new(false, "The target opened an unsupported dialog.");
            var fileFields = new List<IntPtr>();
            var openButtons = new List<IntPtr>();
            if (!EnumChildWindows(dialog, (child, _) =>
            {
                var childClass = new StringBuilder(64);
                _ = GetClassName(child, childClass, childClass.Capacity);
                if (GetDlgCtrlID(child) == 1148 && childClass.ToString() == "Edit")
                    fileFields.Add(child);
                if (GetDlgCtrlID(child) == 1 && childClass.ToString() == "Button")
                    openButtons.Add(child);
                return true;
            }, IntPtr.Zero))
                return new(false, "Could not inspect the Open dialog controls.");
            if (fileFields.Count != 1 || openButtons.Count != 1 || !IsWindowVisible(fileFields[0]) || !IsWindowVisible(openButtons[0]) ||
                !IsWindowEnabled(fileFields[0]) || !IsWindowEnabled(openButtons[0]))
                return new(false, "The dialog could not be identified as a supported Open dialog.");
            var buttonName = new StringBuilder(256);
            _ = GetWindowText(openButtons[0], buttonName, buttonName.Capacity);
            if (buttonName.ToString().Replace("&", "", StringComparison.Ordinal).Trim() is not ("Open" or "Öffnen"))
                return new(false, "The dialog's confirmation button is not a supported Open command.");
            if (GetForegroundWindow() != dialog || !File.Exists(fullPath))
                return new(false, "The Open dialog or file is no longer available.");
            if (SendMessageTimeoutText(fileFields[0], 0x000C, UIntPtr.Zero, fullPath, 2, 1000, out var setResult) == IntPtr.Zero || setResult == UIntPtr.Zero)
                return new(false, "Could not enter the file name in the Open dialog.");
            var entered = new StringBuilder(fullPath.Length + 1);
            if (SendMessageTimeoutBuffer(fileFields[0], 0x000D, (UIntPtr)(uint)entered.Capacity, entered, 2, 1000, out _) == IntPtr.Zero ||
                GetForegroundWindow() != dialog || !File.Exists(fullPath) || !string.Equals(entered.ToString(), fullPath, StringComparison.OrdinalIgnoreCase))
                return new(false, "The Open dialog did not retain the requested file name.");
            if (!PostMessage(openButtons[0], 0x00F5, IntPtr.Zero, IntPtr.Zero))
                return new(false, "Could not submit the Open dialog.");
            return new(true, null);
        }
        return new(false, "No supported Open dialog appeared for the target window.");
    }

    public static ResourcefulOpenResult OpenInRunningAppResourcefully(AppWindow window, IReadOnlyList<string> paths)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(paths);
        string[] files = paths.ToArray();
        PasteClipboardResult paste;
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            paste = new(false, "Clipboard access requires an STA thread.");
        else
        {
            try
            {
                var clipboard = System.Windows.Clipboard.GetDataObject();
                if (clipboard is null || !clipboard.GetDataPresent(System.Windows.DataFormats.FileDrop, false) ||
                    clipboard.GetData(System.Windows.DataFormats.FileDrop, false) is not string[] clipboardFiles ||
                    files.Length == 0 || files.Any(path => string.IsNullOrWhiteSpace(path) || !File.Exists(path)) ||
                    !clipboardFiles.SequenceEqual(files, StringComparer.OrdinalIgnoreCase))
                    paste = new(false, "The clipboard file list does not match the requested files.");
                else
                    paste = SendPasteByInteractionToAppWindow(window);
            }
            catch (ExternalException exception)
            {
                paste = new(false, $"Could not read the clipboard: {exception.Message}");
            }
        }
        return new(paste, DropToAppWindow(window, files));
    }

    public static DropToWindowResult DropToAppWindow(AppWindow window, IReadOnlyList<string> paths)
        => DropToAppWindowCore(window, paths, null);

    public static DropToWindowResult DropToAppWindowAt(AppWindow window, IReadOnlyList<string> paths, int clientX, int clientY)
        => DropToAppWindowCore(window, paths, new NativePoint { X = clientX, Y = clientY });

    private static DropToWindowResult DropToAppWindowCore(AppWindow window, IReadOnlyList<string> paths, NativePoint? clientPoint)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(paths);
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            return new(false, "Drag and drop requires an STA thread.");
        if (paths.Count == 0 || paths.Any(path => string.IsNullOrWhiteSpace(path) || !File.Exists(path)))
            return new(false, "One or more existing files are required.");

        IntPtr handle = window.Handle;
        if (handle == IntPtr.Zero || !IsWindow(handle) || !IsWindowVisible(handle) || GetAncestor(handle, 2) != handle || !IsWindowEnabled(handle))
            return new(false, "The target window is unavailable or disabled.");
        if (new[] { 0x01, 0x02, 0x04, 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0))
            return new(false, "Release the mouse buttons and modifier keys before dragging.");
        if (IsIconic(handle))
            _ = ShowWindowAsync(handle, 9);
        if (GetForegroundWindow() != handle && !SetForegroundWindow(handle))
            return new(false, "Could not activate the target window.");
        if (!SpinWait.SpinUntil(() => GetForegroundWindow() == handle && !IsIconic(handle), TimeSpan.FromSeconds(1)))
            return new(false, "The target window did not become active and visible.");
        if (!GetClientRect(handle, out var rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top)
            return new(false, "Could not determine the target window's visible client area.");
        var point = clientPoint ?? new NativePoint { X = (rect.Left + rect.Right) / 2, Y = (rect.Top + rect.Bottom) / 2 };
        if (point.X < rect.Left || point.X >= rect.Right || point.Y < rect.Top || point.Y >= rect.Bottom)
            return new(false, "The drop point is outside the target window's client area.");
        if (!ClientToScreen(handle, ref point) || !SetCursorPos(point.X, point.Y) || GetAncestor(WindowFromPoint(point), 2) != handle)
            return new(false, "The target window's center is not accessible for dropping.");

        System.Runtime.InteropServices.ComTypes.IDataObject? data = null;
        var source = new ProgrammaticDropSource();
        Timer? timer = null;
        var timerLock = new object();
        int phase = 0;
        bool mouseDown = false;
        bool stopped = false;
        uint threadId = GetCurrentThreadId();
        bool oleInitialized = false;
        try
        {
            int oleResult = OleInitialize(IntPtr.Zero);
            if (oleResult < 0)
                return new(false, $"Could not initialize OLE: {Marshal.GetExceptionForHR(oleResult)?.Message}");
            oleInitialized = true;
            string? parent = Path.GetDirectoryName(Path.GetFullPath(paths[0]));
            if (paths.All(path => string.Equals(Path.GetDirectoryName(Path.GetFullPath(path)), parent, StringComparison.OrdinalIgnoreCase)))
                data = ShellDragDrop.CreateDataObject(paths, IntPtr.Zero);
            else
            {
                var fileData = new System.Windows.DataObject();
                fileData.SetData(System.Windows.DataFormats.FileDrop, paths.ToArray());
                data = (System.Runtime.InteropServices.ComTypes.IDataObject)fileData;
            }
            timer = new Timer(_ =>
            {
                lock (timerLock)
                {
                    if (stopped)
                        return;
                    if (!IsWindow(handle) || GetForegroundWindow() != handle || !GetCursorPos(out var cursor) ||
                        GetAncestor(WindowFromPoint(cursor), 2) != handle || Math.Abs(cursor.X - point.X) > 10 || Math.Abs(cursor.Y - point.Y) > 10)
                        source.Cancel = true;
                    Input input;
                    if (phase == 0 && !source.Cancel)
                    {
                        input = MouseInputEvent(0x0002, 0, 0);
                        mouseDown = true;
                    }
                    else if (phase == 1 && !source.Cancel)
                        input = MouseInputEvent(0x0001, 1, 0);
                    else
                    {
                        source.Drop = !source.Cancel;
                        input = MouseInputEvent(0x0004, 0, 0);
                        mouseDown = false;
                        stopped = true;
                    }
                    if (SendInput(1, [input], Marshal.SizeOf<Input>()) != 1)
                    {
                        source.Cancel = true;
                        _ = SendInput(1, [MouseInputEvent(0x0004, 0, 0)], Marshal.SizeOf<Input>());
                        _ = PostThreadMessage(threadId, 0x0100, new IntPtr(0x1B), IntPtr.Zero);
                        mouseDown = false;
                        stopped = true;
                    }
                    else
                    {
                        uint message = phase == 2 ? 0x0202u : 0x0200u;
                        int coordinates = unchecked((point.Y << 16) | (point.X & 0xFFFF));
                        _ = PostThreadMessage(threadId, message, phase == 2 ? IntPtr.Zero : new IntPtr(1), new IntPtr(coordinates));
                    }
                    phase++;
                }
            }, null, 150, 150);
            int result = DoDragDrop(data, source, 1, out uint effect);
            if (result < 0)
                return new(false, $"The drag operation failed: {Marshal.GetExceptionForHR(result)?.Message}");
            if (result != 0x00040100 || (effect & 1) == 0)
                return new(false, "The target did not accept the file drop.");
            return new(true, null);
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException)
        {
            return new(false, $"Could not start the file drag: {exception.Message}");
        }
        finally
        {
            timer?.Dispose();
            lock (timerLock)
            {
                stopped = true;
                if (mouseDown)
                    _ = SendInput(1, [MouseInputEvent(0x0004, 0, 0)], Marshal.SizeOf<Input>());
            }
            if (data is not null && Marshal.IsComObject(data))
                _ = Marshal.ReleaseComObject(data);
            if (oleInitialized)
                OleUninitialize();
        }
    }

    private static Input KeyInput(ushort key, bool keyUp) => new()
    {
        Type = 1,
        Data = new InputData { Keyboard = new KeyboardInput { VirtualKey = key, Flags = keyUp ? 2u : 0u } }
    };

    private static Input MouseInputEvent(uint flags, int x, int y) => new()
    {
        Type = 0,
        Data = new InputData { Mouse = new MouseInput { X = x, Y = y, Flags = flags } }
    };

    private static bool MatchesApp(string appId, uint processId)
    {
        try
        {
            using var process = Process.GetProcessById(checked((int)processId));
            string? executable = process.MainModule?.FileName;
            if (string.Equals(appId, executable, StringComparison.OrdinalIgnoreCase))
                return true;
            uint length = 0;
            if (GetApplicationUserModelId(process.Handle, ref length, null) != 122 || length == 0)
                return false;
            var id = new StringBuilder(checked((int)length));
            return GetApplicationUserModelId(process.Handle, ref length, id) == 0 &&
                string.Equals(appId, id.ToString(), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or Win32Exception or NotSupportedException)
        {
            return false;
        }
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [ComVisible(true), Guid("00000121-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDropSource
    {
        [PreserveSig] int QueryContinueDrag([MarshalAs(UnmanagedType.Bool)] bool escapePressed, uint keyState);
        [PreserveSig] int GiveFeedback(uint effect);
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    private sealed class ProgrammaticDropSource : IDropSource
    {
        internal volatile bool Drop;
        internal volatile bool Cancel;
        public int QueryContinueDrag(bool escapePressed, uint keyState) => escapePressed || Cancel ? 0x00040101 : Drop ? 0x00040100 : 0;
        public int GiveFeedback(uint effect) => 0x00040102;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputData Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHAssocEnumHandlers(string extension, uint filter, out IEnumAssocHandlers handlers);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(IntPtr window, EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern int GetDlgCtrlID(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr window, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowEnabled(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder className, int maximumLength);

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutText(IntPtr window, uint message, UIntPtr wParam, string text, uint flags, uint timeout, out UIntPtr result);

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutBuffer(IntPtr window, uint message, UIntPtr wParam, StringBuilder text, uint flags, uint timeout, out UIntPtr result);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, [In] Input[] inputs, int size);

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int DoDragDrop(System.Runtime.InteropServices.ComTypes.IDataObject data, IDropSource source, uint allowedEffects, out uint effect);

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int OleInitialize(IntPtr reserved);

    [DllImport("ole32.dll")]
    private static extern void OleUninitialize();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetClientRect(IntPtr window, out NativeRect rect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ClientToScreen(IntPtr window, ref NativePoint point);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(NativePoint point);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr window, int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int length);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out int value, int size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetApplicationUserModelId(IntPtr process, ref uint length, StringBuilder? applicationUserModelId);

    [ComImport, Guid("973810ae-9599-4b88-9e4d-6ee98c9552da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumAssocHandlers
    {
        [PreserveSig]
        int Next(uint count, [MarshalAs(UnmanagedType.Interface)] out IAssocHandler handler, out uint fetched);
    }

    [ComImport, Guid("f04061ac-1659-4a3f-a954-775aa57fc083"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAssocHandler
    {
        [PreserveSig]
        int GetName([MarshalAs(UnmanagedType.LPWStr)] out string? name);
        [PreserveSig]
        int GetUIName([MarshalAs(UnmanagedType.LPWStr)] out string? name);
    }
}