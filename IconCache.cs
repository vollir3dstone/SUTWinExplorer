using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Media.Imaging;

namespace SUTWinExplorer;

internal sealed class IconCache
{
    private const string DocumentType = "IconCache";
    private static readonly JsonSerializerOptions JsonOptions = new() { MaxDepth = 1024 };
    private readonly object _sync = new();
    private readonly string _filePath;
    private CacheDocument _document = new();
    private readonly Dictionary<string, BitmapSource> _decoded = new(StringComparer.Ordinal);

    internal IconCache(string filePath) => _filePath = filePath;

    internal void Load()
    {
        lock (_sync)
        {
            try
            {
                if (!File.Exists(_filePath))
                    return;
                var document = JsonSerializer.Deserialize<CacheDocument>(File.ReadAllText(_filePath), JsonOptions);
                if (document is null || document.Type != DocumentType || document.Version != 1 ||
                    document.Roots is null || document.Images is null)
                    throw new InvalidDataException("Invalid icon cache document.");
                var decoded = new Dictionary<string, BitmapSource>(StringComparer.Ordinal);
                foreach (var (id, image) in document.Images)
                {
                    if (image is null || image.Png is null || image.Width <= 0 || image.Height <= 0)
                        throw new InvalidDataException("Invalid icon cache image.");
                    using var stream = new MemoryStream(Convert.FromBase64String(image.Png));
                    var bitmap = new BitmapImage();
                    bitmap.BeginInit();
                    bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.StreamSource = stream;
                    bitmap.EndInit();
                    bitmap.Freeze();
                    if (bitmap.PixelWidth != image.Width || bitmap.PixelHeight != image.Height)
                        throw new InvalidDataException("Invalid icon cache image dimensions.");
                    decoded.Add(id, bitmap);
                }
                document.Roots = NormalizeNodes(document.Roots, document.Images);
                _document = document;
                _decoded.Clear();
                foreach (var (id, bitmap) in decoded)
                    _decoded.Add(id, bitmap);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or
                                               FormatException or InvalidDataException or NotSupportedException or ArgumentException or ExternalException)
            {
                Debug.WriteLine($"Could not load icon cache: {exception.Message}");
                _document = new CacheDocument();
                _decoded.Clear();
            }
        }
    }

    internal void Save()
    {
        lock (_sync)
        {
            string? temporary = null;
            try
            {
                var directory = Path.GetDirectoryName(_filePath)!;
                Directory.CreateDirectory(directory);
                temporary = Path.Combine(directory, $".{Path.GetFileName(_filePath)}.{Guid.NewGuid():N}.tmp");
                File.WriteAllText(temporary, JsonSerializer.Serialize(_document, JsonOptions));
                File.Move(temporary, _filePath, true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or NotSupportedException or JsonException)
            {
                Debug.WriteLine($"Could not save icon cache: {exception.Message}");
            }
            finally
            {
                if (temporary is not null)
                    try { File.Delete(temporary); }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                    { Debug.WriteLine($"Could not remove temporary icon cache: {exception.Message}"); }
            }
        }
    }

    internal CachedIcon? Find(string path, string variant, int width, int height)
    {
        lock (_sync)
        {
            var node = GetNode(path, false);
            if (node?.Images is null || !node.Images.TryGetValue(SizeKey(variant, width, height), out var id) ||
                !_document.Images.TryGetValue(id, out var image) || !_decoded.TryGetValue(id, out var bitmap))
                return null;
            return new CachedIcon(bitmap, image.HasOverlay, node.BaseIconIndex);
        }
    }

    internal void Store(string path, string variant, int width, int height, BitmapSource bitmap, bool hasOverlay, int? baseIconIndex)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        var bytes = stream.ToArray();
        var id = Convert.ToHexString(SHA256.HashData(bytes)) + (hasOverlay ? "-1" : "-0");
        lock (_sync)
        {
            if (!_document.Images.ContainsKey(id))
            {
                if (!bitmap.IsFrozen)
                    bitmap.Freeze();
                _document.Images.Add(id, new CacheImage
                {
                    Width = bitmap.PixelWidth, Height = bitmap.PixelHeight,
                    Png = Convert.ToBase64String(bytes), HasOverlay = hasOverlay
                });
                _decoded.Add(id, bitmap);
            }
            var node = GetNode(path, true)!;
            node.Images ??= new Dictionary<string, string>(StringComparer.Ordinal);
            node.Images[SizeKey(variant, width, height)] = id;
            if (baseIconIndex.HasValue)
                node.BaseIconIndex = baseIconIndex;
        }
    }

    private CacheNode? GetNode(string path, bool create)
    {
        string root;
        string[] components;
        if (ShellLocations.IsTopPath(path))
        {
            root = "shell:" + ShellLocations.TopPath;
            components = [];
        }
        else
        {
            var fullPath = Path.GetFullPath(path);
            root = Path.GetPathRoot(fullPath) ?? throw new ArgumentException("Path has no root.", nameof(path));
            root = "filesystem:" + root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            components = fullPath[Path.GetPathRoot(fullPath)!.Length..]
                .Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
        }
        var nodes = _document.Roots;
        CacheNode? node = null;
        foreach (var part in new[] { root }.Concat(components))
        {
            if (!nodes.TryGetValue(part, out node))
            {
                if (!create)
                    return null;
                node = new CacheNode();
                nodes.Add(part, node);
            }
            nodes = node.Children;
        }
        return node;
    }

    private static Dictionary<string, CacheNode> NormalizeNodes(Dictionary<string, CacheNode> nodes, Dictionary<string, CacheImage> images)
    {
        var result = new Dictionary<string, CacheNode>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, node) in nodes)
        {
            if (node is null || node.Children is null || node.Images?.Values.Any(id => id is null || !images.ContainsKey(id)) == true)
                throw new InvalidDataException("Invalid icon cache tree.");
            node.Children = NormalizeNodes(node.Children, images);
            result.Add(name, node);
        }
        return result;
    }

    private static string SizeKey(string variant, int width, int height) => $"{variant}:{width}x{height}";

    internal sealed record CachedIcon(BitmapSource Image, bool HasOverlay, int? BaseIconIndex);

    public sealed class CacheDocument
    {
        [System.Text.Json.Serialization.JsonPropertyName("_type")]
        [System.Text.Json.Serialization.JsonRequired]
        public string Type { get; set; } = DocumentType;
        [System.Text.Json.Serialization.JsonRequired]
        public int Version { get; set; } = 1;
        [System.Text.Json.Serialization.JsonRequired]
        public Dictionary<string, CacheNode> Roots { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        [System.Text.Json.Serialization.JsonRequired]
        public Dictionary<string, CacheImage> Images { get; set; } = new(StringComparer.Ordinal);
    }

    public sealed class CacheNode
    {
        [System.Text.Json.Serialization.JsonRequired]
        public Dictionary<string, CacheNode> Children { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, string>? Images { get; set; }
        public int? BaseIconIndex { get; set; }
    }

    public sealed class CacheImage
    {
        [System.Text.Json.Serialization.JsonRequired]
        public int Width { get; set; }
        [System.Text.Json.Serialization.JsonRequired]
        public int Height { get; set; }
        [System.Text.Json.Serialization.JsonRequired]
        public string Png { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonRequired]
        public bool HasOverlay { get; set; }
    }
}