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
    private const string FileSystemPrefix = "filesystem:";
    private static readonly JsonSerializerOptions JsonOptions = new() { MaxDepth = 1024 };
    private readonly object _sync = new();
    private readonly string _filePath;
    private CacheDocument _document = new();
    private readonly Dictionary<string, BitmapSource> _decoded = new(StringComparer.Ordinal);

    internal IconCache(string filePath) => _filePath = filePath;

    internal event Action<string>? FileSystemRootAdded;

    internal string[] GetFileSystemRoots()
    {
        lock (_sync)
            return _document.Roots.Keys.Where(key => key.StartsWith(FileSystemPrefix, StringComparison.OrdinalIgnoreCase))
                .Select(key => key[FileSystemPrefix.Length..] + Path.DirectorySeparatorChar).ToArray();
    }

    internal CachedItem[] GetFileSystemItems()
    {
        lock (_sync)
        {
            var items = new List<CachedItem>();
            var pending = new Stack<(string Path, CacheNode Node)>();
            foreach (var (root, node) in _document.Roots)
                if (root.StartsWith(FileSystemPrefix, StringComparison.OrdinalIgnoreCase))
                    pending.Push((root[FileSystemPrefix.Length..] + Path.DirectorySeparatorChar, node));
            while (pending.TryPop(out var entry))
            {
                if (entry.Node.Images is not null)
                {
                    var variants = entry.Node.Images.Select(pair => ParseVariant(pair.Key, pair.Value, entry.Node.VariantVersions.GetValueOrDefault(pair.Key))).OfType<IconVariant>().ToArray();
                    if (variants.Length > 0)
                        items.Add(new CachedItem(entry.Path, variants));
                }
                foreach (var (name, child) in entry.Node.Children)
                    pending.Push((Path.Combine(entry.Path, name), child));
            }
            return items.ToArray();
        }
    }

    internal CachedItem? GetFileSystemItem(string path)
    {
        if (ShellLocations.IsTopPath(path))
            return null;
        lock (_sync)
        {
            var node = GetNode(path, false);
            if (node?.Images is null)
                return null;
            var variants = node.Images.Select(pair => ParseVariant(pair.Key, pair.Value, node.VariantVersions.GetValueOrDefault(pair.Key))).OfType<IconVariant>().ToArray();
            return variants.Length == 0 ? null : new CachedItem(Path.GetFullPath(path), variants);
        }
    }

    internal void InvalidateFileSystemItems(IEnumerable<string> paths)
    {
        lock (_sync)
        {
            foreach (var path in paths)
            {
                var node = GetNode(path, false);
                if (node is null)
                    continue;
                node.Images?.Clear();
                node.VariantVersions.Clear();
                node.BaseIconIndex = null;
            }
        }
    }

    internal void InvalidateAllFileSystemItems()
    {
        lock (_sync)
        {
            var pending = new Stack<CacheNode>(_document.Roots
                .Where(pair => pair.Key.StartsWith(FileSystemPrefix, StringComparison.OrdinalIgnoreCase))
                .Select(pair => pair.Value));
            while (pending.TryPop(out var node))
            {
                node.Images?.Clear();
                node.VariantVersions.Clear();
                node.BaseIconIndex = null;
                foreach (var child in node.Children.Values)
                    pending.Push(child);
            }
        }
    }

    private static IconVariant? ParseVariant(string key, string imageId, long version)
    {
        var separator = key.IndexOf(':');
        var sizeSeparator = key.IndexOf('x', separator + 1);
        if (separator <= 0 || sizeSeparator <= separator + 1 ||
            !int.TryParse(key.AsSpan(separator + 1, sizeSeparator - separator - 1), out var width) ||
            !int.TryParse(key.AsSpan(sizeSeparator + 1), out var height) || width <= 0 || height <= 0)
            return null;
        return new IconVariant(key[..separator], width, height, imageId, version);
    }

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
            var key = SizeKey(variant, width, height);
            if (node?.Images is null || !node.Images.TryGetValue(key, out var id) ||
                !_document.Images.TryGetValue(id, out var image) || !_decoded.TryGetValue(id, out var bitmap))
                return null;
            return new CachedIcon(bitmap, image.HasOverlay, node.BaseIconIndex,
                new IconVariant(variant, width, height, id, node.VariantVersions.GetValueOrDefault(key)));
        }
    }

    internal void Store(string path, string variant, int width, int height, BitmapSource bitmap, bool hasOverlay, int? baseIconIndex)
    {
        var image = PrepareImage(bitmap, hasOverlay);
        var root = ShellLocations.IsTopPath(path) ? null : Path.GetPathRoot(Path.GetFullPath(path));
        var newRoot = false;
        lock (_sync)
        {
            newRoot = root is not null && !_document.Roots.ContainsKey(FileSystemPrefix + root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            AddImage(image);
            var node = GetNode(path, true)!;
            node.Images ??= new Dictionary<string, string>(StringComparer.Ordinal);
            var key = SizeKey(variant, width, height);
            node.Images[key] = image.Id;
            node.VariantVersions[key] = ++node.NextVariantVersion;
            if (baseIconIndex.HasValue)
                node.BaseIconIndex = baseIconIndex;
        }
        if (newRoot)
            FileSystemRootAdded?.Invoke(root!);
    }

    internal IconVariant? ReplaceCachedItem(CachedItem item, IReadOnlyList<RefreshedVariant> variants, int? baseIconIndex)
    {
        var prepared = variants.Select(variant => (variant.Variant,
            Image: variant.Bitmap is null ? null : PrepareImage(variant.Bitmap, variant.HasOverlay))).ToArray();
        IconVariant? updatedSmall = null;
        lock (_sync)
        {
            var node = GetNode(item.Path, false);
            if (node?.Images is null)
                return null;
            foreach (var (variant, image) in prepared)
            {
                var key = SizeKey(variant.Name, variant.Width, variant.Height);
                if (!node.Images.TryGetValue(key, out var currentId) || currentId != variant.ImageId ||
                    node.VariantVersions.GetValueOrDefault(key) != variant.Version)
                    continue;
                if (image is null)
                    node.Images.Remove(key);
                else
                {
                    AddImage(image);
                    node.Images[key] = image.Id;
                }
                node.VariantVersions[key] = ++node.NextVariantVersion;
                if (variant.Name == "small" && variant.Width == 16 && variant.Height == 16)
                {
                    node.BaseIconIndex = image is null ? null : baseIconIndex;
                    if (image is not null)
                        updatedSmall = variant with { ImageId = image.Id, Version = node.VariantVersions[key] };
                }
            }
        }
        return updatedSmall;
    }

    private static PreparedImage PrepareImage(BitmapSource bitmap, bool hasOverlay)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        var bytes = stream.ToArray();
        if (!bitmap.IsFrozen)
            bitmap.Freeze();
        return new PreparedImage(Convert.ToHexString(SHA256.HashData(bytes)) + (hasOverlay ? "-1" : "-0"),
            new CacheImage { Width = bitmap.PixelWidth, Height = bitmap.PixelHeight,
                Png = Convert.ToBase64String(bytes), HasOverlay = hasOverlay }, bitmap);
    }

    private void AddImage(PreparedImage image)
    {
        if (_document.Images.TryAdd(image.Id, image.Image))
            _decoded.Add(image.Id, image.Bitmap);
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
            root = FileSystemPrefix + root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
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

    internal sealed record CachedIcon(BitmapSource Image, bool HasOverlay, int? BaseIconIndex, IconVariant Variant);
    private sealed record PreparedImage(string Id, CacheImage Image, BitmapSource Bitmap);
    internal sealed record IconVariant(string Name, int Width, int Height, string ImageId, long Version);
    internal sealed record CachedItem(string Path, IconVariant[] Variants);
    internal sealed record RefreshedVariant(IconVariant Variant, BitmapSource? Bitmap, bool HasOverlay);

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
        [System.Text.Json.Serialization.JsonIgnore]
        internal Dictionary<string, long> VariantVersions { get; } = new(StringComparer.Ordinal);
        [System.Text.Json.Serialization.JsonIgnore]
        internal long NextVariantVersion { get; set; }
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