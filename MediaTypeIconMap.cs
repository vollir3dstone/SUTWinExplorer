using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SUTWinExplorer;

internal static class MediaTypeIconMap
{
    private static readonly IReadOnlyDictionary<MediaType, ImageSource> Icons = CreateIcons();

    public static ImageSource? GetIcon(MediaType type) => type == MediaType.None
        ? null
        : Icons.TryGetValue(type, out var icon)
            ? icon
            : throw new ArgumentOutOfRangeException(nameof(type), type, "No icon is defined for this media type.");

    private static Dictionary<MediaType, ImageSource> CreateIcons() => new()
    {
        [MediaType.Executable] = LoadAsset("type_exe 16.png"),
        [MediaType.LinesText] = LoadAsset("type_lines_text 16.png"),
        [MediaType.Book] = LoadAsset("type_book 16.png"),
        [MediaType.StructuredData] = LoadAsset("type_structured_data 16.png"),
        [MediaType.Image] = LoadAsset("type_image 16.png"),
        [MediaType.Audio] = LoadAsset("type_audio 16.png"),
        [MediaType.Video] = LoadAsset("type_video 16.png"),
        [MediaType.CommandData] = LoadAsset("type_command_data 16.png"),
        [MediaType.Directory] = LoadFolderIcon(),
        [MediaType.ShellLink] = LoadAsset("type_shell_link 16.png"),
        [MediaType.Url] = LoadAsset("type_url 16.png"),
        [MediaType.Ambiguous] = CreateWarningIcon()
    };

    private static BitmapSource LoadAsset(string name)
    {
        var uri = new Uri($"/Assets/{name}", UriKind.Relative);
        var resource = Application.GetResourceStream(uri)
            ?? throw new InvalidOperationException($"Media type icon '{name}' is missing.");
        using var stream = resource.Stream;
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private static BitmapSource LoadFolderIcon()
    {
        const uint stockFolder = 3;
        const uint stockIcon = 0x100;
        const uint stockSmallIcon = 1;
        var info = new StockIconInfo { Size = (uint)Marshal.SizeOf<StockIconInfo>(), Path = string.Empty };
        Marshal.ThrowExceptionForHR(SHGetStockIconInfo(stockFolder, stockIcon | stockSmallIcon, ref info));
        if (info.Icon == IntPtr.Zero)
            throw new InvalidOperationException("The Windows folder icon is unavailable.");

        try
        {
            var image = Imaging.CreateBitmapSourceFromHIcon(
                info.Icon, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(16, 16));
            image.Freeze();
            return image;
        }
        finally
        {
            _ = DestroyIcon(info.Icon);
        }
    }

    private static DrawingImage CreateWarningIcon()
    {
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(
            Brushes.Transparent, null, new RectangleGeometry(new Rect(0, 0, 16, 16))));
        drawing.Children.Add(new GeometryDrawing(
            Brushes.Gold,
            new Pen(Brushes.Black, 1),
            Geometry.Parse("M 8,1 L 15,14 L 1,14 Z")));
        drawing.Children.Add(new GeometryDrawing(
            Brushes.Black,
            null,
            Geometry.Parse("M 7.25,4.5 H 8.75 V 10 H 7.25 Z M 7.25,11.3 H 8.75 V 12.8 H 7.25 Z")));
        var image = new DrawingImage(drawing);
        image.Freeze();
        return image;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StockIconInfo
    {
        public uint Size;
        public IntPtr Icon;
        public int SystemIconIndex;
        public int IconIndex;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string Path;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHGetStockIconInfo(uint identifier, uint flags, ref StockIconInfo info);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);
}
