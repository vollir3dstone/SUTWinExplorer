using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SUTWinExplorer;

internal static class ShellMenuIcons
{
    internal static void Apply(IntPtr menu, IReadOnlyList<ShellMenuAction> actions, uint firstCommand, List<IntPtr> bitmaps, Visual? dpiSource = null)
    {
        for (var index = 0; index < actions.Count; index++)
        {
            var command = firstCommand + (uint)index;
            if (GetMenuState(menu, command, 0) == uint.MaxValue)
                continue;
            var bitmap = CreateBitmap(actions[index], dpiSource);
            if (bitmap == IntPtr.Zero)
                continue;
            bitmaps.Add(bitmap);
            var item = new MenuItemInfo { Size = (uint)Marshal.SizeOf<MenuItemInfo>(), Mask = 0x80, Bitmap = bitmap };
            if (!SetMenuItemInfo(menu, command, false, ref item))
                throw new InvalidOperationException("Could not set the menu action icon.");
        }
    }

    internal static void Release(IntPtr bitmap) => _ = DeleteObject(bitmap);

    internal static ImageSource? GetWindowIcon(IntPtr window)
    {
        if (window == IntPtr.Zero)
            return null;
        var response = SendMessageTimeout(window, 0x007F, new IntPtr(2), IntPtr.Zero, 0x0002, 100, out var icon);
        if (response != IntPtr.Zero && icon == IntPtr.Zero)
            response = SendMessageTimeout(window, 0x007F, IntPtr.Zero, IntPtr.Zero, 0x0002, 100, out icon);
        if (response != IntPtr.Zero && icon == IntPtr.Zero)
            _ = SendMessageTimeout(window, 0x007F, new IntPtr(1), IntPtr.Zero, 0x0002, 100, out icon);
        if (icon == IntPtr.Zero)
            icon = IntPtr.Size == 8 ? GetClassLongPtr(window, -34) : new IntPtr(unchecked((int)GetClassLong(window, -34)));
        if (icon == IntPtr.Zero)
            icon = IntPtr.Size == 8 ? GetClassLongPtr(window, -14) : new IntPtr(unchecked((int)GetClassLong(window, -14)));
        if (icon == IntPtr.Zero)
            return null;
        try
        {
            var image = Imaging.CreateBitmapSourceFromHIcon(icon, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(16, 16));
            image.Freeze();
            return image;
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException or ExternalException)
        {
            return null;
        }
    }

    private static IntPtr CreateBitmap(ShellMenuAction action, Visual? dpiSource)
    {
        FrameworkElement icon;
        var button = action.IconSource;
        if (action.MenuImage is { } imageSource)
            icon = new Image { Source = imageSource, Width = 16, Height = 16, Stretch = Stretch.Uniform };
        else if (button?.Content is StackPanel panel && panel.Children.OfType<Control>().FirstOrDefault() is { Template: not null } source)
            icon = new Control { Template = source.Template, Width = 14, Height = 14, Foreground = SystemColors.MenuTextBrush };
        else if ((action.Id is "LinkMarkItem" or "CopyMarkItem" or "MoveMarkItem" or "LinkExecute" or "CopyExecute" or "MoveExecute" or "Delete") && button?.Content is string text)
        {
            var prefixLength = action.Id == "Delete" ? 3 : action.Id.StartsWith("Link", StringComparison.Ordinal) || action.Id.StartsWith("Copy", StringComparison.Ordinal) || action.Id.StartsWith("Move", StringComparison.Ordinal) ? 4 : text.Length;
            if (text.Length <= prefixLength)
                return IntPtr.Zero;
            icon = new TextBlock { Text = text[prefixLength..], FontFamily = button.FontFamily, FontSize = button.FontSize, Foreground = SystemColors.MenuTextBrush };
        }
        else if (action.Id is "Properties" or "Rename" or "Relocate" or "AbortTransfer")
        {
            var glyph = action.Id switch { "Properties" => "\uE946", "Rename" => "\uE70F", "Relocate" => "\uE8DE", _ => "\uE711" };
            icon = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 14, Foreground = SystemColors.MenuTextBrush };
        }
        else
            return IntPtr.Zero;

        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var container = new Grid { Width = 16, Height = 16 };
        container.Children.Add(icon);
        container.Measure(new Size(16, 16));
        container.Arrange(new Rect(0, 0, 16, 16));
        container.UpdateLayout();
        var dpi = VisualTreeHelper.GetDpi(dpiSource ?? (Visual?)button ?? icon);
        var width = (int)Math.Ceiling(16 * dpi.DpiScaleX);
        var height = (int)Math.Ceiling(16 * dpi.DpiScaleY);
        var image = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        image.Render(container);
        var pixels = new byte[width * height * 4];
        image.CopyPixels(pixels, width * 4, 0);
        var info = new BitmapInfo
        {
            Size = (uint)Marshal.SizeOf<BitmapInfo>(), Width = width, Height = -height,
            Planes = 1, BitCount = 32, ImageSize = (uint)pixels.Length
        };
        var bitmap = CreateDIBSection(IntPtr.Zero, ref info, 0, out var bits, IntPtr.Zero, 0);
        if (bitmap == IntPtr.Zero)
            throw new InvalidOperationException("Could not create the menu action icon.");
        try { Marshal.Copy(pixels, 0, bits, pixels.Length); }
        catch { Release(bitmap); throw; }
        return bitmap;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MenuItemInfo
    {
        public uint Size, Mask, Type, State, Id;
        public IntPtr SubMenu, CheckedBitmap, UncheckedBitmap, ItemData, Text;
        public uint TextLength;
        public IntPtr Bitmap;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfo
    {
        public uint Size;
        public int Width, Height;
        public ushort Planes, BitCount;
        public uint Compression, ImageSize;
        public int XPixelsPerMeter, YPixelsPerMeter;
        public uint ColorsUsed, ColorsImportant;
    }

    [DllImport("user32.dll")]
    private static extern uint GetMenuState(IntPtr menu, uint item, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")]
    private static extern IntPtr GetClassLongPtr(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "GetClassLongW")]
    private static extern uint GetClassLong(IntPtr window, int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetMenuItemInfo(IntPtr menu, uint item, [MarshalAs(UnmanagedType.Bool)] bool byPosition, ref MenuItemInfo info);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateDIBSection(IntPtr device, ref BitmapInfo info, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr bitmap);
}