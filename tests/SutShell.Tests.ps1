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
    public void OnFolderRenamed(string oldPath, string newPath) { OldPath = oldPath; NewPath = newPath; }
}

public sealed class SutShellMenuProbe : System.IDisposable
{
    private delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumWindowProc callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(System.IntPtr window, System.Text.StringBuilder name, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr SendMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int GetMenuItemCount(System.IntPtr menu);
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
    public int SelectIndex = -1;
    public string SelectLabel;
    public bool SelectWithRightButton;
    public string AlterSubmenu;
    public bool EmptySubmenu;
    public bool SubmenuAltered;

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
            for (var index = 0; index < ItemCount; index++)
            {
                var text = new System.Text.StringBuilder(512);
                GetMenuString(menu, (uint)index, text, text.Capacity, 0x400);
                Items[index] = text.ToString();
                States[index] = GetMenuState(menu, (uint)index, 0x400);
            }
            if (SelectLabel != null) SelectIndex = System.Array.IndexOf(Items, SelectLabel);
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
                popupFound = true;
                var menu = SendMessage(window, 0x01E1, System.IntPtr.Zero, System.IntPtr.Zero);
                var label = new System.Text.StringBuilder(512);
                GetMenuString(menu, 1, label, label.Capacity, 0x400);
                if (phase == 0 && ObservedFirstLabel == null) ObservedFirstLabel = label.ToString();
                if (phase == 0 && label.ToString() == "Path get")
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
                    SecondWasBase = label.ToString() == "Path get";
                    SecondItems = new string[GetMenuItemCount(menu)];
                    for (var index = 0; index < SecondItems.Length; index++)
                    {
                        var itemLabel = new System.Text.StringBuilder(512);
                        GetMenuString(menu, (uint)index, itemLabel, itemLabel.Capacity, 0x400);
                        SecondItems[index] = itemLabel.ToString();
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
                    AdditionalMenuWasBase[AdditionalMenuCount++] = label.ToString() == "Path get";
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

function Find-VisualName($parent, [string] $name) {
    for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
        if ($child -is [System.Windows.FrameworkElement] -and $child.Name -eq $name) { return $child }
        $match = Find-VisualName $child $name
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

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [System.Reflection.BindingFlags]'Static,NonPublic'
$menuType = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
$whitelistJson = '{"_type":"directoryMenuWhitelist","extensions":[{"_type":"shellExtension","name":"test","verbs":["TestVerb"],"clsids":["{11111111-2222-3333-4444-555555555555}"]}]}'
$whitelistDocument = [System.Text.Json.JsonDocument]::Parse($whitelistJson)
try {
    $parsedWhitelist = $menuType.GetMethod('ParseDirectoryWhitelist', $flags).Invoke($null, @($whitelistDocument))
    $parsedVerbs = $parsedWhitelist.GetType().GetProperty('Verbs').GetValue($parsedWhitelist)
    $parsedHandlers = $parsedWhitelist.GetType().GetProperty('HandlerIds').GetValue($parsedWhitelist)
    $testHandler = [guid] '{11111111-2222-3333-4444-555555555555}'
    $emptyHandlers = [System.Collections.Generic.HashSet[guid]]::new()
    $eligibleHandler = $menuType.GetMethod('IsEligibleDirectoryHandler', $flags)
    Assert-True ($parsedVerbs.Contains('testverb') -and $parsedHandlers.Contains($testHandler) -and
        $eligibleHandler.Invoke($null, [object[]] @($testHandler, $emptyHandlers, $parsedHandlers)) -and
        -not $eligibleHandler.Invoke($null, [object[]] @([guid]::NewGuid(), $emptyHandlers, $parsedHandlers))) 'Directory whitelist parsing or handler eligibility failed.'
} finally { $whitelistDocument.Dispose() }
$ambiguousMenu = [SutShellMenuProbe]::CreateAmbiguousMenu()
try {
    $labels = $menuType.GetMethod('CollectMenuLabels', $flags).Invoke($null, @($ambiguousMenu))
    $wildcardVerbs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directoryOnlyVerbs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $wildcardVerbs.Add('SharedVerb')
    $null = $directoryOnlyVerbs.Add('DirectoryOnlyVerb')
    $wildcardMatch = $menuType.GetMethod('IsWildcardDirectoryMatch', $flags)
    Assert-True ($labels.Count -eq 2 -and $labels.Contains("item`0Shared") -and $labels.Contains("submenu`0Lazy") -and
        $wildcardMatch.Invoke($null, [object[]] @('sharedverb', $null, $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        $wildcardMatch.Invoke($null, [object[]] @($null, "item`0Shared", $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        $wildcardMatch.Invoke($null, [object[]] @($null, "submenu`0Lazy", $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        -not $wildcardMatch.Invoke($null, [object[]] @('DirectoryOnlyVerb', "item`0Shared", $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        -not $wildcardMatch.Invoke($null, [object[]] @($null, "item`0Lazy", $wildcardVerbs, $directoryOnlyVerbs, $labels))) 'Ambiguous wildcard menu matching did not preserve the intended criteria.'
} finally { [void] [SutShellMenuProbe]::DestroyMenu($ambiguousMenu) }
$lazyBackgroundMenu = [SutShellMenuProbe]::CreateLazyBackgroundMenu()
try {
    $null = $menuType.GetMethod('RemoveBackgroundViewMenus', $flags).Invoke($null, [object[]] @($lazyBackgroundMenu, $null))
    $remainingLabels = $menuType.GetMethod('CollectMenuLabels', $flags).Invoke($null, @($lazyBackgroundMenu))
    Assert-True ($remainingLabels.Count -eq 1) 'Lazy Sort and Group submenus were not removed or the New submenu was removed.'
} finally { [void] [SutShellMenuProbe]::DestroyMenu($lazyBackgroundMenu) }
$openDirectory = $shell.GetMethod('OpenDirectoryAsync', $flags)
$openSortedDirectory = $shell.GetMethod('OpenSortedDirectoryAsync', $flags)
$openCachedDirectory = $shell.GetMethod('OpenCachedDirectoryAsync', $flags)
$cacheType = $assembly.GetType('SUTWinExplorer.DirectoryDataCache', $true)
$sortPairType = $assembly.GetType('SUTWinExplorer.DirectorySortPair', $true)
$sortColumnType = $assembly.GetType('SUTWinExplorer.DirectorySortColumn', $true)
$sortCriterionType = $assembly.GetType('SUTWinExplorer.DirectorySortCriterion', $true)
$sortStateType = $assembly.GetType('SUTWinExplorer.DirectorySortState', $true)
$getRange = $shell.GetMethod('GetDirectoryRangeAsync', $flags)
$ensureAccessible = $shell.GetMethod('EnsureDirectoryAccessible', $flags)
$observe = $shell.GetMethod('ObserveDirectories', $flags)
$rename = $shell.GetMethod('Rename', $flags)
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-shell-test-' + [guid]::NewGuid().ToString('N'))

try {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'hello')
    [System.IO.File]::SetLastWriteTime((Join-Path $directory 'notes.txt'), [datetime]::new(2026, 11, 2, 9, 5, 0))
    [System.IO.File]::WriteAllText((Join-Path $directory '.internal'), 'hidden')
    [System.IO.File]::WriteAllText((Join-Path $directory 'unknown.zzzunknown'), 'unknown')
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'empty.bin'), [byte[]]::new(0))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'exact.bin'), [byte[]]::new(1024))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'over.bin'), [byte[]]::new(1025))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'large.bin'), [byte[]]::new(1048576))
    foreach ($badName in @('', '..', 'invalid/name', 'exact.bin')) {
        $failed = $false
        try { $null = $rename.Invoke($null, [object[]] @([string] (Join-Path $directory 'notes.txt'), [string] $badName, [IntPtr]::Zero)) } catch {
            $expectedType = if ($badName -eq 'exact.bin') { [System.IO.IOException] } else { [System.ArgumentException] }
            $failed = $expectedType.IsInstanceOfType($_.Exception.InnerException)
        }
        Assert-True $failed "Invalid or conflicting rename was accepted: $badName"
    }
    $casePath = Join-Path $directory 'case-only.tmp'
    [System.IO.File]::WriteAllText($casePath, 'case')
    $caseResult = $rename.Invoke($null, [object[]] @([string] $casePath, [string] 'CASE-only.tmp', [IntPtr]::Zero))
    $caseNames = @([System.IO.Directory]::EnumerateFileSystemEntries($directory) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    Assert-True ($caseResult -ceq (Join-Path $directory 'CASE-only.tmp') -and $caseNames -ccontains 'CASE-only.tmp') 'Case-only rename failed.'
    [System.IO.File]::Delete($caseResult)

    $sortDirectory = Join-Path $directory 'sorting-fixture'
    try {
        [System.IO.Directory]::CreateDirectory((Join-Path $sortDirectory 'Z-folder')) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path $sortDirectory 'A-folder')) | Out-Null
        foreach ($case in @(@('a.bin', 2, 1), @('b.bin', 2, 2), @('c.txt', 10, 1), @('d.txt', 1, 2))) {
            $path = Join-Path $sortDirectory $case[0]
            [System.IO.File]::WriteAllBytes($path, [byte[]]::new($case[1]))
            [System.IO.File]::SetLastWriteTime($path, [datetime]::new(2026, 1, $case[2]))
        }
        $sortState = [Activator]::CreateInstance($sortStateType, $true)
        $instanceFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $updateSort = $sortStateType.GetMethod('Update', $instanceFlags)
        $pairsProperty = $sortStateType.GetProperty('Pairs', $instanceFlags)
        function New-SortPair([string] $column, [string] $criterion) {
            [Activator]::CreateInstance($sortPairType, [object[]] @(
                [Enum]::Parse($sortColumnType, $column), [Enum]::Parse($sortCriterionType, $criterion)))
        }
        function Set-TestSort($state, [object[]] $pairs) {
            $array = [Array]::CreateInstance($sortPairType, $pairs.Count)
            for ($index = 0; $index -lt $pairs.Count; $index++) { $array.SetValue($pairs[$index], $index) }
            $null = $updateSort.Invoke($state, [object[]] @(,$array))
        }
        function Get-SortedNames($state) {
            $result = $openSortedDirectory.Invoke($null, [object[]] @([string] $sortDirectory, [bool] $true,
                [bool] $false, [string] '', $state, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
            $entries = $getRange.Invoke($null, [object[]] @($result, [int] 0, [int] $result.Count,
                [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
            return ,@($entries | ForEach-Object { [System.IO.Path]::GetFileName($_.FullPath) })
        }
        Set-TestSort $sortState @((New-SortPair 'Name' 'Descending'))
        Assert-True ((Get-SortedNames $sortState) -join ',' -ceq 'Z-folder,A-folder,d.txt,c.txt,b.bin,a.bin') 'Name descending or directory grouping failed.'
        Set-TestSort $sortState @((New-SortPair 'Size' 'Ascending'))
        Assert-True ((Get-SortedNames $sortState) -join ',' -ceq 'Z-folder,A-folder,d.txt,b.bin,a.bin,c.txt') 'Numeric size sort or secondary name sort failed.'
        Set-TestSort $sortState @((New-SortPair 'Size' 'Descending'))
        Assert-True ((Get-SortedNames $sortState) -join ',' -ceq 'Z-folder,A-folder,c.txt,b.bin,a.bin,d.txt') 'Size direction change or sort history failed.'
        Set-TestSort $sortState @((New-SortPair 'DateModified' 'Ascending'), (New-SortPair 'Name' 'Ascending'))
        Assert-True ((Get-SortedNames $sortState)[2..5] -join ',' -ceq 'a.bin,c.txt,b.bin,d.txt') 'Multi-column update or date sorting failed.'
        $history = @($pairsProperty.GetValue($sortState))
        Assert-True (($history.Column -join ',') -ceq 'DateModified,Name,Size') 'Updating a sort column did not move it to the front without duplication.'
        $invalid = $false
        try { Set-TestSort $sortState @((New-SortPair 'Name' 'Ascending'), (New-SortPair 'Name' 'Descending')) } catch { $invalid = $true }
        Assert-True ($invalid -and (@($pairsProperty.GetValue($sortState)).Column -join ',') -ceq 'DateModified,Name,Size') 'Duplicate columns were accepted or changed sort history.'
        foreach ($column in @('Type', 'MediaType')) {
            Set-TestSort $sortState @((New-SortPair $column 'Ascending'))
            $sortedNames = Get-SortedNames $sortState
            Assert-True ($sortedNames.Count -eq 6 -and $sortedNames[0] -in @('A-folder', 'Z-folder') -and $sortedNames[1] -in @('A-folder', 'Z-folder')) "$column sort lost items or directory grouping."
            $mediaMap = $assembly.GetType('SUTWinExplorer.MediaTypeMap', $true)
            $previous = $null
            foreach ($name in $sortedNames[2..5]) {
                $path = Join-Path $sortDirectory $name
                $key = if ($column -eq 'Type') { [SutShellTestTypeName]::Get($path) } else {
                    $mediaType = $mediaMap.GetMethod('GetMediaType').Invoke($null, [object[]] @([string] $path, [bool] $false))
                    if ([int] $mediaType -eq 0) { [int]::MaxValue } else { [int] $mediaType }
                }
                $inOrder = if ($null -eq $previous) { $true } elseif ($column -eq 'Type') {
                    [StringComparer]::CurrentCultureIgnoreCase.Compare($previous, $key) -le 0
                } else { $previous -le $key }
                Assert-True $inOrder "$column keys are not in ascending order."
                $previous = $key
            }
        }
        [System.IO.File]::WriteAllBytes((Join-Path $sortDirectory 'picture.png'), [byte[]]::new(0))
        [System.IO.File]::WriteAllBytes((Join-Path $sortDirectory 'archive.zip'), [byte[]]::new(0))
        $mediaOrder = [Activator]::CreateInstance($sortStateType, $true)
        Set-TestSort $mediaOrder @((New-SortPair 'MediaType' 'Ascending'))
        $mediaNames = Get-SortedNames $mediaOrder
        Assert-True ([Array]::IndexOf($mediaNames, 'picture.png') -lt [Array]::IndexOf($mediaNames, 'archive.zip')) 'Media types are not sorted by enum order.'
        Assert-True (($mediaNames[2..7] -join ',') -ceq 'c.txt,d.txt,picture.png,archive.zip,a.bin,b.bin') 'Files without a media type must follow known media types in ascending order.'
        Set-TestSort $mediaOrder @((New-SortPair 'MediaType' 'Descending'))
        $mediaNames = Get-SortedNames $mediaOrder
        Assert-True (($mediaNames[2..7] -join ',') -ceq 'archive.zip,picture.png,c.txt,d.txt,a.bin,b.bin') 'Files without a media type must follow known media types in descending order.'
        Set-TestSort $mediaOrder @((New-SortPair 'Size' 'Ascending'), (New-SortPair 'MediaType' 'Ascending'))
        $mediaNames = Get-SortedNames $mediaOrder
        Assert-True (($mediaNames[2..7] -join ',') -ceq 'picture.png,archive.zip,d.txt,a.bin,b.bin,c.txt') 'A secondary media-type sort must not override the primary size sort.'
        [System.IO.File]::Delete((Join-Path $sortDirectory 'picture.png'))
        [System.IO.File]::Delete((Join-Path $sortDirectory 'archive.zip'))
        $cache = [Activator]::CreateInstance($cacheType, $true)
        $cacheSort = [Activator]::CreateInstance($sortStateType, $true)
        function Get-CachedSnapshot([string] $pattern) {
            $openCachedDirectory.Invoke($null, [object[]] @([string] $sortDirectory, [bool] $true, [bool] $false,
                [string] $pattern, $cacheSort, $cache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
        }
        function Get-SnapshotEntries($sourceSnapshot) {
            return ,@($getRange.Invoke($null, [object[]] @($sourceSnapshot, [int] 0, [int] $sourceSnapshot.Count,
                [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
        }
        $initialSnapshot = Get-CachedSnapshot ''
        $initialEntries = Get-SnapshotEntries $initialSnapshot
        $cachedFile = @($initialEntries | Where-Object { $_.FullPath -eq (Join-Path $sortDirectory 'a.bin') })[0]
        [System.IO.File]::WriteAllBytes((Join-Path $sortDirectory 'a.bin'), [byte[]]::new(2048))
        [System.IO.File]::WriteAllText((Join-Path $sortDirectory 'new-file.txt'), 'new')
        $filteredCache = Get-CachedSnapshot '*.txt'
        Assert-True ($filteredCache.Count -eq 2) 'A filter unexpectedly re-enumerated the directory.'
        Set-TestSort $cacheSort @((New-SortPair 'Size' 'Descending'))
        $reusedSnapshot = Get-CachedSnapshot ''
        $reusedEntries = Get-SnapshotEntries $reusedSnapshot
        $reusedFile = @($reusedEntries | Where-Object { $_.FullPath -eq $cachedFile.FullPath })[0]
        Assert-True ($reusedSnapshot.Count -eq 6 -and [object]::ReferenceEquals($cachedFile, $reusedFile) -and
            $reusedFile.SizeText -ceq $cachedFile.SizeText -and [object]::ReferenceEquals($reusedFile.Icons, $cachedFile.Icons)) 'Filtering or sorting discarded cached entry data.'
        foreach ($column in @('ShellIcon', 'Overlay')) {
            Set-TestSort $cacheSort @((New-SortPair $column 'Ascending'))
            $iconEntries = Get-SnapshotEntries (Get-CachedSnapshot '')
            $iconKeyName = if ($column -eq 'ShellIcon') { 'BaseIconIndex' } else { 'OverlaySlot' }
            $iconProperty = $assembly.GetType('SUTWinExplorer.ShellIconSet').GetProperty($iconKeyName, $instanceFlags)
            $previous = $null
            foreach ($entry in @($iconEntries | Where-Object { -not $_.IsDirectory })) {
                $key = if ($null -ne $entry.Icons) { $iconProperty.GetValue($entry.Icons) } else { $null }
                Assert-True ($null -eq $previous -or ($null -ne $key -and $previous -le $key)) "$column keys are not in ascending order."
                $previous = $key
            }
            Set-TestSort $cacheSort @((New-SortPair $column 'Descending'))
            $reverseEntries = Get-SnapshotEntries (Get-CachedSnapshot '')
            $previous = $null
            foreach ($entry in @($reverseEntries | Where-Object { -not $_.IsDirectory -and $null -ne $_.Icons })) {
                $key = $iconProperty.GetValue($entry.Icons)
                Assert-True ($null -eq $previous -or $previous -ge $key) "$column keys are not in descending order."
                $previous = $key
            }
        }
        $null = $cacheType.GetMethod('Invalidate', $instanceFlags).Invoke($cache, @())
        $refreshedSnapshot = Get-CachedSnapshot ''
        $refreshedEntries = Get-SnapshotEntries $refreshedSnapshot
        $refreshedFile = @($refreshedEntries | Where-Object { $_.FullPath -eq $cachedFile.FullPath })[0]
        Assert-True ($refreshedSnapshot.Count -eq 7 -and -not [object]::ReferenceEquals($cachedFile, $refreshedFile) -and
            $refreshedFile.SizeText -ceq ('{0:N0} KB' -f 2)) 'Invalidation did not refresh directory membership and metadata.'
        $freshCache = [Activator]::CreateInstance($cacheType, $true)
        $iconSort = [Activator]::CreateInstance($sortStateType, $true)
        Set-TestSort $iconSort @((New-SortPair 'ShellIcon' 'Ascending'))
        $firstIconSnapshot = $openCachedDirectory.Invoke($null, [object[]] @([string] $sortDirectory, [bool] $true,
            [bool] $false, [string] '', $iconSort, $freshCache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
        $itemsProperty = $firstIconSnapshot.GetType().GetProperty('Items', $instanceFlags)
        $firstIconItem = @($itemsProperty.GetValue($firstIconSnapshot))[0]
        $iconsProperty = $firstIconItem.GetType().GetProperty('Icons', $instanceFlags)
        $cachedIcon = $iconsProperty.GetValue($firstIconItem)
        $firstIconEntries = Get-SnapshotEntries $firstIconSnapshot
        Assert-True ($null -ne $cachedIcon -and [object]::ReferenceEquals($cachedIcon, $firstIconEntries[0].Icons)) 'Initial icon sort did not reuse its loaded icon for the row.'
    } finally { [System.IO.Directory]::Delete($sortDirectory, $true) }

    $snapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] '', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    Assert-True ($snapshot.Count -eq 8) 'Snapshot count is incorrect.'
    $all = @($getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] $snapshot.Count, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($all.Count -eq 8 -and $all[0].IsDirectory) 'Enumeration or directory-first ordering failed.'
    $notes = $all | Where-Object { $_.FullPath -eq (Join-Path $directory 'notes.txt') }
    Assert-True ($null -ne $notes.Icons -and $notes.MediaTypeName -eq 'lines-text' -and $null -ne $notes.MediaTypeIcon) 'Shell icon or media type is missing.'
    $previousCulture = [System.Globalization.CultureInfo]::CurrentCulture
    try {
        foreach ($cultureName in @('de-DE', 'en-US', 'th-TH')) {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($cultureName)
            Assert-True ($notes.ModifiedText -ceq '2026-11-02 09:05') "Date format changed under $cultureName."
        }
    } finally {
        [System.Globalization.CultureInfo]::CurrentCulture = $previousCulture
    }
    $unknown = $all | Where-Object { $_.FullPath -eq (Join-Path $directory 'unknown.zzzunknown') }
    Assert-True ($unknown.MediaTypeName -eq '' -and $null -eq $unknown.MediaTypeIcon) 'Unknown media type must be empty.'
    foreach ($entry in @($notes, $unknown, $all[0])) {
        Assert-True ($entry.Type -ceq [SutShellTestTypeName]::Get($entry.FullPath)) "Shell type mismatch for $($entry.FullPath)."
    }
    foreach ($case in @(@('empty.bin', 0), @('notes.txt', 1), @('exact.bin', 1), @('over.bin', 2), @('large.bin', 1024))) {
        $entry = $all | Where-Object { $_.FullPath -eq (Join-Path $directory $case[0]) }
        $expected = '{0:N0} KB' -f $case[1]
        Assert-True ($entry.SizeText -ceq $expected) "Size mismatch for $($case[0]): $($entry.SizeText)."
    }
    Assert-True ($all[0].SizeText -eq '') 'Directory size must be empty.'

    $page = @($getRange.Invoke($null, [object[]] @($snapshot, [int] 2, [int] 3, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($page.Count -eq 3 -and $page[0].FullPath -eq $all[2].FullPath -and $page[2].FullPath -eq $all[4].FullPath) 'Requested range does not match the snapshot order.'
    Assert-True ($notes.Icons.BaseIcon.IsFrozen -and $notes.MediaTypeIcon.IsFrozen) 'Complete row images must be frozen for the UI thread.'
    $parallelRanges = @(1..12 | ForEach-Object {
        $getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] $snapshot.Count, [Threading.CancellationToken]::None))
    })
    foreach ($task in $parallelRanges) {
        $parallelEntries = @($task.GetAwaiter().GetResult())
        Assert-True ($parallelEntries.Count -eq $snapshot.Count -and $null -ne $parallelEntries[0].Icons.BaseIcon) 'Concurrent range loading lost a Shell icon.'
    }
    $emptyPage = @($getRange.Invoke($null, [object[]] @($snapshot, [int] $snapshot.Count, [int] 0, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($emptyPage.Count -eq 0) 'Empty range must return no items.'
    $invalidRange = $false
    try { $null = $getRange.Invoke($null, [object[]] @($snapshot, [int] $snapshot.Count, [int] 1, [Threading.CancellationToken]::None)) } catch { $invalidRange = $true }
    Assert-True $invalidRange 'An out-of-bounds range was accepted.'
    [System.IO.File]::WriteAllText((Join-Path $directory 'vanish-a.txt'), 'gone')
    [System.IO.File]::WriteAllText((Join-Path $directory 'vanish-b.txt'), 'present')
    $changingSnapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] 'vanish-*.txt', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    [System.IO.File]::Delete((Join-Path $directory 'vanish-a.txt'))
    $changedPage = @($getRange.Invoke($null, [object[]] @($changingSnapshot, [int] 0, [int] 2, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($changingSnapshot.Count -eq 2 -and $changedPage.Count -eq 2 -and $changedPage[1].FullPath -eq (Join-Path $directory 'vanish-b.txt') -and $null -ne $changedPage[1].Icons) 'A vanished item changed the snapshot range or blocked its neighbor.'
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $cancellation.Cancel()
        $cancelledTask = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] '', $cancellation.Token))
        $cancelled = $false
        try { $null = $cancelledTask.GetAwaiter().GetResult() } catch { $cancelled = $true }
        Assert-True ($cancelled -and $cancelledTask.IsCanceled) 'Cancelled enumeration completed instead of cancelling.'
        $cancelledRange = $getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] 1, $cancellation.Token))
        $cancelled = $false
        try { $null = $cancelledRange.GetAwaiter().GetResult() } catch { $cancelled = $true }
        Assert-True ($cancelled -and $cancelledRange.IsCanceled) 'Cancelled range lookup completed instead of cancelling.'
    } finally {
        $cancellation.Dispose()
    }

    $filteredSnapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $false, [bool] $true, [string] 'notes*.TXT', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    $filtered = @($getRange.Invoke($null, [object[]] @($filteredSnapshot, [int] 0, [int] $filteredSnapshot.Count, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($filtered.Count -eq 1 -and $filtered[0].FullPath -eq $notes.FullPath) 'Directory, internal, or case-insensitive pattern filtering failed.'
    $top = $openDirectory.Invoke($null, [object[]] @([string] '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}', [bool] $false, [bool] $true, [string] '', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    Assert-True ($top.Count -eq 0) 'This PC must respect Hide directories.'

    $failed = $false
    try { $ensureAccessible.Invoke($null, @((Join-Path $directory 'missing'))) } catch { $failed = $true }
    Assert-True $failed 'A missing directory was accepted.'

    $signal = [SutShellTestSignal]::new()
    $callback = [Delegate]::CreateDelegate([Action], $signal, 'Notify')
    $observer = $observe.Invoke($null, @([string[]] @($directory), $callback))
    try {
        [System.IO.File]::WriteAllText((Join-Path $directory 'created.txt'), 'new')
        Assert-True ($signal.Event.WaitOne(5000)) 'External changes were not observed.'
    } finally {
        $observer.Dispose()
        $signal.Event.Dispose()
    }
    foreach ($index in 1..80) {
        [System.IO.File]::WriteAllText((Join-Path $directory ('visible-test-{0:D3}.txt' -f $index)), 'test')
    }
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'OtherFolder')) | Out-Null
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Width = 800
    $window.Height = 500
    $window.Content = $view
    $window.Show()
    try {
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $directory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $view.FindName('FileList')
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "ContentView did not load and render requested row packages: $($probe.Error)"
        $list = $view.FindName('FileList')
        $columns = $list.View.Columns
        Assert-True ($columns.Count -eq 7 -and $columns[3].Header.Tag -eq 'Name' -and
            $columns[3].Width -gt 80 -and $columns[4].Width -eq 130) 'Shell column order or name-column sizing is incorrect.'
        $iconSetType = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true)
        $iconSet = $iconSetType.GetConstructor([type[]] @([System.Windows.Media.ImageSource], [System.Windows.Media.ImageSource], [double])).Invoke(
            [object[]] @($notes.Icons.BaseIcon, $notes.MediaTypeIcon, [double] 0.55))
        $entryType = $assembly.GetType('SUTWinExplorer.FileEntry', $true)
        $testEntry = $entryType.GetConstructors()[0].Invoke([object[]] @(
            $notes.Name, $notes.FullPath, $notes.IsDirectory, $notes.Type, $notes.SizeText,
            $notes.Modified, $iconSet, $notes.MediaTypeIcon, $notes.MediaTypeName))
        $rowType = $assembly.GetType('SUTWinExplorer.DirectoryRow', $true)
        $testRow = [Activator]::CreateInstance($rowType, $true)
        $rowType.GetProperty('Entry').SetValue($testRow, $testEntry)
        $cells = foreach ($column in @($columns[1], $columns[2])) {
            $presenter = [System.Windows.Controls.ContentPresenter]::new()
            $presenter.Content = $testRow
            $presenter.ContentTemplate = $column.CellTemplate
            $presenter.Measure([System.Windows.Size]::new(16, 16))
            $presenter.Arrange([System.Windows.Rect]::new(0, 0, 16, 16))
            $presenter.UpdateLayout()
            [System.Windows.Media.VisualTreeHelper]::GetChild($presenter, 0)
        }
        $baseCell = $cells[0]
        $overlayCell = $cells[1]
        Assert-True ([object]::ReferenceEquals($baseCell.Source, $notes.Icons.BaseIcon) -and
            [object]::ReferenceEquals($overlayCell.Source, $notes.MediaTypeIcon) -and
            $baseCell.Opacity -eq 0.55 -and $overlayCell.Opacity -eq 0.55) "Shell column binding mismatch: base=$([object]::ReferenceEquals($baseCell.Source, $notes.Icons.BaseIcon)), overlay=$([object]::ReferenceEquals($overlayCell.Source, $notes.MediaTypeIcon)), opacity=$($baseCell.Opacity)/$($overlayCell.Opacity)."
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "Background packages did not complete: $($probe.Error)"
        $list.SelectedItems.Add($list.Items[0]) | Out-Null
        $list.SelectedItems.Add($list.Items[$list.Items.Count - 1]) | Out-Null
        $selectedEntries = @($list.SelectedItems | ForEach-Object { $_.Entry })
        $selectedPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($list.SelectedItems.Count -eq 2 -and $view.FindName('CopyGetButton').IsEnabled -and
            -not $view.FindName('PathGetButton').IsEnabled -and -not $view.FindName('RenameButton').IsEnabled) 'Multiple selection or its toolbar state failed.'
        $columns[5].Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($view.FindName('SizeSortIndicator').Visibility -eq 'Visible' -and
            $view.FindName('SizeSortIndicator').Text -ceq [string] [char] 0x25B2) 'Ascending size indicator was not shown.'
        $columns[5].Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($view.FindName('SizeSortIndicator').Text -ceq [string] [char] 0x25BC) 'Descending size indicator was not shown.'
        $columns[3].Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $list.UpdateLayout()
        Assert-True ($view.FindName('NameSortIndicator').Visibility -eq 'Visible' -and
            $view.FindName('SizeSortIndicator').Visibility -eq 'Collapsed' -and
            $view.FindName('NameSortIndicator').IsVisible -and $view.FindName('NameSortIndicator').ActualWidth -gt 0 -and
            $view.FindName('NameSortIndicator').Text -ceq [string] [char] 0x25B2) 'Primary sort indicator did not move to the new column.'
        $viewSort = $view.GetType().GetField('_sorting', $viewFlags).GetValue($view)
        Assert-True ((@($pairsProperty.GetValue($viewSort)).Column -join ',') -ceq 'Name,Size') 'Column clicks did not preserve the secondary sort.'
        foreach ($iconColumn in @(@(1, 'IconSortIndicator'), @(2, 'OverlaySortIndicator'))) {
            $columns[$iconColumn[0]].Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $list.UpdateLayout()
            $indicator = $view.FindName($iconColumn[1])
            Assert-True ($indicator.IsVisible -and $indicator.Text -ceq [string] [char] 0x25B2) 'Icon header did not select ascending sort.'
        }
        $columns[3].Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $view.FindName('NamePatternTextBox').Text = '*'
        $view.FindName('NamePatternTextBox').Text = ''
        $otherView = [Activator]::CreateInstance($view.GetType())
        $otherSort = $otherView.GetType().GetField('_sorting', $viewFlags).GetValue($otherView)
        Assert-True (@($pairsProperty.GetValue($otherSort)).Count -eq 0) 'Sort history leaked into another ContentView.'
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        $restoredPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($probe.Ready -and $restoredPaths.Count -eq 2 -and
            @($selectedPaths | Where-Object { $_ -notin $restoredPaths }).Count -eq 0) 'Sorting did not preserve selected paths.'
        foreach ($selectedEntry in $selectedEntries) {
            $restoredEntry = @($list.SelectedItems | ForEach-Object { $_.Entry } | Where-Object { $_.FullPath -eq $selectedEntry.FullPath })[0]
            Assert-True ([object]::ReferenceEquals($selectedEntry, $restoredEntry)) 'GUI sorting or filtering reloaded a cached entry.'
        }
        foreach ($operation in @('Copy', 'Move')) {
            $view.FindName("${operation}GetButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $workflowType = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true)
            $workflow = $workflowType.GetProperty('Shared').GetValue($null)
            $preparedPaths = @($workflow.PreparedPaths)
            Assert-True ($preparedPaths.Count -eq 2 -and @($selectedPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "$operation did not stage all selected paths."
            $view.FindName("${operation}AbortButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        $menuProbe = [SutShellMenuProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($window).Handle)
        try {
            $showItems = $shell.GetMethod('ShowItemMenu', $flags)
            $null = $showItems.Invoke($null, [object[]] @([string[]] $selectedPaths,
                [System.Windows.Interop.WindowInteropHelper]::new($window).Handle, $null))
            Assert-True ($menuProbe.ItemCount -gt 0) 'The Shell did not display a populated multi-item context menu.'
        } finally { $menuProbe.Dispose() }
        $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $otherFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'exact.bin') })[0]
        $showMenu = $view.GetType().GetMethod('ShowMenu', $viewFlags)
        $ownerHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        $menuInstanceType = $assembly.GetType('SUTWinExplorer.SutContextMenu', $true)
        $showInstance = $menuInstanceType.GetMethod('Show', $viewFlags)
        $emptyActions = [Array]::CreateInstance($assembly.GetType('SUTWinExplorer.ShellMenuAction', $true), 0)
        $factoryPaths = [string[]] @((Join-Path $directory 'notes.txt'))
        $baseInstance = $menuType.GetMethod('GetBaseMenu', $flags).Invoke($null, [object[]] @($factoryPaths, $ownerHandle, $emptyActions))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $baseSnapshot = $showInstance.Invoke($baseInstance, [object[]] @($null))
            Assert-True ($menuProbe.ItemCount -gt 0 -and $null -ne $baseSnapshot) 'The factory Base Menu did not return a snapshot after display.'
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $baseInstance).Dispose()
            ([IDisposable] $baseInstance).Dispose()
        }
        $disposedRejected = $false
        try { $null = $showInstance.Invoke($baseInstance, [object[]] @($null)) } catch {
            $disposedRejected = $_.Exception.InnerException -is [ObjectDisposedException]
        }
        Assert-True $disposedRejected 'A disposed menu instance was still usable.'
        $contentInstance = $menuType.GetMethod('GetContentMenu', $flags).Invoke($null, [object[]] @($factoryPaths, $ownerHandle, $baseSnapshot))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showInstance.Invoke($contentInstance, [object[]] @($null))
            Assert-True ($menuProbe.ItemCount -gt 0) 'The Content Menu could not use the snapshot after the Base Menu was disposed.'
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $contentInstance).Dispose()
        }
        $backgroundEntries = @((& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $directory -Background | ConvertFrom-Json).Menu)
        $excludedBackgroundEntries = @($backgroundEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -in @('refresh', 'viewcustomwizard') })
        Assert-True ($excludedBackgroundEntries.Count -eq 2) 'The Shell did not expose both background commands to exclude.'
        $viewParents = @($backgroundEntries | Where-Object {
            $_.Position -match '^\d+\.\d+$' -and $_.Verb -match '^(viewlogical|arrange|sortascending|sortdescending|groupascending|groupdescending)'
        } | ForEach-Object { ($_.Position -split '\.')[0] } | Select-Object -Unique)
        Assert-True ($viewParents.Count -ge 3) 'The Shell did not expose identifiable View, Sort and Group submenus.'
        $newParent = @($backgroundEntries | Where-Object { $_.Position -notmatch '\.' -and $_.HasSubmenu -and $_.OwnerDrawn } | ForEach-Object {
            $parent = $_
            if (@($backgroundEntries | Where-Object { $_.Position -eq ($parent.Position + '.0') -and $_.Text -ceq $parent.Text }).Count -gt 0) { $parent }
        })
        Assert-True ($newParent.Count -eq 1) 'The Shell New submenu could not be identified.'
        $emptyCommands = [System.Collections.Generic.Dictionary[string, int]]::new()
        $backgroundInstance = $menuType.GetMethod('GetBackgroundContentMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $emptyCommands))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showInstance.Invoke($backgroundInstance, [object[]] @($null))
            Assert-True ($menuProbe.ItemCount -gt 0) 'The filtered background menu was not displayed.'
            Assert-True ($newParent[0].Text -in $menuProbe.Items) 'The New submenu was removed from the background Content Menu.'
            foreach ($entry in $excludedBackgroundEntries) {
                Assert-True ($entry.Text -notin $menuProbe.Items) "An excluded command remained in the background Content Menu: $($entry.Text)."
            }
            foreach ($position in $viewParents) {
                $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                Assert-True ($parent.Text -notin $menuProbe.Items) "A background view submenu remained: $($parent.Text)."
            }
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $backgroundInstance).Dispose()
        }
        $backgroundBase = $menuType.GetMethod('GetBackgroundBaseMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $emptyActions))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $backgroundSnapshot = $showInstance.Invoke($backgroundBase, [object[]] @($null))
            Assert-True ($null -ne $backgroundSnapshot -and $newParent[0].Text -notin $menuProbe.Items) 'The background Base Menu included New or did not return a snapshot.'
            foreach ($entry in $excludedBackgroundEntries) {
                Assert-True ($entry.Text -notin $menuProbe.Items) "An excluded command remained in the background Base Menu: $($entry.Text)."
            }
            foreach ($position in $viewParents) {
                $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                Assert-True ($parent.Text -notin $menuProbe.Items) "A background view submenu remained in the Base Menu: $($parent.Text)."
            }
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $backgroundBase).Dispose()
        }
        $backgroundInstance = $menuType.GetMethod('GetBackgroundContentMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $backgroundSnapshot))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showInstance.Invoke($backgroundInstance, [object[]] @($null))
            Assert-True ($newParent[0].Text -in $menuProbe.Items) 'New was lost after comparing the background menus.'
            foreach ($entry in $excludedBackgroundEntries) {
                Assert-True ($entry.Text -notin $menuProbe.Items) "An excluded command returned after comparing background menus: $($entry.Text)."
            }
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $backgroundInstance).Dispose()
        }
        $backgroundSuffix = [guid]::NewGuid().ToString('N')
        $sharedBackgroundVerb = "KISBackgroundShared$backgroundSuffix"
        $backgroundOnlyVerb = "KISBackgroundOnly$backgroundSuffix"
        $sharedBackgroundLabel = "KIS shared background $backgroundSuffix"
        $backgroundOnlyLabel = "KIS background only $backgroundSuffix"
        $backgroundRegistryPaths = @("Software\Classes\*\shell\$sharedBackgroundVerb",
            "Software\Classes\Directory\shell\$sharedBackgroundVerb",
            "Software\Classes\Directory\Background\shell\$sharedBackgroundVerb",
            "Software\Classes\Directory\Background\shell\$backgroundOnlyVerb")
        try {
            foreach ($registryPath in $backgroundRegistryPaths) {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
                try {
                    $entry.SetValue('', $(if ($registryPath.EndsWith($backgroundOnlyVerb)) { $backgroundOnlyLabel } else { $sharedBackgroundLabel }))
                    $command = $entry.CreateSubKey('command')
                    try { $command.SetValue('', 'cmd.exe /c exit 0') } finally { $command.Dispose() }
                } finally { $entry.Dispose() }
            }
            $backgroundBase = $menuType.GetMethod('GetBackgroundBaseMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $emptyActions))
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $backgroundSnapshot = $showInstance.Invoke($backgroundBase, [object[]] @($null))
                Assert-True ($sharedBackgroundLabel -in $menuProbe.Items -and $backgroundOnlyLabel -notin $menuProbe.Items) 'Shared and background-only registrations were classified incorrectly in the Base Menu.'
            } finally { $menuProbe.Dispose(); ([IDisposable] $backgroundBase).Dispose() }
            $backgroundInstance = $menuType.GetMethod('GetBackgroundContentMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $backgroundSnapshot))
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showInstance.Invoke($backgroundInstance, [object[]] @($null))
                Assert-True ($sharedBackgroundLabel -notin $menuProbe.Items -and $backgroundOnlyLabel -in $menuProbe.Items) 'Shared and background-only registrations were classified incorrectly in the Content Menu.'
            } finally { $menuProbe.Dispose(); ([IDisposable] $backgroundInstance).Dispose() }
        } finally {
            foreach ($registryPath in $backgroundRegistryPaths) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false) }
        }
        $showMenuCore = $view.GetType().GetMethod('ShowMenuCore', $viewFlags)
        $list.SelectedItems.Clear()
        foreach ($menuKind in @('base', 'content', 'none', 'base')) {
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($null, $true))
                if ($menuKind -eq 'none') {
                    Assert-True ($menuProbe.ItemCount -eq -1) 'The third background click displayed a menu.'
                } elseif ($menuKind -eq 'base') {
                    Assert-True ($menuProbe.ItemCount -ge 9 -and $menuProbe.Items[1] -eq 'Path get' -and
                        ($menuProbe.States[0] -band 3) -ne 0 -and ($menuProbe.States[1] -band 3) -ne 0 -and
                        $newParent[0].Text -notin $menuProbe.Items) 'The background Base Menu or its disabled selection actions were incorrect.'
                } else {
                    Assert-True ($menuProbe.ItemCount -gt 0 -and $newParent[0].Text -in $menuProbe.Items) 'The background Content Menu did not include New.'
                }
                foreach ($position in $viewParents) {
                    $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                    Assert-True ($parent.Text -notin $menuProbe.Items) "A view submenu appeared in the background $menuKind step."
                }
            } finally { $menuProbe.Dispose() }
        }
        $multiPaths = @($notesMenuRow.Entry.FullPath, $otherFileRow.Entry.FullPath)
        $list.SelectedItems.Clear()
        $list.SelectedItems.Add($notesMenuRow) | Out-Null
        $list.SelectedItems.Add($otherFileRow) | Out-Null
        foreach ($selection in @(-1, 2, 3, 5, 6)) {
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            $menuProbe.SelectIndex = $selection
            try {
                $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
                Assert-True ($menuProbe.ItemCount -ge 9 -and
                    ($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete') 'Multiple files did not show the Base Menu.'
                Assert-True (($menuProbe.States[0] -band 3) -ne 0 -and ($menuProbe.States[1] -band 3) -ne 0) 'Rename and Path get must be disabled for multiple files.'
                if ($selection -ge 0) { Assert-True (($menuProbe.States[$selection] -band 3) -eq 0) "Multi-file command $selection was disabled." }
            } finally { $menuProbe.Dispose() }
            if ($selection -in @(2, 5)) {
                $operation = if ($selection -eq 2) { 'Copy' } else { 'Move' }
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $preparedPaths = @($workflow.PreparedPaths)
                Assert-True ($workflow.IsPrepared -and $preparedPaths.Count -eq 2 -and
                    @($multiPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "Multi-file $operation get did not prepare both files."
            } elseif ($selection -in @(3, 6)) {
                $operation = if ($selection -eq 3) { 'Copy' } else { 'Move' }
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                Assert-True (-not $workflow.IsPrepared) "Multi-file $operation abort did not clear the workflow."
            }
        }
        $showMenuCore = $view.GetType().GetMethod('ShowMenuCore', $viewFlags)
        $multiNativeEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $multiPaths | ConvertFrom-Json).Menu
        Assert-True (@($multiNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text }).Count -gt 0) 'The Shell did not provide a properties command for the multi-file selection.'
        foreach ($menuKind in @('base', 'content', 'none', 'base')) {
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                if ($menuKind -eq 'none') {
                    Assert-True ($menuProbe.ItemCount -eq -1) 'The third multi-file click displayed a menu.'
                    continue
                }
                Assert-True ($menuProbe.ItemCount -gt 0) "The multi-file $menuKind menu was empty."
                $isBase = $menuProbe.ItemCount -ge 9 -and ($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete'
                Assert-True ($isBase -eq ($menuKind -eq 'base')) "The multi-file menu did not alternate to $menuKind."
                foreach ($entry in $multiNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text }) {
                    Assert-True (($entry.Text -in $menuProbe.Items) -eq ($menuKind -eq 'base')) "Properties was shown in the wrong multi-file menu: $menuKind."
                    if ($menuKind -eq 'base') {
                        $index = [Array]::IndexOf($menuProbe.Items, $entry.Text)
                        Assert-True (($menuProbe.States[$index] -band 3) -eq 0) 'Properties was disabled in the Base Menu multi-file menu.'
                    }
                }
                if ($menuKind -eq 'content') {
                    $linkDropHereLabel = [SutShellMenuProbe]::LinkDropHereLabel()
                    Assert-True ($null -eq $linkDropHereLabel -or $linkDropHereLabel -notin $menuProbe.Items) 'A drag-and-drop-only Link Shell Extension command appeared in the multi-file menu.'
                    foreach ($entry in $multiNativeEntries | Where-Object { $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename') -and $_.Text }) {
                        Assert-True ($entry.Text -notin $menuProbe.Items) "Excluded Shell command remained in the multi-file menu: $($entry.Text)."
                    }
                }
            } finally { $menuProbe.Dispose() }
        }
        $controller = $view.GetType().GetField('_contextMenu', $viewFlags).GetValue($view)
        $resetController = $controller.GetType().GetMethod('Reset', $viewFlags)
        foreach ($resetMode in @('explicit', 'selection')) {
            $null = $resetController.Invoke($controller, @())
            foreach ($expectedBase in @($true, $false)) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                    $isBase = $menuProbe.ItemCount -ge 9 -and $menuProbe.Items[1] -eq 'Path get'
                    Assert-True ($menuProbe.ItemCount -gt 0 -and $isBase -eq $expectedBase) 'The reset test did not reach the expected menu.'
                } finally { $menuProbe.Dispose() }
            }
            if ($resetMode -eq 'explicit') { $null = $resetController.Invoke($controller, @()) }
            else {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($otherFileRow) | Out-Null
            }
            $nextRow = if ($resetMode -eq 'explicit') { $notesMenuRow } else { $otherFileRow }
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($nextRow.PSObject.BaseObject, $true))
                Assert-True ($menuProbe.ItemCount -ge 9 -and $menuProbe.Items[1] -eq 'Path get') "A $resetMode reset did not restart with the Base Menu."
            } finally { $menuProbe.Dispose() }
            if ($resetMode -eq 'selection') {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                $list.SelectedItems.Add($otherFileRow) | Out-Null
            }
        }
        $multiProperties = @($multiNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text })[0]
        $propertiesProbe = [SutShellPropertiesProbe]::new('')
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectLabel = $multiProperties.Text
        try {
            $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($menuProbe.SelectIndex -ge 9 -and $propertiesProbe.Opened) 'The Base Menu multi-file properties command did not open a Windows dialog.'
        } finally {
            $menuProbe.Dispose()
            $propertiesProbe.Dispose()
        }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $notesMenuRow
        $unfilteredMenu = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path (Join-Path $directory 'notes.txt') -Generic | ConvertFrom-Json).Menu
        $notepadEntries = @($unfilteredMenu | Where-Object { $_.Verb -eq 'ANotepad++64' })
        $viewerEntries = @($unfilteredMenu | Where-Object { $_.Verb -eq 'view SUTTextViewer' })
        $propertyEntries = @($unfilteredMenu | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text })
        $shellRenameEntries = @($unfilteredMenu | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'rename' -and $_.Text })
        Assert-True ($propertyEntries.Count -gt 0) 'The Shell did not provide a properties command for the test file.'
        $nativeEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path (Join-Path $directory 'notes.txt') | ConvertFrom-Json).Menu
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showItems.Invoke($null, [object[]] @([string[]] @((Join-Path $directory 'notes.txt')), $ownerHandle, [Action] {}))
            $nativeLabels = @($menuProbe.Items)
            foreach ($entry in $nativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -in @('properties', 'rename') -and $_.Text }) {
                Assert-True ($entry.Text -in $nativeLabels) "The original Windows menu lost $($entry.Verb)."
            }
        } finally { $menuProbe.Dispose() }
        $originalCursor = [SutShellRightClickProbe]::CursorPosition()
        $originalLeft = $window.Left
        $originalTop = $window.Top
        try {
            $window.Left = 20
            $window.Top = 20
            $window.Activate() | Out-Null
            $list.SelectedItems.Clear()
            $unfilteredCount = $list.Items.Count
            $namePattern = $view.FindName('NamePatternTextBox')
            $namePattern.Text = 'notes*.txt'
            Wait-ListCount $list 1
            $backgroundPoint = Find-ListBackgroundPoint $list
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $backgroundPoint.X, [int] $backgroundPoint.Y, [int] $backgroundPoint.X, [int] $backgroundPoint.Y)
            $rightClickProbe.AdditionalClicks = 2
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $newParent[0].Text -in $rightClickProbe.SecondItems -and $rightClickProbe.NoMenuObserved -and
                    $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0] -and
                    $list.SelectedItems.Count -eq 0) 'Actual background clicks did not follow the Base, Content, no-menu sequence.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $controller = $view.GetType().GetField('_contextMenu', $viewFlags).GetValue($view)
            $null = $controller.GetType().GetMethod('Reset', $viewFlags).Invoke($controller, @())
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $backgroundPoint.X, [int] $backgroundPoint.Y, [int] $backgroundPoint.X, [int] $backgroundPoint.Y)
            $rightClickProbe.SecondWithShift = $true
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase) 'Shift-right-click did not open the native background menu.'
                foreach ($entry in $excludedBackgroundEntries) {
                    Assert-True ($entry.Text -in $rightClickProbe.SecondItems) "Shift-right-click did not preserve the native background command: $($entry.Text)."
                }
                foreach ($position in $viewParents) {
                    $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                    Assert-True ($parent.Text -in $rightClickProbe.SecondItems) 'Shift-right-click did not preserve the original background view menus.'
                }
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $singleRow = $list.Items[0]
            $list.ScrollIntoView($singleRow)
            $list.UpdateLayout()
            $singleContainer = $list.ItemContainerGenerator.ContainerFromItem($singleRow)
            Assert-True ($null -ne $singleContainer) 'The filtered row was not realized for the background target-change test.'
            $singlePoint = $singleContainer.PointToScreen([System.Windows.Point]::new(10, $singleContainer.ActualHeight / 2))
            foreach ($direction in @('background-to-item', 'item-to-background')) {
                $list.SelectedItems.Clear()
                $null = $controller.GetType().GetMethod('Reset', $viewFlags).Invoke($controller, @())
                $start = if ($direction -eq 'background-to-item') { $backgroundPoint } else { $singlePoint }
                $destination = if ($direction -eq 'background-to-item') { $singlePoint } else { $backgroundPoint }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $start.X, [int] $start.Y, [int] $destination.X, [int] $destination.Y)
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedSelections = if ($direction -eq 'background-to-item') { 1 } else { 0 }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                        $list.SelectedItems.Count -eq $expectedSelections) "A $direction click did not start a new Base Menu."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            $namePattern.Clear()
            Wait-ListCount $list $unfilteredCount
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $probe = [SutShellUiProbe]::new()
            $probe.List = $list
            $probe.AwaitAll = $true
            $probe.Frame = $frame
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True $probe.Ready 'The unfiltered rows did not reload after the background click test.'
            $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
            $otherFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'exact.bin') })[0]
            $notesIndex = $list.Items.IndexOf($notesMenuRow)
            $otherMenuRow = $list.Items[($notesIndex + 1) % $list.Items.Count]
            $list.ScrollIntoView($otherMenuRow)
            $list.UpdateLayout()
            $notesContainer = $list.ItemContainerGenerator.ContainerFromItem($notesMenuRow)
            $otherContainer = $list.ItemContainerGenerator.ContainerFromItem($otherMenuRow)
            Assert-True ($null -ne $notesContainer -and $null -ne $otherContainer) 'The right-click test rows were not realized.'
            $startPoint = $notesContainer.PointToScreen([System.Windows.Point]::new($notesContainer.ActualWidth - 10, $notesContainer.ActualHeight / 2))
            $samePoint = $notesContainer.PointToScreen([System.Windows.Point]::new(10, $notesContainer.ActualHeight / 2))
            $otherPoint = $otherContainer.PointToScreen([System.Windows.Point]::new(10, $otherContainer.ActualHeight / 2))
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y, [int] $samePoint.X, [int] $samePoint.Y)
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(7)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase) "Two actual right-clicks on the same row did not show the Content Menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y, [int] $samePoint.X, [int] $samePoint.Y)
            $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddMilliseconds($rightClickProbe.SecondDelayMilliseconds + 7000)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $rightClickProbe.TargetClass -eq '#32768') "A delayed right-click at the popup's opening point did not show the Content Menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            foreach ($mode in @('delayed', 'rapid-multi')) {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                if ($mode -eq 'rapid-multi') { $list.SelectedItems.Add($otherMenuRow) | Out-Null }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y, [int] $samePoint.X, [int] $samePoint.Y)
                if ($mode -eq 'delayed') { $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250 }
                $rightClickProbe.AdditionalClicks = 2
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddMilliseconds(3 * $rightClickProbe.SecondDelayMilliseconds + 7000)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedCount = if ($mode -eq 'rapid-multi') { 2 } else { 1 }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                        $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and
                        $rightClickProbe.AdditionalMenuWasBase[0] -and $list.SelectedItems.Count -eq $expectedCount -and
                        $list.SelectedItems.Contains($notesMenuRow) -and ($mode -ne 'rapid-multi' -or $list.SelectedItems.Contains($otherMenuRow))) "Repeated stationary right-clicks did not alternate menus for mode=$mode`: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), additional=$($rightClickProbe.AdditionalMenuCount), selection=$($list.SelectedItems.Count)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $startPoint.X, [int] $startPoint.Y, [int] $otherPoint.X, [int] $otherPoint.Y)
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(7)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) "Actual right-clicks on different rows did not select the new row and open its Base Menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($list.SelectedItems.Count), selected=$($list.SelectedItem.Entry.FullPath)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            foreach ($target in @('same', 'selected')) {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                if ($target -eq 'selected') { $list.SelectedItems.Add($otherMenuRow) | Out-Null }
                $targetPoint = if ($target -eq 'same') { $samePoint } else { $otherPoint }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $startPoint.X, [int] $startPoint.Y, [int] $targetPoint.X, [int] $targetPoint.Y)
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddSeconds(7)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedRow = if ($target -eq 'same') { $notesMenuRow } else { $otherMenuRow }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and
                        $rightClickProbe.SecondWasBase -eq ($target -eq 'selected') -and $list.SelectedItems.Count -eq 1 -and
                        $list.SelectedItem.Entry.FullPath -eq $expectedRow.Entry.FullPath) "Actual right-clicks failed for target=$target`: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($list.SelectedItems.Count)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            foreach ($target in @('same', 'other', 'double', 'delayed')) {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                $list.SelectedItems.Add($otherMenuRow) | Out-Null
                $origin = if ($target -in @('double', 'delayed')) { $samePoint } else { $startPoint }
                $targetPoint = if ($target -eq 'other') { $otherPoint } else { $samePoint }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $origin.X, [int] $origin.Y, [int] $targetPoint.X, [int] $targetPoint.Y)
                $rightClickProbe.SecondWithShift = $true
                if ($target -eq 'delayed') { $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250 }
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddMilliseconds($rightClickProbe.SecondDelayMilliseconds + 7000)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedCount = if ($target -eq 'other') { 1 } else { 2 }
                    $expectedProperty = if ($target -eq 'other') { $propertyEntries[0].Text } else { $multiProperties.Text }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                        $expectedProperty -in $rightClickProbe.SecondItems -and $list.SelectedItems.Count -eq $expectedCount -and
                        ($target -ne 'other' -or $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath)) "Shift-right-click during the Base Menu failed for target=$target`: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), properties=$($expectedProperty -in $rightClickProbe.SecondItems), selection=$($list.SelectedItems.Count)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase) 'A second right-click on the same row did not show the Content Menu.'
            } finally { $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $otherPoint.X, [int] $otherPoint.Y)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) 'A right-click on another row did not select it and show its Base Menu.'
            } finally { $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($notesMenuRow) | Out-Null
            $list.SelectedItems.Add($otherMenuRow) | Out-Null
            $list.ScrollIntoView($otherMenuRow)
            $list.UpdateLayout()
            $notesContainer = $list.ItemContainerGenerator.ContainerFromItem($notesMenuRow)
            $otherContainer = $list.ItemContainerGenerator.ContainerFromItem($otherMenuRow)
            $startPoint = $notesContainer.PointToScreen([System.Windows.Point]::new($notesContainer.ActualWidth - 10, $notesContainer.ActualHeight / 2))
            $otherPoint = $otherContainer.PointToScreen([System.Windows.Point]::new(10, $otherContainer.ActualHeight / 2))
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $otherPoint.X, [int] $otherPoint.Y)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) "A right-click on another selected row did not start a new single-item menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($list.SelectedItems.Count), selected=$($list.SelectedItem.Entry.FullPath), target=$($otherMenuRow.Entry.FullPath)."
            } finally { $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($notesMenuRow) | Out-Null
            $list.SelectedItems.Add($otherMenuRow) | Out-Null
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($menuProbe.Items[1] -eq 'Path get') 'The first menu did not open for the multiple selection.'
            } finally { $menuProbe.Dispose() }
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $rightClick = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Right)
                $rightClick.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent
                $otherContainer.RaiseEvent($rightClick)
                Assert-True ($menuProbe.ItemCount -ge 9 -and $menuProbe.Items[1] -eq 'Path get' -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) "A right-click on another selected row after dismissing the menu did not start a new single-item menu: menu=$($menuProbe.ItemCount), selection=$($list.SelectedItems.Count), selected=$($list.SelectedItem.Entry.FullPath), handled=$($rightClick.Handled)."
            } finally { $menuProbe.Dispose() }
            $copyWorkflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
            Assert-True (-not $copyWorkflow.IsPrepared) 'The second right-click activated Copy get.'
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            $menuProbe.SelectIndex = 2
            $menuProbe.SelectWithRightButton = $true
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($menuProbe.ItemCount -ge 3 -and -not $copyWorkflow.IsPrepared) 'A right-click on a menu command unexpectedly invoked it.'
            } finally {
                $menuProbe.Dispose()
                $view.FindName('CopyAbortButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
        } finally {
            $window.Left = $originalLeft
            $window.Top = $originalTop
            [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1])
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
        }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            Assert-True (($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete') 'The first right-click did not show the Base Menu.'
            $baseLabels = @($menuProbe.Items)
            foreach ($entry in $propertyEntries) {
                $index = [Array]::IndexOf($menuProbe.Items, $entry.Text)
                Assert-True ($index -ge 9 -and ($menuProbe.States[$index] -band 3) -eq 0) 'Properties was missing or disabled in the Base Menu.'
            }
            foreach ($entry in $shellRenameEntries) {
                Assert-True ($entry.Text -notin $baseLabels[9..($baseLabels.Count - 1)]) 'The Shell rename command appeared alongside the application Rename action.'
            }
        } finally { $menuProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            $contentLabels = @($menuProbe.Items)
            Assert-True ($menuProbe.ItemCount -gt 0 -and $contentLabels[1] -ne 'Path get') 'The second right-click did not show the Content Menu.'
            $linkDropHereLabel = [SutShellMenuProbe]::LinkDropHereLabel()
            Assert-True ($null -eq $linkDropHereLabel -or $linkDropHereLabel -notin $contentLabels) 'A drag-and-drop-only Link Shell Extension command appeared in the Content file menu.'
            $openWithLabel = [SutShellMenuProbe]::OpenWithLabel()
            if ($openWithLabel -in $nativeLabels) { Assert-True ($openWithLabel -in $contentLabels) 'Open With was lost from the Content Menu.' }
            foreach ($entry in $notepadEntries) {
                if ($entry.Text -in $nativeLabels) { Assert-True ($entry.Text -in $contentLabels) 'Notepad++ was lost from the Content Menu.' }
            }
            foreach ($entry in $nativeEntries | Where-Object { $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename', 'properties') -and $_.Text }) {
                Assert-True ($entry.Text -notin $contentLabels) "Excluded Shell command remained in the Content Menu: $($entry.Text)."
            }
            foreach ($label in $nativeLabels | Where-Object { $_ -and $_ -notin $baseLabels }) {
                $excludedLabel = @($nativeEntries | Where-Object { $_.Text -ceq $label -and $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename', 'properties') }).Count -gt 0
                if (-not $excludedLabel) { Assert-True ($label -in $contentLabels) "A native command absent from the Base Menu was lost: $label." }
            }
            foreach ($label in @('7-Zip', 'Norton 360', '&TortoiseGit', 'Pa&th Copy')) {
                $genericParents = @($unfilteredMenu | Where-Object { $_.Position -notmatch '\.' -and $_.Text -ceq $label -and $_.HasSubmenu })
                $nativeParents = @($nativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -ceq $label -and $_.HasSubmenu })
                if ($genericParents.Count -ne 1 -or $nativeParents.Count -ne 1 -or $label -notin $baseLabels -or $label -notin $nativeLabels) { continue }
                $genericPrefix = $genericParents[0].Position + '.'
                $nativePrefix = $nativeParents[0].Position + '.'
                $genericChildren = @($unfilteredMenu | Where-Object { $_.Position.StartsWith($genericPrefix) -and -not $_.Separator })
                $nativeChildren = @($nativeEntries | Where-Object { $_.Position.StartsWith($nativePrefix) -and -not $_.Separator })
                if ($genericChildren.Count -eq 0 -or @($genericChildren | Where-Object { $_.Disabled -or -not $_.Text }).Count -gt 0) { continue }
                $genericSignature = @($genericChildren | ForEach-Object { @($_.Position.Substring($genericPrefix.Length), $_.Text, $_.Verb, $_.HasSubmenu, $_.Disabled) -join '|' }) -join "`n"
                $nativeSignature = @($nativeChildren | ForEach-Object { @($_.Position.Substring($nativePrefix.Length), $_.Text, $_.Verb, $_.HasSubmenu, $_.Disabled) -join '|' }) -join "`n"
                if ($genericSignature -ceq $nativeSignature) {
                    Assert-True ($label -notin $contentLabels) "The matching $label submenu remained in the Content Menu."
                }
            }
        } finally { $menuProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            Assert-True ($menuProbe.ItemCount -eq -1) 'The third right-click displayed a menu.'
        } finally { $menuProbe.Dispose() }
        if ('7-Zip' -in $baseLabels -and '7-Zip' -in $nativeLabels -and '7-Zip' -notin $contentLabels) {
            foreach ($emptySubmenu in @($false, $true)) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.AlterSubmenu = '7-Zip'
                $menuProbe.EmptySubmenu = $emptySubmenu
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                    Assert-True $menuProbe.SubmenuAltered 'The differing-submenu fixture could not be created.'
                } finally { $menuProbe.Dispose() }
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                    Assert-True ('7-Zip' -in $menuProbe.Items) 'A submenu with extra Content Menu commands or an empty Base Menu counterpart was removed.'
                } finally { $menuProbe.Dispose() }
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            }
        }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            Assert-True (($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete') 'The next right-click did not return to the Base Menu.'
        } finally { $menuProbe.Dispose() }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $notesMenuRow
        $propertiesProbe = [SutShellPropertiesProbe]::new('notes.txt')
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectLabel = $propertyEntries[0].Text
        try {
            $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($menuProbe.SelectIndex -ge 9 -and $propertiesProbe.Opened) "The Base Menu properties command did not open the Windows properties dialog: index=$($menuProbe.SelectIndex), opened=$($propertiesProbe.Opened)."
        } finally {
            $menuProbe.Dispose()
            $propertiesProbe.Dispose()
        }
        $contextMenuType = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
        $blacklist = $contextMenuType.GetField('BlacklistedVerbs', [System.Reflection.BindingFlags]'Static,NonPublic').GetValue($null).Value
        Assert-True ($blacklist.Contains('anotepad++64') -and -not $blacklist.Contains('view SUTTextViewer')) 'The embedded blacklist did not load the expected case-insensitive verbs.'
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showItems.Invoke($null, [object[]] @([string[]] @((Join-Path $directory 'notes.txt')), $ownerHandle, $null))
            foreach ($entry in $notepadEntries) {
                Assert-True ($entry.Text -in $menuProbe.Items) 'The original Windows menu lost the Notepad++ command.'
            }
        } finally { $menuProbe.Dispose() }
        $originalClipboard = [System.Windows.Clipboard]::GetDataObject()
        try {
            foreach ($selection in @(-1, 1, 2, 3, 5, 6, 0)) {
                $buttonStates = @(@('Rename', 'PathGet', 'CopyGet', 'CopyAbort', 'CopyPaste', 'MoveGet', 'MoveAbort', 'MovePaste', 'Delete') |
                    ForEach-Object { $view.FindName($_ + 'Button').IsEnabled })
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.SelectIndex = $selection
                try {
                    $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
                    Assert-True ($menuProbe.ItemCount -ge 9) 'The Base file menu did not contain all toolbar actions.'
                    Assert-True (($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete') "The menu did not match the toolbar actions: $($menuProbe.Items[0..8] -join ',')."
                    $openWithLabel = [SutShellMenuProbe]::OpenWithLabel()
                    Assert-True ($null -ne $openWithLabel -and $openWithLabel -notin $menuProbe.Items) 'The Shell Open With submenu is still present.'
                    $linkDropHereLabel = [SutShellMenuProbe]::LinkDropHereLabel()
                    Assert-True ($null -eq $linkDropHereLabel -or $linkDropHereLabel -notin $menuProbe.Items) 'A drag-and-drop-only Link Shell Extension command appeared in the file menu.'
                    foreach ($entry in $notepadEntries) {
                        Assert-True ($entry.Text -notin $menuProbe.Items) 'The blacklisted Notepad++ command appeared in the Base Menu.'
                    }
                    foreach ($entry in $viewerEntries) {
                        Assert-True ($entry.Text -in $menuProbe.Items) 'The unblacklisted SUTTextViewer command disappeared from the Base Menu.'
                    }
                    if ($menuProbe.ItemCount -gt 9) {
                        Assert-True (($menuProbe.States[9] -band 0x800) -ne 0) 'The toolbar actions were not separated from Shell extensions.'
                    }
                    for ($index = 0; $index -lt 9; $index++) {
                        Assert-True ((($menuProbe.States[$index] -band 3) -eq 0) -eq $buttonStates[$index]) "Menu state did not match $($menuProbe.Items[$index])."
                    }
                    if ($selection -ge 0) { Assert-True (($menuProbe.States[$selection] -band 3) -eq 0) "Command $selection was disabled." }
                } finally { $menuProbe.Dispose() }
                if ($selection -eq 1) {
                    Assert-True ([System.Windows.Clipboard]::GetText() -ceq (Join-Path $directory 'notes.txt')) 'Path get did not put the selected path on the clipboard.'
                } elseif ($selection -in @(2, 5)) {
                    $operation = if ($selection -eq 2) { 'Copy' } else { 'Move' }
                    $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                    Assert-True ($workflow.IsPrepared -and @($workflow.PreparedPaths)[0] -ceq (Join-Path $directory 'notes.txt')) "$operation get did not prepare the selected file."
                } elseif ($selection -in @(3, 6)) {
                    $operation = if ($selection -eq 3) { 'Copy' } else { 'Move' }
                    $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                    Assert-True (-not $workflow.IsPrepared) "$operation abort did not clear the workflow."
                } elseif ($selection -eq 0) {
                    Assert-True $notesMenuRow.IsEditing 'Rename did not start the inline editor.'
                    $null = $view.GetType().GetMethod('EndRename', $viewFlags).Invoke($view, [object[]] @([bool] $false))
                }
            }
        } finally {
            if ($null -eq $originalClipboard) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($originalClipboard, $true) }
        }
        $pasteSource = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-menu-source-' + [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.Directory]::CreateDirectory($pasteSource) | Out-Null
            foreach ($operation in @('Copy', 'Move')) {
                $sourceFile = Join-Path $pasteSource "menu-$operation-test.txt"
                $destinationFile = Join-Path $directory "menu-$operation-test.txt"
                [System.IO.File]::WriteAllText($sourceFile, 'menu workflow test')
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $workflow.Prepare([string[]] @($sourceFile))
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.SelectIndex = if ($operation -eq 'Copy') { 4 } else { 7 }
                try {
                    $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
                    Assert-True (($menuProbe.States[$menuProbe.SelectIndex] -band 3) -eq 0) "$operation paste was disabled."
                } finally { $menuProbe.Dispose() }
                Assert-True ([System.IO.File]::Exists($destinationFile) -and -not $workflow.IsPrepared) "$operation paste did not complete the prepared workflow."
                Assert-True (([System.IO.File]::Exists($sourceFile)) -eq ($operation -eq 'Copy')) "$operation paste did not preserve the expected source state."
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $probe = [SutShellUiProbe]::new()
                $probe.List = $list
                $probe.AwaitAll = $true
                $probe.Frame = $frame
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(25)
                $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
                $timer.Start()
                try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
                Assert-True $probe.Ready "Rows did not reload after $operation paste: $($probe.Error)"
                $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
                $list.SelectedItem = $notesMenuRow
                Remove-Item -LiteralPath $destinationFile -Force
            }
        } finally {
            Remove-Item -LiteralPath $pasteSource -Recurse -Force -ErrorAction SilentlyContinue
        }
        $list.SelectedItems.Clear()
        foreach ($selectedPath in $selectedPaths) {
            $list.SelectedItems.Add(@($list.Items | Where-Object { $_.Entry.FullPath -eq $selectedPath })[0]) | Out-Null
        }
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        $restoredPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($probe.Ready -and $restoredPaths.Count -eq 2 -and
            @($selectedPaths | Where-Object { $_ -notin $restoredPaths }).Count -eq 0) "Multiple selection was not restored after consecutive refreshes: $($probe.Error)"
        $list.SelectedItems.Clear()
        $firstRow = $list.Items[0]
        $lastRow = $list.Items[$list.Items.Count - 1]
        $list.ScrollIntoView($lastRow)
        $list.UpdateLayout()
        $priority = [SutShellPriorityProbe]::new()
        $priority.First = $firstRow
        $priority.Visible = $lastRow
        $priorityCallback = [Delegate]::CreateDelegate([System.ComponentModel.PropertyChangedEventHandler], $priority, 'OnPropertyChanged')
        $firstRow.add_PropertyChanged($priorityCallback)
        $lastRow.add_PropertyChanged($priorityCallback)
        try {
            $firstRow.GetType().GetProperty('Entry').SetValue($firstRow, $null)
            $lastRow.GetType().GetProperty('Entry').SetValue($lastRow, $null)
            $view.GetType().GetField('_nextBackgroundIndex', $viewFlags).SetValue($view, 0)
            $null = $view.GetType().GetMethod('LoadNextRange', $viewFlags).Invoke($view, @())
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $probe = [SutShellUiProbe]::new()
            $probe.List = $list
            $probe.AwaitAll = $true
            $probe.Frame = $frame
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($probe.Ready -and $priority.Order -ceq 'VB') "Visible row did not precede background work: $($priority.Order) $($probe.Error)"
        } finally {
            $firstRow.remove_PropertyChanged($priorityCallback)
            $lastRow.remove_PropertyChanged($priorityCallback)
        }
        $list.ScrollIntoView($firstRow)
        $list.UpdateLayout()
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "Scrolling did not load and render the requested range: $($probe.Error)"
        $list.SelectedItem = $list.Items[0]
        Assert-True $view.FindName('PathGetButton').IsEnabled 'Selecting a loaded row must enable Path get.'
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "Rows were not ready for rename testing: $($probe.Error)"
        $notesRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $list.SelectedItem = $notesRow
        Assert-True $view.FindName('RenameButton').IsEnabled 'Rename must be enabled for one loaded item.'
        $list.ScrollIntoView($notesRow)
        $list.UpdateLayout()
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::F2)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        $list.RaiseEvent($keyEvent)
        $list.UpdateLayout()
        $editor = Find-VisualName $list.ItemContainerGenerator.ContainerFromItem($notesRow) 'ItemNameEditor'
        Assert-True ($null -ne $editor -and $editor.IsVisible -and $editor.Text -eq 'notes.txt') 'The inline rename editor was not rendered.'
        Assert-True ($notesRow.IsEditing -and $notesRow.EditName -eq 'notes.txt') 'Inline rename did not start with the actual file name.'
        $editor.Text = 'cancelled.txt'
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        Assert-True ([object]::ReferenceEquals($list.ItemsSource[0], $list.Items[0]) -and $notesRow.IsEditing) 'Refresh interrupted an active rename.'
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::Escape)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $editor.RaiseEvent($keyEvent)
        Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'notes.txt')) -and
            -not (Test-Path -LiteralPath (Join-Path $directory 'cancelled.txt'))) 'Cancel changed the file.'
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and $list.SelectedItem.Entry.FullPath -eq (Join-Path $directory 'notes.txt')) 'Deferred refresh did not retain the selected file.'
        $view.FindName('RenameButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $list.UpdateLayout()
        $editor = Find-VisualName $list.ItemContainerGenerator.ContainerFromItem($list.SelectedItem) 'ItemNameEditor'
        Assert-True ($null -ne $editor -and $editor.IsVisible) 'The inline editor did not reopen.'
        $editor.Text = 'renamed-notes.txt'
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::Enter)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $editor.RaiseEvent($keyEvent)
        Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'renamed-notes.txt')) -and
            -not (Test-Path -LiteralPath (Join-Path $directory 'notes.txt'))) 'Inline rename did not rename the file correctly.'
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and $list.SelectedItem.Entry.FullPath -eq (Join-Path $directory 'renamed-notes.txt')) 'Renamed file was not reselected.'
        $view.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready 'Directory rows were not loaded for rename testing.'
        $folderRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'Folder') })[0]
        $renamedFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'renamed-notes.txt') })[0]
        Assert-True ($null -ne $folderRow -and $null -ne $renamedFileRow) 'Mixed-selection rows were not available.'
        $otherFolderRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'OtherFolder') })[0]
        Assert-True ($null -ne $otherFolderRow) 'The second directory menu test row was not loaded.'
        $registrySuffix = [guid]::NewGuid().ToString('N')
        $sharedVerb = "KISTestShared$registrySuffix"
        $folderSharedVerb = "KISTestFolderShared$registrySuffix"
        $directoryVerb = "KISTestDirectory$registrySuffix"
        $sharedLabel = "KIS shared action $registrySuffix"
        $folderSharedLabel = "KIS shared folder action $registrySuffix"
        $directoryLabel = "KIS directory action $registrySuffix"
        $registryPaths = @("Software\Classes\*\shell\$sharedVerb", "Software\Classes\Directory\shell\$sharedVerb",
            "Software\Classes\*\shell\$folderSharedVerb", "Software\Classes\Folder\shell\$folderSharedVerb", "Software\Classes\Directory\shell\$directoryVerb")
        try {
            foreach ($registryPath in $registryPaths) {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
                try {
                    $label = if ($registryPath.EndsWith($sharedVerb)) { $sharedLabel } elseif ($registryPath.EndsWith($folderSharedVerb)) { $folderSharedLabel } else { $directoryLabel }
                    $entry.SetValue('', $label)
                    $command = $entry.CreateSubKey('command')
                    try { $command.SetValue('', 'cmd.exe /c exit 0') } finally { $command.Dispose() }
                } finally { $entry.Dispose() }
            }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $folderRow
            foreach ($menuKind in @('base', 'content')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                    Assert-True (($sharedLabel -in $menuProbe.Items) -eq ($menuKind -eq 'base') -and
                        ($folderSharedLabel -in $menuProbe.Items) -eq ($menuKind -eq 'base') -and
                        ($directoryLabel -in $menuProbe.Items) -eq ($menuKind -eq 'content')) "Registry-matched directory commands appeared in the wrong menu: $menuKind."
                } finally { $menuProbe.Dispose() }
            }
            $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
            $whitelist = $menuType.GetField('DirectoryWhitelist', $flags).GetValue($null).Value
            $whitelistedVerbs = $whitelist.GetType().GetProperty('Verbs').GetValue($whitelist)
            $null = $whitelistedVerbs.Add($directoryVerb.ToLowerInvariant())
            try {
                foreach ($menuKind in @('base', 'content')) {
                    $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                    try {
                        $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                        Assert-True (($directoryLabel -in $menuProbe.Items) -eq ($menuKind -eq 'base')) "The whitelisted directory command appeared in the wrong menu: $menuKind."
                    } finally { $menuProbe.Dispose() }
                }
            } finally { $null = $whitelistedVerbs.Remove($directoryVerb) }
            $explorerVerb = "KISTestExplorerCommand$registrySuffix"
            $explorerPath = "Software\Classes\Directory\shell\$explorerVerb"
            try {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($explorerPath)
                try { $entry.SetValue('ExplorerCommandHandler', $testHandler.ToString('B')) } finally { $entry.Dispose() }
                $directoryVerbKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\Directory\shell')
                try {
                    $emptyNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    $getEligibleVerbs = $menuType.GetMethod('GetEligibleDirectoryVerbs', $flags)
                    $accepted = $getEligibleVerbs.Invoke($null, [object[]] @($directoryVerbKey, $emptyNames, $parsedWhitelist))
                    $rejected = $getEligibleVerbs.Invoke($null, [object[]] @($directoryVerbKey, $emptyNames, $whitelist))
                    Assert-True ($accepted.Contains($explorerVerb) -and -not $rejected.Contains($explorerVerb)) 'ExplorerCommandHandler CLSID whitelist matching failed.'
                } finally { $directoryVerbKey.Dispose() }
            } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($explorerPath, $false) }
        } finally {
            foreach ($registryPath in $registryPaths) {
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false)
            }
        }
        foreach ($multiple in @($false, $true)) {
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($folderRow) | Out-Null
            if ($multiple) { $list.SelectedItems.Add($otherFolderRow) | Out-Null }
            $folderPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
            $folderNativeEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $folderPaths | ConvertFrom-Json).Menu
            $folderProperties = @($folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text })
            Assert-True ($folderProperties.Count -gt 0) "The Shell did not provide directory properties: multiple=$multiple."
            if (-not $multiple) {
                $singleFolderProperty = $folderProperties[0].Text
                $folderFilesystemEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $folderPaths -FilesystemObjects | ConvertFrom-Json).Menu
                $sevenZipNative = @($folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -eq '7-Zip' -and $_.HasSubmenu })
                $sevenZipFileKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('*\shellex\ContextMenuHandlers\7-Zip')
                $sevenZipFolderKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('Folder\shellex\ContextMenuHandlers\7-Zip')
                try {
                    $sevenZipShared = $null -ne $sevenZipFileKey -and $null -ne $sevenZipFolderKey -and
                        $sevenZipFileKey.GetValue('') -eq $sevenZipFolderKey.GetValue('') -and $sevenZipNative.Count -eq 1
                } finally {
                    if ($sevenZipFileKey) { $sevenZipFileKey.Dispose() }
                    if ($sevenZipFolderKey) { $sevenZipFolderKey.Dispose() }
                }
                $hgFileKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('*\shellex\ContextMenuHandlers\TortoiseHgCMenu')
                $hgFolderKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('Folder\shellex\ContextMenuHandlers\TortoiseHgCMenu')
                try {
                    $hgWorkbench = @($folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -match '^Hg\s+&?Workbench$' -and -not $_.Verb -and -not $_.HasSubmenu -and -not $_.OwnerDrawn })
                    $hgShared = $null -ne $hgFileKey -and $null -ne $hgFolderKey -and
                        $hgFileKey.GetValue('') -eq $hgFolderKey.GetValue('') -and $hgWorkbench.Count -eq 1
                } finally {
                    if ($hgFileKey) { $hgFileKey.Dispose() }
                    if ($hgFolderKey) { $hgFolderKey.Dispose() }
                }
            }
            foreach ($menuKind in @('base', 'content', 'none', 'base')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                    if ($menuKind -eq 'none') {
                        Assert-True ($menuProbe.ItemCount -eq -1) 'The third directory click displayed a menu.'
                        continue
                    }
                    $isBase = $menuProbe.ItemCount -ge 9 -and ($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete'
                    Assert-True ($isBase -eq ($menuKind -eq 'base')) "The directory menu did not alternate to $menuKind`: multiple=$multiple."
                    foreach ($entry in $folderProperties) {
                        $index = [Array]::IndexOf($menuProbe.Items, $entry.Text)
                        Assert-True (($index -ge 0) -eq ($menuKind -eq 'base')) "Directory properties appeared in the wrong menu: multiple=$multiple, menu=$menuKind."
                        if ($menuKind -eq 'base') { Assert-True (($menuProbe.States[$index] -band 3) -eq 0) 'Directory properties was disabled.' }
                    }
                    if ($multiple -and $menuKind -eq 'base') {
                        Assert-True (($menuProbe.States[0] -band 3) -ne 0 -and ($menuProbe.States[1] -band 3) -ne 0) 'Rename and Path get must be disabled for multiple directories.'
                    }
                    if ($menuKind -eq 'base') {
                        $folderBaseLabels = @($menuProbe.Items)
                        if (-not $multiple) {
                            if ($sevenZipShared) { Assert-True ('7-Zip' -in $folderBaseLabels) 'The shared 7-Zip handler was missing from the directory Base Menu.' }
                            if ($hgShared) { Assert-True ($hgWorkbench[0].Text -in $folderBaseLabels) 'The shared Hg Workbench command was missing from the directory Base Menu.' }
                            foreach ($entry in $folderFilesystemEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -and $_.Verb -notin @('copy', 'cut', 'paste', 'copyaspath', 'delete', 'rename') -and $_.Text }) {
                                Assert-True ($entry.Text -in $folderBaseLabels) "An AllFilesystemObjects command was missing from the directory Base Menu: $($entry.Text)."
                            }
                        }
                    }
                    if ($menuKind -eq 'content') {
                        if (-not $multiple -and $sevenZipShared) { Assert-True ('7-Zip' -notin $menuProbe.Items) 'The shared 7-Zip handler remained duplicated in the directory Content Menu.' }
                        if (-not $multiple -and $hgShared) { Assert-True ($hgWorkbench[0].Text -notin $menuProbe.Items) 'The shared Hg Workbench command remained duplicated in the directory Content Menu.' }
                        foreach ($entry in $folderNativeEntries | Where-Object { $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'delete', 'rename') -and $_.Text }) {
                            Assert-True ($entry.Text -notin $menuProbe.Items) "An excluded command remained in the directory Content Menu: $($entry.Text)."
                        }
                        foreach ($entry in $folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -and $_.Verb -and -not $_.HasSubmenu -and -not $_.Disabled -and -not $_.OwnerDrawn -and $_.Text -notin $folderBaseLabels -and $_.Verb -notin @('copy', 'cut', 'paste', 'copyaspath', 'delete', 'rename', 'properties') }) {
                            Assert-True ($entry.Text -in $menuProbe.Items) "A directory command absent from the Base Menu was lost: $($entry.Text)."
                        }
                    }
                    Assert-True ($list.SelectedItems.Count -eq $folderPaths.Count) 'Switching directory menus changed the selection.'
                } finally { $menuProbe.Dispose() }
            }
        }
        if ($hgShared) {
            $collisionVerb = "KISTestDirectoryCollision$registrySuffix"
            $collisionPath = "Software\Classes\Directory\shell\$collisionVerb"
            try {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($collisionPath)
                try {
                    $entry.SetValue('', $hgWorkbench[0].Text)
                    $command = $entry.CreateSubKey('command')
                    try { $command.SetValue('', 'cmd.exe /c exit 0') } finally { $command.Dispose() }
                } finally { $entry.Dispose() }
                $list.SelectedItems.Clear()
                $list.SelectedItem = $folderRow
                $collisionEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $folderRow.Entry.FullPath | ConvertFrom-Json).Menu
                Assert-True (@($collisionEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -ceq $hgWorkbench[0].Text }).Count -eq 2) 'The duplicate-label directory fixture was not shown by the Shell.'
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                    Assert-True (@($menuProbe.Items | Where-Object { $_ -ceq $hgWorkbench[0].Text }).Count -eq 1) 'The ambiguous shared Hg command was lost or the directory-only command was promoted.'
                } finally { $menuProbe.Dispose() }
            } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($collisionPath, $false) }
        }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $folderRow
        $propertiesProbe = [SutShellPropertiesProbe]::new('Folder')
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectLabel = $singleFolderProperty
        try {
            $null = $showMenu.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($menuProbe.SelectIndex -ge 9 -and $propertiesProbe.Opened) 'Directory properties did not open a Windows dialog from the Base Menu.'
        } finally { $menuProbe.Dispose(); $propertiesProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectIndex = 2
        try {
            $null = $showMenu.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject))
            $workflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
            Assert-True ($workflow.IsPrepared -and @($workflow.PreparedPaths).Count -eq 1 -and
                @($workflow.PreparedPaths)[0] -eq $folderRow.Entry.FullPath) 'Copy get did not prepare the selected directory.'
        } finally {
            $menuProbe.Dispose()
            $view.FindName('CopyAbortButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        $originalCursor = [SutShellRightClickProbe]::CursorPosition()
        $originalLeft = $window.Left
        $originalTop = $window.Top
        try {
            $window.Left = 20
            $window.Top = 20
            $window.Activate() | Out-Null
            $list.ScrollIntoView($folderRow)
            $list.UpdateLayout()
            $folderContainer = $list.ItemContainerGenerator.ContainerFromItem($folderRow)
            Assert-True ($null -ne $folderContainer) 'The directory right-click test row was not realized.'
            $folderPoint = $folderContainer.PointToScreen([System.Windows.Point]::new(10, $folderContainer.ActualHeight / 2))
            $list.SelectedItems.Clear()
            $list.SelectedItem = $folderRow
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $folderPoint.X, [int] $folderPoint.Y, [int] $folderPoint.X, [int] $folderPoint.Y)
            $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250
            $rightClickProbe.AdditionalClicks = 2
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddMilliseconds(3 * $rightClickProbe.SecondDelayMilliseconds + 7000)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and
                    $rightClickProbe.AdditionalMenuWasBase[0] -and $list.SelectedItems.Count -eq 1 -and
                    $list.SelectedItem.Entry.FullPath -eq $folderRow.Entry.FullPath) 'Stationary right-clicks did not alternate the directory menus.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($folderRow) | Out-Null
            $list.SelectedItems.Add($renamedFileRow) | Out-Null
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $folderPoint.X, [int] $folderPoint.Y, [int] $folderPoint.X, [int] $folderPoint.Y)
            $rightClickProbe.AdditionalClicks = 2
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0] -and
                    $list.SelectedItems.Count -eq 2 -and $list.SelectedItems.Contains($folderRow) -and
                    $list.SelectedItems.Contains($renamedFileRow)) 'Stationary right-clicks did not alternate the mixed-selection menus.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
        } finally {
            $window.Left = $originalLeft
            $window.Top = $originalTop
            [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1])
        }
        foreach ($firstRow in @($renamedFileRow, $folderRow)) {
            $secondRow = if ($firstRow -eq $folderRow) { $renamedFileRow } else { $folderRow }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($firstRow) | Out-Null
            $list.SelectedItems.Add($secondRow) | Out-Null
            $mixedPaths = @($firstRow.Entry.FullPath, $secondRow.Entry.FullPath)
            Assert-True ($list.SelectedItems.Count -eq 2) 'The mixed file and folder selection was not established.'
            $mixedNative = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $mixedPaths | ConvertFrom-Json).Menu
            $mixedGeneric = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $mixedPaths -Generic | ConvertFrom-Json).Menu
            Assert-True ($mixedNative.Count -gt 0 -and $mixedGeneric.Count -gt 0) 'The Shell did not provide both mixed-selection menus.'
            foreach ($menuKind in @('base', 'content', 'none', 'base')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($firstRow.PSObject.BaseObject, $true))
                    if ($menuKind -eq 'none') {
                        Assert-True ($menuProbe.ItemCount -eq -1) 'The third mixed-selection click displayed a menu.'
                        continue
                    }
                    $isBase = $menuProbe.ItemCount -ge 9 -and ($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete'
                    Assert-True ($isBase -eq ($menuKind -eq 'base')) "The mixed menu did not alternate to $menuKind."
                    if ($isBase) {
                        Assert-True (($menuProbe.States[0] -band 3) -ne 0 -and ($menuProbe.States[1] -band 3) -ne 0 -and
                            ($menuProbe.States[2] -band 3) -eq 0 -and ($menuProbe.States[5] -band 3) -eq 0 -and
                            ($menuProbe.States[8] -band 3) -eq 0) 'Mixed-selection action states were incorrect.'
                        foreach ($entry in $mixedGeneric | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text }) {
                            Assert-True ($entry.Text -in $menuProbe.Items) 'Mixed-selection Base Menu lost Shell properties.'
                        }
                    } else {
                        foreach ($entry in $mixedNative | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename', 'properties') -and $_.Text }) {
                            Assert-True ($entry.Text -notin $menuProbe.Items) "Excluded Shell command remained in the mixed Content Menu: $($entry.Text)."
                        }
                    }
                    Assert-True ($list.SelectedItems.Count -eq 2 -and $list.SelectedItems.Contains($firstRow) -and
                        $list.SelectedItems.Contains($secondRow)) 'Opening a mixed-selection menu changed the selection.'
                } finally { $menuProbe.Dispose() }
            }
            foreach ($operation in @('Copy', 'Move')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.SelectIndex = if ($operation -eq 'Copy') { 2 } else { 5 }
                try { $null = $showMenu.Invoke($view, [object[]] @($firstRow.PSObject.BaseObject)) } finally { $menuProbe.Dispose() }
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $preparedPaths = @($workflow.PreparedPaths)
                Assert-True ($workflow.IsPrepared -and $preparedPaths.Count -eq 2 -and
                    @($mixedPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "Mixed-selection $operation did not prepare both items."
                $view.FindName("${operation}AbortButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
        }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $folderRow
        $renameProbe = [SutShellRenameProbe]::new()
        $folderEvent = $view.GetType().GetEvent('FolderRenamed', $viewFlags)
        $folderCallback = [Delegate]::CreateDelegate([Action[string,string]], $renameProbe, 'OnFolderRenamed')
        $folderEvent.GetAddMethod($true).Invoke($view, [object[]] @($folderCallback))
        try {
            $null = $view.GetType().GetMethod('BeginRename', $viewFlags).Invoke($view, @())
            $folderRow.EditName = 'RenamedFolder'
            $null = $view.GetType().GetMethod('EndRename', $viewFlags).Invoke($view, [object[]] @([bool] $true))
            Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'RenamedFolder')) -and
                $renameProbe.OldPath -eq (Join-Path $directory 'Folder') -and
                $renameProbe.NewPath -eq (Join-Path $directory 'RenamedFolder')) 'Directory rename was not propagated.'
        } finally {
            $folderEvent.GetRemoveMethod($true).Invoke($view, [object[]] @($folderCallback))
        }
        $otherDirectory = Join-Path $directory 'navigation-test'
        [System.IO.Directory]::CreateDirectory($otherDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $otherDirectory 'other.txt'), 'other')
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $otherDirectory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $directory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and [System.IO.Path]::GetDirectoryName($list.Items[0].Entry.FullPath) -eq $directory) "A stale navigation replaced the current snapshot: $($probe.Error)"

        $deleteDirectory = Join-Path $directory 'delete-fixture'
        $deleteNames = @('delete-first', 'delete-second', 'delete-folder')
        [System.IO.Directory]::CreateDirectory((Join-Path $deleteDirectory $deleteNames[2])) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $deleteDirectory $deleteNames[0]), 'first')
        [System.IO.File]::WriteAllText((Join-Path $deleteDirectory $deleteNames[1]), 'second')
        [System.IO.File]::WriteAllText((Join-Path $deleteDirectory $deleteNames[2] 'nested'), 'folder content')
        $recycleBin = (New-Object -ComObject Shell.Application).NameSpace(10)
        try {
            $deleteApi = $shell.GetMethod('Delete', $flags)
            $fileOperations = $assembly.GetType('SUTWinExplorer.ShellFileOperations', $true)
            $canDelete = $fileOperations.GetMethod('CanDelete', $flags)
            $driveRoot = [System.IO.Path]::GetPathRoot($deleteDirectory)
            foreach ($invalidPath in @($driveRoot, '\\server\share\', 'relative-file')) {
                Assert-True (-not $canDelete.Invoke($null, [object[]] @([string] $invalidPath))) "A non-deletable path was accepted: $invalidPath"
            }
            foreach ($invalidSelection in @(
                [string[]] @(),
                [string[]] @((Join-Path $deleteDirectory $deleteNames[0]), (Join-Path $deleteDirectory 'missing')),
                [string[]] @((Join-Path $deleteDirectory $deleteNames[0]), $driveRoot)
            )) {
                $failed = $false
                try { $null = $deleteApi.Invoke($null, [object[]] @([string[]] $invalidSelection, [IntPtr]::Zero)) }
                catch { $failed = $_.Exception.InnerException -is [InvalidOperationException] }
                Assert-True ($failed -and [System.IO.File]::Exists((Join-Path $deleteDirectory $deleteNames[0]))) 'An invalid delete selection was accepted or partially deleted.'
            }
            $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $deleteDirectory))
            $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $probe = [SutShellUiProbe]::new()
            $probe.List = $list
            $probe.AwaitAll = $true
            $probe.Frame = $frame
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($probe.Ready -and -not $view.FindName('DeleteButton').IsEnabled) 'Delete was enabled without a selection or the test directory did not load.'
            $firstDeleteRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $deleteDirectory $deleteNames[0]) })[0]
            $secondDeleteRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $deleteDirectory $deleteNames[1]) })[0]
            $list.SelectedItems.Add($firstDeleteRow) | Out-Null
            $list.SelectedItems.Add($secondDeleteRow) | Out-Null
            Assert-True $view.FindName('DeleteButton').IsEnabled 'Delete was not enabled for two files.'
            $view.FindName('CopyGetButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True (-not $view.FindName('DeleteButton').IsEnabled) 'Delete was enabled during a prepared Copy.'
            $view.FindName('CopyAbortButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            $menuProbe.SelectIndex = 8
            $confirmationProbe = [SutShellDeleteConfirmProbe]::new()
            try {
                $null = $showMenu.Invoke($view, [object[]] @($firstDeleteRow.PSObject.BaseObject))
                Assert-True (($menuProbe.States[8] -band 3) -eq 0) 'Delete was disabled in the Base file menu.'
            } finally { $menuProbe.Dispose(); $confirmationProbe.Dispose() }
            Assert-True (-not [System.IO.File]::Exists((Join-Path $deleteDirectory $deleteNames[0])) -and
                -not [System.IO.File]::Exists((Join-Path $deleteDirectory $deleteNames[1]))) 'The Base Menu Delete command did not delete both selected files.'
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $probe = [SutShellUiProbe]::new()
            $probe.List = $list
            $probe.AwaitAll = $true
            $probe.Frame = $frame
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($probe.Ready -and $list.Items.Count -eq 1) 'The view did not refresh after deleting files.'
            $folderDeleteRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $deleteDirectory $deleteNames[2]) })[0]
            $list.SelectedItem = $folderDeleteRow
            Assert-True $view.FindName('DeleteButton').IsEnabled 'Delete was not enabled for a folder.'
            $confirmationProbe = [SutShellDeleteConfirmProbe]::new()
            try {
                $view.FindName('DeleteButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            } finally { $confirmationProbe.Dispose() }
            Assert-True (-not [System.IO.Directory]::Exists((Join-Path $deleteDirectory $deleteNames[2]))) 'The toolbar Delete command did not delete the folder.'
            $recycled = @($recycleBin.Items() | Where-Object {
                $_.Name -in $deleteNames -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $deleteDirectory, [StringComparison]::OrdinalIgnoreCase)
            })
            Assert-True ($recycled.Count -eq 3) "The Shell did not put all test objects in the Recycle Bin: $($recycled.Count)."
        } finally {
            foreach ($item in @($recycleBin.Items() | Where-Object {
                $_.Name -in $deleteNames -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $deleteDirectory, [StringComparison]::OrdinalIgnoreCase)
            })) { $item.Verbs().Item(0).DoIt() }
            $remaining = @($recycleBin.Items() | Where-Object {
                $_.Name -in $deleteNames -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $deleteDirectory, [StringComparison]::OrdinalIgnoreCase)
            })
            Assert-True ($remaining.Count -eq 0) "Could not restore $($remaining.Count) Delete test fixtures from the Recycle Bin."
        }
    } finally {
        $window.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $pathviewType = $assembly.GetType('SUTWinExplorer.Pathview', $true)
    $pathviewConstructor = $pathviewType.GetConstructors()[0]
    $fixedPathview = $pathviewConstructor.Invoke([object[]] @([string] $directory, [bool] $false, $null, $null, $null, $null))
    $browsePathview = $pathviewConstructor.Invoke([object[]] @([string] $directory, [bool] $true, $null, $null, $null, $null))
    $fixedWindow = [System.Windows.Window]::new()
    try {
        $fixedWindow.ShowInTaskbar = $false
        $fixedWindow.Left = -20000
        $fixedWindow.Top = -20000
        $fixedWindow.Width = 1600
        $fixedWindow.Height = 650
        $sidebarGrid = [System.Windows.Controls.Grid]::new()
        $sidebarGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
        $sidebarGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
        [System.Windows.Controls.Grid]::SetColumn($browsePathview, 1)
        $null = $sidebarGrid.Children.Add($fixedPathview)
        $null = $sidebarGrid.Children.Add($browsePathview)
        $fixedWindow.Content = $sidebarGrid
        $fixedWindow.Show()
        $fixedWindow.UpdateLayout()
        $subfolderList = $fixedPathview.FindName('ActivePathSubfoldersList')
        $subfolderEntry = @($subfolderList.Items | Where-Object { $_.Path -eq (Join-Path $directory 'OtherFolder') })[0]
        $siblingsTree = $browsePathview.FindName('ActivePathAndSiblingsTree')
        $treeEntry = Find-TreeEntry $siblingsTree.Items[0] (Join-Path $directory 'RenamedFolder')
        Assert-True ($null -ne $subfolderEntry -and $null -ne $treeEntry) 'Directory sidebar menu test entries were not found.'
        $showDirectoryMenu = $pathviewType.GetMethod('ShowDirectoryMenu', $viewFlags)
        foreach ($menuKind in @('base', 'content', 'none', 'base')) {
            foreach ($case in @(@{ View = $fixedPathview; Window = $fixedWindow; Entry = $subfolderEntry; Tree = $false },
                                @{ View = $browsePathview; Window = $fixedWindow; Entry = $treeEntry; Tree = $true })) {
                $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($case.Window).Handle
                $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
                try {
                    $null = $showDirectoryMenu.Invoke($case.View, [object[]] @($case.Entry.PSObject.BaseObject, [bool] $case.Tree, [bool] $true))
                    if ($menuKind -eq 'none') {
                        Assert-True ($menuProbe.ItemCount -eq -1) 'The third sidebar click displayed a menu.'
                        continue
                    }
                    $isBase = $menuProbe.ItemCount -ge 9 -and ($menuProbe.Items[0..8] -join ',') -ceq 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete'
                    Assert-True ($isBase -eq ($menuKind -eq 'base')) "Sidebar menu did not alternate independently: tree=$($case.Tree), expected=$menuKind, count=$($menuProbe.ItemCount), path=$($case.Entry.Path), exists=$([IO.Directory]::Exists($case.Entry.Path)), items=$($menuProbe.Items -join '|')."
                    if ($isBase) {
                        Assert-True (($menuProbe.States[0] -band 3) -eq 0 -and ($menuProbe.States[1] -band 3) -eq 0 -and
                            ($menuProbe.States[2] -band 3) -eq 0 -and ($menuProbe.States[8] -band 3) -eq 0) 'Sidebar directory action states were incorrect.'
                    }
                } finally { $menuProbe.Dispose() }
            }
        }
        $sidebarController = $pathviewType.GetField('_subfolderContextMenu', $viewFlags).GetValue($fixedPathview)
        foreach ($operation in @('Copy', 'Move')) {
            $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
            $workflow.Prepare([string[]] @($subfolderEntry.Path))
            $null = $sidebarController.GetType().GetMethod('Reset', $viewFlags).Invoke($sidebarController, @())
            $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle
            $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
            $menuProbe.SelectIndex = if ($operation -eq 'Copy') { 3 } else { 6 }
            try {
                $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true))
                Assert-True (($menuProbe.States[0] -band 3) -ne 0 -and ($menuProbe.States[1] -band 3) -ne 0 -and
                    ($menuProbe.States[2] -band 3) -ne 0 -and ($menuProbe.States[$menuProbe.SelectIndex] -band 3) -eq 0 -and
                    -not $workflow.IsPrepared) "The sidebar background $operation action did not match the workflow state."
            } finally { $menuProbe.Dispose(); $workflow.Abort() }
        }
        foreach ($case in @(@{ View = $fixedPathview; Window = $fixedWindow; Entry = $subfolderEntry; Tree = $false },
                            @{ View = $browsePathview; Window = $fixedWindow; Entry = $treeEntry; Tree = $true })) {
            $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($case.Window).Handle
            foreach ($operation in @('Copy', 'Move')) {
                $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
                $menuProbe.SelectIndex = if ($operation -eq 'Copy') { 2 } else { 5 }
                try { $null = $showDirectoryMenu.Invoke($case.View, [object[]] @($case.Entry.PSObject.BaseObject, [bool] $case.Tree, [bool] $false)) }
                finally { $menuProbe.Dispose() }
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                Assert-True ($workflow.IsPrepared -and @($workflow.PreparedPaths).Count -eq 1 -and
                    @($workflow.PreparedPaths)[0] -eq $case.Entry.Path) "Sidebar $operation targeted the wrong selection."
                $workflow.Abort()
            }
        }
        $originalCursor = [SutShellRightClickProbe]::CursorPosition()
        try {
            $fixedWindow.Left = 20
            $fixedWindow.Top = 20
            $fixedWindow.Activate() | Out-Null
            $subfolderEntry = @($subfolderList.Items | Where-Object { $_.Path -eq (Join-Path $directory 'OtherFolder') })[0]
            $treeEntry = Find-TreeEntry $siblingsTree.Items[0] (Join-Path $directory 'RenamedFolder')
            $subfolderList.ScrollIntoView($subfolderEntry)
            $fixedWindow.UpdateLayout()
            $backgroundPoint = Find-ListBackgroundPoint $subfolderList
            $rightClickProbe = [SutShellRightClickProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle,
                [int] $backgroundPoint.X, [int] $backgroundPoint.Y, [int] $backgroundPoint.X, [int] $backgroundPoint.Y)
            $rightClickProbe.AdditionalClicks = 2
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $newParent[0].Text -in $rightClickProbe.SecondItems -and $rightClickProbe.NoMenuObserved -and
                    $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0]) 'Sidebar background clicks did not follow the three-step sequence.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $subfolderContainer = $subfolderList.ItemContainerGenerator.ContainerFromItem($subfolderEntry)
            $treeContainer = Find-TreeContainer $siblingsTree $treeEntry
            Assert-True ($null -ne $subfolderContainer -and $null -ne $treeContainer) "Sidebar right-click test entries were not realized: list=$($null -ne $subfolderContainer), tree=$($null -ne $treeContainer), treeEntry=$($null -ne $treeEntry)."
            foreach ($container in @($subfolderContainer, $treeContainer)) {
                $container.BringIntoView()
                $fixedWindow.UpdateLayout()
                $point = $container.PointToScreen([System.Windows.Point]::new(10, $container.ActualHeight / 2))
                $rightClickProbe = [SutShellRightClickProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle,
                    [int] $point.X, [int] $point.Y, [int] $point.X, [int] $point.Y)
                $rightClickProbe.AdditionalClicks = 2
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                        $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0]) "Sidebar right-click alternation failed: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
        } finally { [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1]) }
        $activeTree = $fixedPathview.FindName('ActivePathTree')
        $treeItem = $activeTree.ItemContainerGenerator.ContainerFromIndex(0)
        Assert-True ($null -ne $treeItem) 'The fixed Active path tree was not realized.'
        $menuProbe = [SutShellMenuProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle)
        try {
            $event = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Right)
            $event.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent
            $treeItem.RaiseEvent($event)
            Assert-True ($menuProbe.ItemCount -gt 0 -and ($menuProbe.ItemCount -lt 9 -or
                ($menuProbe.Items[0..8] -join ',') -cne 'Rename,Path get,Copy get,Copy abort,Copy paste,Move get,Move abort,Move paste,Delete')) "The fixed Active path tree did not show a native menu: count=$($menuProbe.ItemCount), items=$($menuProbe.Items -join '|')."
        } finally { $menuProbe.Dispose() }
    } finally {
        $fixedWindow.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $profileDirectory = Join-Path $directory 'profiles'
    $storeType = $assembly.GetType('SUTWinExplorer.ProfileStore', $true)
    $store = $storeType.GetConstructor([type[]] @([string], [string])).Invoke([object[]] @([string] $profileDirectory, [string] 'default'))
    $profile = $store.LoadOrCreate()
    $application.GetType().GetMethod('SetActiveProfile', $viewFlags).Invoke($application, [object[]] @($store, $profile))
    $mainWindow = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.MainWindow', $true))
    $mainWindow.ShowInTaskbar = $false
    $mainWindow.Left = -20000
    $mainWindow.Top = -20000
    $mainWindow.Show()
    try {
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.Window = $mainWindow
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        $browseStatus = if ($null -ne $probe.ContentView) { $probe.ContentView.FindName('StatusLabel').Text } else { 'no ContentView' }
        Assert-True $probe.Ready "BROWSE startup did not render a Shell icon: $($probe.Error); status=$browseStatus"
        $mainView = $probe.ContentView
        $null = $mainView.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($mainView, [object[]] @([string] $directory))
        $null = $mainView.GetType().GetMethod('Refresh', $viewFlags).Invoke($mainView, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $mainView.FindName('FileList')
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "MainWindow content did not load: $($probe.Error)"
        $mainList = $mainView.FindName('FileList')
        $mainNotes = @($mainList.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'renamed-notes.txt') })[0]
        $mainOther = $mainList.Items[($mainList.Items.IndexOf($mainNotes) + 1) % $mainList.Items.Count]
        $mainWindow.Width = 1000
        $mainWindow.Height = 700
        $mainWindow.Left = 20
        $mainWindow.Top = 20
        $mainWindow.Activate() | Out-Null
        $mainWindow.UpdateLayout()
        $mainList.ScrollIntoView($mainOther)
        $mainList.UpdateLayout()
        $notesContainer = $mainList.ItemContainerGenerator.ContainerFromItem($mainNotes)
        $otherContainer = $mainList.ItemContainerGenerator.ContainerFromItem($mainOther)
        Assert-True ($null -ne $notesContainer -and $null -ne $otherContainer) "MainWindow test rows were not realized: notes=$($null -ne $mainNotes), other=$($null -ne $mainOther), notesContainer=$($null -ne $notesContainer), otherContainer=$($null -ne $otherContainer), visible=$($mainList.IsVisible), size=$($mainList.ActualWidth)x$($mainList.ActualHeight)."
        $startPoint = $notesContainer.PointToScreen([System.Windows.Point]::new(200, $notesContainer.ActualHeight / 2))
        $samePoint = $notesContainer.PointToScreen([System.Windows.Point]::new(10, $notesContainer.ActualHeight / 2))
        $otherPoint = $otherContainer.PointToScreen([System.Windows.Point]::new(10, $otherContainer.ActualHeight / 2))
        $mainOwner = [System.Windows.Interop.WindowInteropHelper]::new($mainWindow).Handle
        foreach ($target in @('double', 'same', 'other')) {
            $mainList.SelectedItems.Clear()
            $mainList.SelectedItem = $mainNotes
            $origin = if ($target -eq 'double') { $samePoint } else { $startPoint }
            $destination = if ($target -eq 'other') { $otherPoint } else { $samePoint }
            $hitSource = $mainList.InputHitTest($mainList.PointFromScreen($origin))
            $hitPath = [System.Collections.Generic.List[string]]::new()
            $hitAncestor = $hitSource
            while ($null -ne $hitAncestor) {
                $hitPath.Add($hitAncestor.GetType().Name)
                $hitAncestor = [System.Windows.Media.VisualTreeHelper]::GetParent($hitAncestor)
            }
            $rightClickProbe = [SutShellRightClickProbe]::new($mainOwner, [int] $origin.X, [int] $origin.Y, [int] $destination.X, [int] $destination.Y)
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(7)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                $expectedRow = if ($target -eq 'other') { $mainOther } else { $mainNotes }
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and
                    $rightClickProbe.SecondWasBase -eq ($target -eq 'other') -and $mainList.SelectedItems.Count -eq 1 -and
                    $mainList.SelectedItem.Entry.FullPath -eq $expectedRow.Entry.FullPath) "MainWindow right-click failed for target=$target`: first=$($rightClickProbe.FirstMenu), firstLabel=$($rightClickProbe.ObservedFirstLabel), start=$($origin.X),$($origin.Y), actualStart=$($rightClickProbe.ActualStart -join ','), startClass=$($rightClickProbe.StartClass), hit=$($hitPath -join '/'), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($mainList.SelectedItems.Count), selected=$($mainList.SelectedItem.Entry.FullPath)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
        }
    } finally {
        $mainWindow.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    'SutShell tests passed.'
} finally {
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}