using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SUTWinExplorer;

internal static class ShellMenuIcons
{
    internal static void Apply(IntPtr menu, IReadOnlyList<ShellMenuAction> actions, uint firstCommand, List<IntPtr> bitmaps)
    {
        for (var index = 0; index < actions.Count; index++)
        {
            var command = firstCommand + (uint)index;
            if (GetMenuState(menu, command, 0) == uint.MaxValue || actions[index].IconSource is not { } button)
                continue;
            var bitmap = CreateBitmap(actions[index], button);
            if (bitmap == IntPtr.Zero)
                continue;
            bitmaps.Add(bitmap);
            var item = new MenuItemInfo { Size = (uint)Marshal.SizeOf<MenuItemInfo>(), Mask = 0x80, Bitmap = bitmap };
            if (!SetMenuItemInfo(menu, command, false, ref item))
                throw new InvalidOperationException("Could not set the menu action icon.");
        }
    }

    internal static void Release(IntPtr bitmap) => _ = DeleteObject(bitmap);

    private static IntPtr CreateBitmap(ShellMenuAction action, Button button)
    {
        FrameworkElement icon;
        if (button.Content is StackPanel panel && panel.Children.OfType<Control>().FirstOrDefault() is { Template: not null } source)
            icon = new Control { Template = source.Template, Width = 14, Height = 14, Foreground = SystemColors.MenuTextBrush };
        else if ((action.IsTransfer || action.Id == "Delete") && button.Content is string text)
        {
            var prefixLength = action.Id == "Delete" ? 3 : action.Id.StartsWith("Link", StringComparison.Ordinal) || action.Id.StartsWith("Copy", StringComparison.Ordinal) || action.Id.StartsWith("Move", StringComparison.Ordinal) ? 4 : text.Length;
            if (text.Length <= prefixLength)
                return IntPtr.Zero;
            icon = new TextBlock { Text = text[prefixLength..], FontFamily = button.FontFamily, FontSize = button.FontSize, Foreground = SystemColors.MenuTextBrush };
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
        var dpi = VisualTreeHelper.GetDpi(button);
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetMenuItemInfo(IntPtr menu, uint item, [MarshalAs(UnmanagedType.Bool)] bool byPosition, ref MenuItemInfo info);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateDIBSection(IntPtr device, ref BitmapInfo info, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr bitmap);
}