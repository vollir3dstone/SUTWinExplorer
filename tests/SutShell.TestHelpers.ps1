$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
public sealed class SutShellTestSignal
{
    public readonly System.Threading.ManualResetEvent Event = new(false);
    public void Notify() => Event.Set();
}

public sealed class SutShellPriorityProbe
{
    public object First;
    public object Visible;
    public string Order = "";
    public void OnPropertyChanged(object sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName != "Entry" || sender.GetType().GetProperty("Entry").GetValue(sender) == null) return;
        if (object.ReferenceEquals(sender, Visible)) Order += "V";
        if (object.ReferenceEquals(sender, First)) Order += "B";
    }
}

public sealed class SutShellRenameProbe
{
    public string OldPath;
    public string NewPath;
    public void OnDirectoryRenamed(string oldPath, string newPath) { OldPath = oldPath; NewPath = newPath; }
}

public sealed class SutShellMenuProbe : System.IDisposable
{
    private delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumWindowProc callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(System.IntPtr window, System.Text.StringBuilder name, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr SendMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetMenuItemCount(System.IntPtr menu);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetMenuItemID(System.IntPtr menu, int position);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetMenuString(System.IntPtr menu, uint position, System.Text.StringBuilder text, int length, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetMenuState(System.IntPtr menu, uint position, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr GetSubMenu(System.IntPtr menu, int position);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool RemoveMenu(System.IntPtr menu, uint position, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr CreatePopupMenu();
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyMenu(System.IntPtr menu);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern bool AppendMenu(System.IntPtr menu, uint flags, System.UIntPtr id, string text);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern System.IntPtr GetModuleHandle(string name);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int LoadString(System.IntPtr module, uint id, System.Text.StringBuilder text, int length);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetMenuItemRect(System.IntPtr window, System.IntPtr menu, uint item, out Rect rect);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct Point { public int X, Y; }
    private readonly uint thread = GetCurrentThreadId();
    private readonly System.IntPtr owner;
    private readonly System.Threading.Timer timer;
    private int ticks;
    private int handled;
    public int ItemCount = -1;
    public string[] Items;
    public uint[] States;
    public uint[] CommandIds;
    public int SelectIndex = -1;
    public string SelectLabel;
    public uint SelectCommandId = uint.MaxValue;
    public bool SelectWithRightButton;
    public string AlterSubmenu;
    public bool EmptySubmenu;
    public bool SubmenuAltered;

    public static void LeftClickAt(int x, int y)
    {
        SetCursorPos(x, y);
        mouse_event(2, 0, 0, 0, System.UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, System.UIntPtr.Zero);
    }

    public static void LeftDown() => mouse_event(2, 0, 0, 0, System.UIntPtr.Zero);
    public static void LeftUp() => mouse_event(4, 0, 0, 0, System.UIntPtr.Zero);

    public static System.IntPtr CreateAmbiguousMenu()
    {
        var menu = CreatePopupMenu();
        var submenu = CreatePopupMenu();
        if (menu == System.IntPtr.Zero || submenu == System.IntPtr.Zero ||
            !AppendMenu(menu, 0, new System.UIntPtr(1), "Shared") ||
            !AppendMenu(menu, 0, new System.UIntPtr(2), "Shared") ||
            !AppendMenu(menu, 0x10, new System.UIntPtr(unchecked((ulong)submenu.ToInt64())), "Lazy") ||
            !AppendMenu(menu, 0x800, System.UIntPtr.Zero, null))
            throw new System.InvalidOperationException("Could not create the ambiguous menu fixture.");
        return menu;
    }

    public static System.IntPtr CreateLazyBackgroundMenu()
    {
        var menu = CreatePopupMenu();
        foreach (var resourceId in new uint[] { 37460, 37462, 30315 })
        {
            var label = new System.Text.StringBuilder(256);
            var submenu = CreatePopupMenu();
            if (menu == System.IntPtr.Zero || submenu == System.IntPtr.Zero ||
                LoadString(GetModuleHandle("shell32.dll"), resourceId, label, label.Capacity) <= 0 ||
                !AppendMenu(menu, 0x10, new System.UIntPtr(unchecked((ulong)submenu.ToInt64())), label.ToString()))
                throw new System.InvalidOperationException("Could not create the lazy background menu fixture.");
        }
        return menu;
    }

    public static string OpenWithLabel()
    {
        var text = new System.Text.StringBuilder(256);
        return LoadString(GetModuleHandle("shell32.dll"), 5376, text, text.Capacity) > 0 ? text.ToString() : null;
    }

    public static string LinkDropHereLabel()
    {
        var module = GetModuleHandle("HardlinkShellExt.dll");
        if (module == System.IntPtr.Zero) return null;
        var text = new System.Text.StringBuilder(256);
        return LoadString(module, 241, text, text.Capacity) > 0 ? text.ToString() : null;
    }

    public SutShellMenuProbe(System.IntPtr owner)
    {
        this.owner = owner;
        timer = new System.Threading.Timer(Check, null, 50, 50);
    }

    private void Check(object state)
    {
        EnumThreadWindows(thread, (window, parameter) =>
        {
            var name = new System.Text.StringBuilder(64);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "#32768") return true;
            var menu = SendMessage(window, 0x01E1, System.IntPtr.Zero, System.IntPtr.Zero);
            var itemCount = GetMenuItemCount(menu);
            if (itemCount < 0) return true;
            if (System.Threading.Interlocked.Exchange(ref handled, 1) != 0)
            {
                if (SelectWithRightButton && ticks >= 4)
                    PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
                return false;
            }
            ItemCount = itemCount;
            Items = new string[ItemCount];
            States = new uint[ItemCount];
            CommandIds = new uint[ItemCount];
            for (var index = 0; index < ItemCount; index++)
            {
                var text = new System.Text.StringBuilder(512);
                GetMenuString(menu, (uint)index, text, text.Capacity, 0x400);
                Items[index] = text.ToString();
                States[index] = GetMenuState(menu, (uint)index, 0x400);
                CommandIds[index] = GetMenuItemID(menu, index);
            }
            if (SelectLabel != null) SelectIndex = System.Array.IndexOf(Items, SelectLabel);
            else if (SelectCommandId != uint.MaxValue) SelectIndex = System.Array.IndexOf(CommandIds, SelectCommandId);
            if (AlterSubmenu != null)
            {
                var index = System.Array.IndexOf(Items, AlterSubmenu);
                var submenu = index < 0 ? System.IntPtr.Zero : GetSubMenu(menu, index);
                var count = submenu == System.IntPtr.Zero ? 0 : GetMenuItemCount(submenu);
                if (count > 1 && GetSubMenu(submenu, count - 1) == System.IntPtr.Zero)
                {
                    SubmenuAltered = RemoveMenu(submenu, (uint)(count - 1), 0x400);
                    while (SubmenuAltered && EmptySubmenu && --count > 0)
                        SubmenuAltered = RemoveMenu(submenu, (uint)(count - 1), 0x400);
                }
            }
            if (SelectIndex >= 0 && SelectIndex < ItemCount && (States[SelectIndex] & 3) == 0 &&
                GetMenuItemRect(window, menu, (uint)SelectIndex, out var rect) && GetCursorPos(out var original))
            {
                SetCursorPos((rect.Left + rect.Right) / 2, (rect.Top + rect.Bottom) / 2);
                mouse_event(SelectWithRightButton ? 8u : 2u, 0, 0, 0, System.UIntPtr.Zero);
                mouse_event(SelectWithRightButton ? 16u : 4u, 0, 0, 0, System.UIntPtr.Zero);
                SetCursorPos(original.X, original.Y);
            }
            else PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
            return false;
        }, System.IntPtr.Zero);
        if (System.Threading.Interlocked.Increment(ref ticks) > 100)
            PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
    }

    public void Dispose() => timer.Dispose();
}

public sealed class SutShellPropertiesProbe : System.IDisposable
{
    private delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentProcessId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(System.IntPtr window, out uint process);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(System.IntPtr window, System.Text.StringBuilder name, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetWindowText(System.IntPtr window, System.Text.StringBuilder text, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    private readonly uint process = GetCurrentProcessId();
    private readonly string filename;
    private readonly System.Threading.Timer timer;
    private int handled;
    public bool Opened;

    public SutShellPropertiesProbe(string filename)
    {
        this.filename = filename;
        timer = new System.Threading.Timer(Check, null, 50, 50);
    }

    private void Check(object state)
    {
        EnumWindows((window, parameter) =>
        {
            GetWindowThreadProcessId(window, out var ownerProcess);
            if (ownerProcess != process) return true;
            var name = new System.Text.StringBuilder(64);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "#32770") return true;
            var title = new System.Text.StringBuilder(512);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString().IndexOf(filename, System.StringComparison.OrdinalIgnoreCase) < 0) return true;
            if (System.Threading.Interlocked.Exchange(ref handled, 1) != 0) return false;
            Opened = true;
            PostMessage(window, 0x0010, System.IntPtr.Zero, System.IntPtr.Zero);
            return false;
        }, System.IntPtr.Zero);
    }

    public void Dispose() => timer.Dispose();
}

public sealed class SutShellDeleteConfirmProbe : System.IDisposable
{
    private delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentProcessId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(System.IntPtr window, out uint process);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(System.IntPtr window, System.Text.StringBuilder name, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr GetDlgItem(System.IntPtr window, int id);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    private readonly uint process = GetCurrentProcessId();
    private readonly System.Threading.Timer timer;

    public SutShellDeleteConfirmProbe() => timer = new System.Threading.Timer(Check, null, 50, 50);

    private void Check(object state)
    {
        EnumWindows((window, parameter) =>
        {
            GetWindowThreadProcessId(window, out var ownerProcess);
            if (ownerProcess != process) return true;
            var name = new System.Text.StringBuilder(64);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "#32770") return true;
            var button = GetDlgItem(window, 6);
            if (button != System.IntPtr.Zero) PostMessage(button, 0x00F5, System.IntPtr.Zero, System.IntPtr.Zero);
            return true;
        }, System.IntPtr.Zero);
    }

    public void Dispose() => timer.Dispose();
}

public sealed class SutShellExtensionConfirmProbe : System.IDisposable
{
    private delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentProcessId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(System.IntPtr window, out uint process);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetWindowText(System.IntPtr window, System.Text.StringBuilder text, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    private readonly uint process = GetCurrentProcessId();
    private readonly System.Threading.Timer timer;
    public bool Seen;
    public SutShellExtensionConfirmProbe() => timer = new System.Threading.Timer(Check, null, 50, 50);
    private void Check(object state)
    {
        EnumWindows((window, parameter) =>
        {
            GetWindowThreadProcessId(window, out var ownerProcess);
            if (ownerProcess != process) return true;
            var title = new System.Text.StringBuilder(256);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString() != "File extension") return true;
            Seen = true;
            PostMessage(window, 0x0111, new System.IntPtr(7), System.IntPtr.Zero);
            return false;
        }, System.IntPtr.Zero);
    }
    public void Dispose() => timer.Dispose();
}

public sealed class SutShellRightClickProbe : System.IDisposable
{
    private delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumWindowProc callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(System.IntPtr window, System.Text.StringBuilder name, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr SendMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetMenuString(System.IntPtr menu, uint position, System.Text.StringBuilder text, int length, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int GetMenuItemCount(System.IntPtr menu);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetMenuItemID(System.IntPtr menu, int position);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetMenuItemRect(System.IntPtr window, System.IntPtr menu, uint item, out Rect rect);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr WindowFromPoint(Point point);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, System.UIntPtr extra);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct Point { public int X, Y; }
    private readonly uint thread = GetCurrentThreadId();
    private readonly System.IntPtr owner;
    private readonly System.Threading.Timer timer;
    private int phase;
    private int ticks;
    private int checking;
    private System.IntPtr firstMenu;
    private System.IntPtr currentMenu;
    private readonly int targetX;
    private readonly int targetY;
    private int startX;
    private int startY;
    private long secondClickAt;
    private long noMenuCheckAt;
    public static uint PropertiesCommandId;
    public static uint NameClipboardCopyCommandId;
    public bool FirstMenu;
    public bool SecondMenu;
    public bool SecondWasBase;
    public bool SecondWithShift;
    public int SecondDelayMilliseconds;
    public int AdditionalClicks;
    public int AdditionalMenuCount;
    public bool NoMenuObserved;
    public bool[] AdditionalMenuWasBase = new bool[2];
    public string[] SecondItems;
    public uint[] SecondCommandIds;
    public string TargetClass;
    public string ObservedFirstLabel;
    public string StartClass;
    public int[] ActualStart;

    public SutShellRightClickProbe(System.IntPtr owner, int targetX, int targetY)
    {
        this.owner = owner;
        this.targetX = targetX;
        this.targetY = targetY;
        timer = new System.Threading.Timer(Check, null, 50, 50);
    }

    public SutShellRightClickProbe(System.IntPtr owner, int startX, int startY, int targetX, int targetY)
    {
        this.owner = owner;
        this.startX = startX;
        this.startY = startY;
        this.targetX = targetX;
        this.targetY = targetY;
        phase = -1;
        timer = new System.Threading.Timer(Check, null, 50, 50);
    }

    public static int[] CursorPosition()
    {
        GetCursorPos(out var point);
        return new[] { point.X, point.Y };
    }

    public static void MovePointer(int x, int y) => SetCursorPos(x, y);

    private void Check(object state)
    {
        if (System.Threading.Interlocked.Exchange(ref checking, 1) != 0) return;
        try
        {
            if (phase == -1)
            {
                phase = 0;
                SetCursorPos(startX, startY);
                GetCursorPos(out var actualStart);
                ActualStart = new[] { actualStart.X, actualStart.Y };
                var startName = new System.Text.StringBuilder(64);
                GetClassName(WindowFromPoint(actualStart), startName, startName.Capacity);
                StartClass = startName.ToString();
                mouse_event(8, 0, 0, 0, System.UIntPtr.Zero);
                mouse_event(16, 0, 0, 0, System.UIntPtr.Zero);
                return;
            }
            var popupFound = false;
            EnumThreadWindows(thread, (window, parameter) =>
            {
                var name = new System.Text.StringBuilder(64);
                GetClassName(window, name, name.Capacity);
                if (name.ToString() != "#32768") return true;
                var menu = SendMessage(window, 0x01E1, System.IntPtr.Zero, System.IntPtr.Zero);
                var itemCount = GetMenuItemCount(menu);
                if (itemCount < 0) return true;
                popupFound = true;
                var label = new System.Text.StringBuilder(512);
                GetMenuString(menu, 2, label, label.Capacity, 0x400);
                var isBase = GetMenuItemID(menu, 0) == PropertiesCommandId && GetMenuItemID(menu, 2) == NameClipboardCopyCommandId;
                if (phase == 0 && ObservedFirstLabel == null) ObservedFirstLabel = label.ToString();
                if (phase == 0 && isBase)
                {
                    FirstMenu = true;
                    firstMenu = menu;
                    phase = 3;
                    secondClickAt = System.Environment.TickCount64 + SecondDelayMilliseconds;
                }
                if (phase == 3 && menu == firstMenu && System.Environment.TickCount64 >= secondClickAt)
                {
                    phase = 1;
                    SetCursorPos(targetX, targetY);
                    var targetName = new System.Text.StringBuilder(64);
                    GetClassName(WindowFromPoint(new Point { X = targetX, Y = targetY }), targetName, targetName.Capacity);
                    TargetClass = targetName.ToString();
                    if (SecondWithShift) keybd_event(0x10, 0, 0, System.UIntPtr.Zero);
                    try
                    {
                        mouse_event(8, 0, 0, 0, System.UIntPtr.Zero);
                        mouse_event(16, 0, 0, 0, System.UIntPtr.Zero);
                    }
                    finally
                    {
                        if (SecondWithShift) keybd_event(0x10, 0, 2, System.UIntPtr.Zero);
                    }
                }
                else if (phase == 1 && menu != firstMenu)
                {
                    SecondMenu = true;
                    SecondWasBase = isBase;
                    SecondItems = new string[itemCount];
                    SecondCommandIds = new uint[SecondItems.Length];
                    for (var index = 0; index < SecondItems.Length; index++)
                    {
                        var itemLabel = new System.Text.StringBuilder(512);
                        GetMenuString(menu, (uint)index, itemLabel, itemLabel.Capacity, 0x400);
                        SecondItems[index] = itemLabel.ToString();
                        SecondCommandIds[index] = GetMenuItemID(menu, index);
                    }
                    if (AdditionalClicks > 0)
                    {
                        currentMenu = menu;
                        phase = 4;
                        secondClickAt = System.Environment.TickCount64 + SecondDelayMilliseconds;
                    }
                    else
                    {
                        phase = 2;
                        PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
                    }
                }
                else if (phase == 4 && menu == currentMenu && System.Environment.TickCount64 >= secondClickAt)
                {
                    phase = 5;
                    noMenuCheckAt = System.Environment.TickCount64 + 200;
                    mouse_event(8, 0, 0, 0, System.UIntPtr.Zero);
                    mouse_event(16, 0, 0, 0, System.UIntPtr.Zero);
                }
                else if (phase == 6)
                {
                    AdditionalMenuWasBase[AdditionalMenuCount++] = isBase;
                    phase = 2;
                    PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
                }
                return false;
            }, System.IntPtr.Zero);
            if (phase == 5 && !popupFound && System.Environment.TickCount64 >= noMenuCheckAt)
            {
                NoMenuObserved = true;
                if (AdditionalClicks > 1)
                {
                    phase = 6;
                    mouse_event(8, 0, 0, 0, System.UIntPtr.Zero);
                    mouse_event(16, 0, 0, 0, System.UIntPtr.Zero);
                }
                else phase = 2;
            }
            if (System.Threading.Interlocked.Increment(ref ticks) > 300)
                PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
        }
        finally { System.Threading.Volatile.Write(ref checking, 0); }
    }

    public void Dispose() => timer.Dispose();
}

public sealed class SutShellUiProbe
{
    public object List;
    public object Window;
    public object ContentView;
    public bool Startup;
    public bool AwaitAll;
    public object Frame;
    public bool Ready;
    public string Error;
    private string state = "no rows";
    private int phase;
    private readonly System.DateTime deadline = System.DateTime.UtcNow.AddSeconds(20);

    private static object Property(object target, string name) => target.GetType().GetProperty(name).GetValue(target);

    private static bool ContainsImage(object visual, object source)
    {
        var image = visual.GetType().GetProperty("Source");
        if (image != null && object.ReferenceEquals(image.GetValue(visual), source)) return true;
        var helper = System.Type.GetType("System.Windows.Media.VisualTreeHelper, PresentationCore", true);
        var count = (int)helper.GetMethod("GetChildrenCount").Invoke(null, new[] { visual });
        for (var index = 0; index < count; index++)
            if (ContainsImage(helper.GetMethod("GetChild").Invoke(null, new[] { visual, (object)index }), source)) return true;
        return false;
    }

    private static object FindContentView(object visual)
    {
        if (visual.GetType().FullName == "SUTWinExplorer.ContentView") return visual;
        var helper = System.Type.GetType("System.Windows.Media.VisualTreeHelper, PresentationCore", true);
        var count = (int)helper.GetMethod("GetChildrenCount").Invoke(null, new[] { visual });
        for (var index = 0; index < count; index++)
        {
            var result = FindContentView(helper.GetMethod("GetChild").Invoke(null, new[] { visual, (object)index }));
            if (result != null) return result;
        }
        return null;
    }

    public void Tick(object sender, System.EventArgs args)
    {
        try
        {
            if (List == null && Window != null)
            {
                var content = FindContentView(Window);
                if (content != null) { ContentView = content; List = content.GetType().GetMethod("FindName").Invoke(content, new object[] { "FileList" }); }
            }
            if (List == null)
            {
                if (System.DateTime.UtcNow < deadline) return;
                Error = "Timed out waiting for BROWSE ContentView.";
                Frame.GetType().GetProperty("Continue").SetValue(Frame, false);
                return;
            }
            var items = Property(List, "Items");
            var count = (int)Property(items, "Count");
            if (AwaitAll && count > 0)
            {
                var loaded = 0;
                for (var index = 0; index < count; index++)
                {
                    var item = items.GetType().GetProperty("Item", new[] { typeof(int) }).GetValue(items, new object[] { index });
                    if (Property(item, "Entry") != null) loaded++;
                }
                state = "loaded=" + loaded + "/" + count;
                if (loaded == count) Ready = true;
                if (!Ready && System.DateTime.UtcNow < deadline) return;
                if (!Ready) Error = "Timed out waiting for background packages: " + state;
                Frame.GetType().GetProperty("Continue").SetValue(Frame, false);
                return;
            }
            if (count > 0)
            {
                var index = phase == 0 ? 0 : count - 1;
                var row = items.GetType().GetProperty("Item", new[] { typeof(int) }).GetValue(items, new object[] { index });
                var entry = Property(row, "Entry");
                var failed = row.GetType().GetProperty("Failed", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).GetValue(row);
                state = "count=" + count + ", entry=" + (entry != null) + ", failed=" + failed;
                if (entry != null && Property(entry, "Icons") is object icons)
                {
                    var generator = Property(List, "ItemContainerGenerator");
                    var container = generator.GetType().GetMethod("ContainerFromIndex").Invoke(generator, new object[] { index });
                    state += ", icons=true, container=" + (container != null);
                    if (container != null && ContainsImage(container, Property(icons, "BaseIcon")))
                    {
                        if (Startup) Ready = true;
                        else if (phase == 0)
                        {
                            var last = items.GetType().GetProperty("Item", new[] { typeof(int) }).GetValue(items, new object[] { count - 1 });
                            phase = 1;
                            List.GetType().GetMethod("ScrollIntoView", new[] { typeof(object) }).Invoke(List, new[] { last });
                        }
                        else Ready = true;
                    }
                }
            }
            if (!Ready && System.DateTime.UtcNow < deadline) return;
            if (!Ready) Error = "Timed out waiting for the visible row and rendered icon in phase " + phase + ": " + state;
        }
        catch (System.Exception exception)
        {
            Error = exception.ToString();
        }
        Frame.GetType().GetProperty("Continue").SetValue(Frame, false);
    }
}

public static class SutShellTestTypeName
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct ShellFileInfo
    {
        public System.IntPtr Icon;
        public int IconIndex;
        public uint Attributes;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern System.IntPtr SHGetFileInfo(string path, uint attributes, ref ShellFileInfo info, uint size, uint flags);

    public static string Get(string path)
    {
        var info = new ShellFileInfo();
        if (SHGetFileInfo(path, 0, ref info, (uint)System.Runtime.InteropServices.Marshal.SizeOf<ShellFileInfo>(), 0x400) == System.IntPtr.Zero)
            throw new System.InvalidOperationException("Shell type lookup failed.");
        return info.TypeName;
    }
}
'@

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Test-BaseMenu($probe) {
    $probe.ItemCount -ge 5 -and $probe.CommandIds[0] -eq (Get-ActionCommandId 'Properties') -and $probe.CommandIds[2] -eq (Get-ActionCommandId 'NameClipboardCopy')
}
$standardActionIds = @('Properties', 'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'ItemClipboardPaste', 'LinkMarkItem', 'LinkAbort', 'LinkExecute', 'CopyMarkItem', 'CopyAbort', 'CopyExecute', 'MoveMarkItem', 'MoveAbort', 'MoveExecute', 'Rename', 'Delete')
function Get-ActionCommandId([string] $id, [string[]] $actionOrder = $menuActionOrder) {
    $index = [Array]::IndexOf($actionOrder, $id)
    if ($index -lt 0) { throw "Unknown menu action: $id" }
    [uint] (0x8000 + $index)
}
function Get-MenuActionIndex($probe, [string] $id) {
    [Array]::IndexOf($probe.CommandIds, (Get-ActionCommandId $id))
}

function Get-ShellMenuVerbs($instance) {
    $instanceFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $menu = $instance.GetType().GetField('_menu', $instanceFlags).GetValue($instance)
    $context = $instance.GetType().GetField('_contextMenu', $instanceFlags).GetValue($instance)
    $getVerb = $menuType.GetMethod('GetCommandVerb', [System.Reflection.BindingFlags]'Static,NonPublic')
    for ($index = 0; $index -lt [SutShellMenuProbe]::GetMenuItemCount($menu); $index++) {
        $command = [SutShellMenuProbe]::GetMenuItemID($menu, $index)
        if ($command -ge 1 -and $command -le 0x7fff) {
            $verb = $getVerb.Invoke($null, [object[]] @($context, [uint32] ($command - 1)))
            if ($verb) { $verb }
        }
    }
}

function Find-VisualName($parent, [string] $name) {
    for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
        if ($child -is [System.Windows.FrameworkElement] -and $child.Name -eq $name) { return $child }
        $match = Find-VisualName $child $name
        if ($null -ne $match) { return $match }
    }
    return $null
}

function Find-VisualType($parent, [type] $type) {
    for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
        if ($type.IsInstanceOfType($child)) { return $child }
        $match = Find-VisualType $child $type
        if ($null -ne $match) { return $match }
    }
    return $null
}

function Find-TreeEntry($entry, [string] $path) {
    if ($entry.Path -eq $path) { return $entry }
    foreach ($child in $entry.Children) {
        $found = Find-TreeEntry $child $path
        if ($null -ne $found) { return $found }
    }
    return $null
}

function Find-TreeContainer($control, $entry) {
    foreach ($item in $control.Items) {
        $container = $control.ItemContainerGenerator.ContainerFromItem($item)
        if ($null -eq $container) { continue }
        if ([object]::ReferenceEquals($item, $entry)) { return $container }
        $found = Find-TreeContainer $container $entry
        if ($null -ne $found) { return $found }
    }
    return $null
}

function Find-ListBackgroundPoint($control) {
    for ($y = [int] $control.ActualHeight - 8; $y -ge 8; $y -= 8) {
        $point = [System.Windows.Point]::new(10, $y)
        $source = $control.InputHitTest($point)
        if ($null -eq $source) { continue }
        $blocked = $false
        while ($null -ne $source -and -not [object]::ReferenceEquals($source, $control)) {
            if ($source -is [System.Windows.Controls.ListViewItem] -or
                $source -is [System.Windows.Controls.Primitives.ScrollBar] -or
                $source -is [System.Windows.Controls.GridViewColumnHeader]) { $blocked = $true; break }
            $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source)
        }
        if (-not $blocked -and $null -ne $source) { return $control.PointToScreen($point) }
    }
    throw "Could not find a clickable list background: $($control.Name)."
}

function Wait-ListCount($control, [int] $expectedCount) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $timer.add_Tick({ if ($control.Items.Count -eq $expectedCount -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    Assert-True ($control.Items.Count -eq $expectedCount) "The list did not reach $expectedCount items."
    $control.UpdateLayout()
}

function Start-NewDialogProbe([string] $mode) {
    $result = [pscustomobject] @{ Seen = $false; Error = $null; ExtensionChanged = $false; MismatchRejected = $false; ListCorrect = $false; ListDetails = ''; FocusCorrect = $false; Timer = $null }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $result.Timer = $timer
    $timer.add_Tick({
        $dialog = @([System.Windows.Application]::Current.Windows | Where-Object { $_.GetType().FullName -eq 'SUTWinExplorer.NewItemDialog' }) | Select-Object -First 1
        if ($null -eq $dialog) { return }
        $timer.Stop()
        $result.Seen = $true
        try {
            $picker = Find-VisualName $dialog 'TypePicker'
            $editor = Find-VisualName $dialog 'NameEditor'
            if ($mode -eq 'Cancel') {
                $picker.UpdateLayout()
                $firstItem = $picker.ItemContainerGenerator.ContainerFromIndex(0)
                $secondItem = $picker.ItemContainerGenerator.ContainerFromIndex(1)
                $firstIcon = if ($null -ne $firstItem) { Find-VisualType $firstItem ([System.Windows.Controls.Image]) } else { $null }
                $secondIcon = if ($null -ne $secondItem) { Find-VisualType $secondItem ([System.Windows.Controls.Image]) } else { $null }
                $divider = $picker.ItemContainerGenerator.ContainerFromIndex(2)
                $dividerLine = Find-VisualType $divider ([System.Windows.Controls.Border])
                $dividerCorrect = $divider -is [System.Windows.Controls.ListBoxItem] -and -not $divider.IsEnabled -and
                    -not $divider.Focusable -and $divider.ActualHeight -gt $dividerLine.ActualHeight -and $dividerLine.ActualHeight -eq 1
                $baseItems = @($picker.Items)
                $initialSelection = $picker.SelectedIndex
                $picker.ItemsSource = @($baseItems + @($baseItems[0]) * 12)
                $picker.UpdateLayout()
                $scroll = Find-VisualType $picker ([System.Windows.Controls.ScrollViewer])
                $scroll.ScrollToEnd()
                $picker.UpdateLayout()
                $result.ListDetails = "first=$($baseItems[0].Name), second=$($baseItems[1].Name), selected=$initialSelection, divider=$dividerCorrect, height=$($picker.ActualHeight), firstIcon=$($null -ne $firstIcon.Source), secondIcon=$($null -ne $secondIcon.Source), offset=$($scroll.VerticalOffset), count=$($picker.Items.Count)"
                $result.ListCorrect = $picker -is [System.Windows.Controls.ListBox] -and $baseItems[0].Kind.ToString() -eq 'Directory' -and
                    $baseItems[0].Name -eq 'Directory' -and $baseItems[1].Name -eq 'Textfile' -and $baseItems[1].Extension -eq '.txt' -and
                    $initialSelection -eq 1 -and $dividerCorrect -and
                    $picker.ActualHeight -le 262 -and $null -ne $firstIcon.Source -and $null -ne $secondIcon.Source -and
                    $null -ne $scroll -and $scroll.VerticalOffset -gt 0
                $dialog.DialogResult = $false
                return
            }
            if ($mode -eq 'Windows') {
                (Find-VisualName $dialog 'WindowsButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                return
            }
            if ($mode -eq 'CancelFolder') {
                $picker.SelectedItem = @($picker.Items | Where-Object { $null -ne $_.Kind -and $_.Kind.ToString() -eq 'Directory' })[0]
                $dialog.DialogResult = $false
                return
            }
            if ($mode -eq 'Focus') {
                $originalCursor = [SutShellRightClickProbe]::CursorPosition()
                try {
                    $dialog.Left = 30
                    $dialog.Top = 30
                    $null = $dialog.Activate()
                    $dialog.UpdateLayout()
                    $focused = $true
                    foreach ($index in @(0, 1, 1)) {
                        $item = $picker.ItemContainerGenerator.ContainerFromIndex($index)
                        $point = $item.PointToScreen([System.Windows.Point]::new(30, $item.ActualHeight / 2))
                        [SutShellMenuProbe]::LeftClickAt([int] $point.X, [int] $point.Y)
                        $frame = [System.Windows.Threading.DispatcherFrame]::new()
                        $wait = [System.Windows.Threading.DispatcherTimer]::new()
                        $wait.Interval = [TimeSpan]::FromMilliseconds(150)
                        $wait.add_Tick({ $frame.Continue = $false }.GetNewClosure())
                        $wait.Start()
                        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $wait.Stop() }
                        $focused = $focused -and $picker.SelectedIndex -eq $index -and $editor.IsKeyboardFocused
                    }
                    $divider = $picker.ItemContainerGenerator.ContainerFromIndex(2)
                    $point = $divider.PointToScreen([System.Windows.Point]::new(30, $divider.ActualHeight / 2))
                    [SutShellMenuProbe]::LeftClickAt([int] $point.X, [int] $point.Y)
                    $frame = [System.Windows.Threading.DispatcherFrame]::new()
                    $wait = [System.Windows.Threading.DispatcherTimer]::new()
                    $wait.Interval = [TimeSpan]::FromMilliseconds(150)
                    $wait.add_Tick({ $frame.Continue = $false }.GetNewClosure())
                    $wait.Start()
                    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $wait.Stop() }
                    $focused = $focused -and $picker.SelectedIndex -eq 1
                    $result.FocusCorrect = $focused
                } finally { [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1]) }
                $dialog.DialogResult = $false
                return
            }
            if ($mode -in @('Text', 'Mismatch', 'HiddenText', 'ScrollText')) {
                $textType = @($picker.Items | Where-Object { $_.Extension -eq '.txt' })[0]
                $folderType = @($picker.Items | Where-Object { $null -ne $_.Kind -and $_.Kind.ToString() -eq 'Directory' })[0]
                $picker.SelectedItem = $folderType
                $editor.Text = 'chosen-name'
                $picker.SelectedItem = $textType
                $changed = $editor.Text -ceq 'chosen-name.txt'
                $picker.SelectedItem = $folderType
                $changed = $changed -and $editor.Text -ceq 'chosen-name'
                $picker.SelectedItem = $textType
                $changed = $changed -and $editor.Text -ceq 'chosen-name.txt'
                $editor.Text = 'custom.md'
                $picker.SelectedItem = $folderType
                $picker.SelectedItem = $textType
                $result.ExtensionChanged = $changed -and $editor.Text -ceq 'custom.md'
                if ($mode -eq 'Mismatch') {
                    $confirmProbe = [SutShellExtensionConfirmProbe]::new()
                    try {
                        (Find-VisualName $dialog 'CreateButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                        $target = $dialog.GetType().GetField('_directory', [System.Reflection.BindingFlags]'Instance,NonPublic').GetValue($dialog)
                        $result.MismatchRejected = $confirmProbe.Seen -and $dialog.IsVisible -and -not [IO.File]::Exists((Join-Path $target 'custom.md'))
                    } finally { $confirmProbe.Dispose() }
                }
                $editor.Text = if ($mode -eq 'HiddenText') { '.chosen-hidden.txt' } elseif ($mode -eq 'ScrollText') { 'zzzz-last.txt' } else { 'chosen-name.txt' }
            } else {
                $picker.SelectedItem = @($picker.Items | Where-Object { $null -ne $_.Kind -and $_.Kind.ToString() -eq 'Directory' })[0]
                $editor.Text = 'chosen-folder'
            }
            (Find-VisualName $dialog 'CreateButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        } catch { $result.Error = $_.Exception.ToString(); $dialog.Close() }
    }.GetNewClosure())
    $timer.Start()
    return $result
}

function Test-TransferActionExecution($assembly, [string] $operation, [string] $source, [string] $destination) {
    $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
    [System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
    $application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
    $application.InitializeComponent()
    $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $previousContext = [System.Threading.SynchronizationContext]::Current
    $viewFlags = [Reflection.BindingFlags]'Instance,NonPublic'
    try {
        [System.Threading.SynchronizationContext]::SetSynchronizationContext(
            [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
        foreach ($location in @('ContentView', 'Pathview')) {
            $view = $null
            $window = [System.Windows.Window]::new()
            try {
                if ($location -eq 'ContentView') {
                    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
                    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $false))
                    $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $destination))
                } else {
                    $view = $assembly.GetType('SUTWinExplorer.Pathview', $true).GetConstructors()[0].Invoke([object[]] @([string] $destination, $false, $null, $null, $null, $null))
                }
                $window.ShowInTaskbar = $false
                $window.Left = -20000
                $window.Top = -20000
                $window.Content = $view
                $window.Show()
                $file = Join-Path $source "execute-$operation-$location.txt"
                [IO.File]::WriteAllText($file, $location)
                $workflow.Prepare([string[]] @($file))
                if ($location -eq 'ContentView') {
                    $view.FindName("${operation}ExecuteButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                } else {
                    $null = $view.GetType().GetMethod('ExecuteDirectoryMenuAction', $viewFlags).Invoke($view, [object[]] @([string] "${operation}Execute", $null))
                }
                $targetName = [IO.Path]::GetFileName($file)
                if ($operation -eq 'Link') { $targetName += ' - Shortcut.lnk' }
                $target = Join-Path $destination $targetName
                Assert-True (-not $workflow.IsPrepared -and [IO.File]::Exists($target) -and
                    ([IO.File]::Exists($file) -eq ($operation -ne 'Move'))) "$location $operation execute did not complete with the expected source and destination."

                $missing = Join-Path $source "missing-$operation-$location.txt"
                $workflow.Prepare([string[]] @($missing))
                $errorProbe = [SutShellPropertiesProbe]::new('Operation failed')
                try {
                    if ($location -eq 'ContentView') {
                        $view.FindName("${operation}ExecuteButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                    } else {
                        $null = $view.GetType().GetMethod('ExecuteDirectoryMenuAction', $viewFlags).Invoke($view, [object[]] @([string] "${operation}Execute", $null))
                    }
                    Assert-True ($errorProbe.Opened -and $workflow.IsPrepared -and @($workflow.PreparedPaths)[0] -ceq $missing) "$location $operation failure did not report the error and retain the prepared source."
                } finally { $errorProbe.Dispose(); $workflow.Abort() }
            } finally {
                $workflow.Abort()
                if ($location -eq 'Pathview' -and $null -ne $view) { $view.GetType().GetMethod('Close', $viewFlags).Invoke($view, @()) }
                $window.Close()
            }
        }
    } finally {
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
        $application.Shutdown()
    }
}

