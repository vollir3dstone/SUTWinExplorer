using System.IO;
using System.Text.Json;

namespace SUTWinExplorer;

internal enum MediaType
{
    None,
    Executable,
    Book,
    StructuredData,
    Image,
    Audio,
    Video,
    CommandData,
    Directory,
    ShellLink,
    Ambiguous
}

internal static class MediaTypeMap
{
    private const string ResourceName = "SUTWinExplorer.MediaTypes.json";
    private static readonly IReadOnlyDictionary<string, MediaType> TypesByExtension = Load();

    public static MediaType GetMediaType(string path, bool isDirectory)
    {
        if (isDirectory)
            return MediaType.Directory;

        var extension = Path.GetExtension(path);
        if (string.Equals(extension, ".lnk", StringComparison.OrdinalIgnoreCase))
            return MediaType.ShellLink;

        return TypesByExtension.TryGetValue(extension, out var type) ? type : MediaType.None;
    }

    public static string GetName(MediaType type) => type switch
    {
        MediaType.None => string.Empty,
        MediaType.Executable => "executable",
        MediaType.Book => "book",
        MediaType.StructuredData => "structured-data",
        MediaType.Image => "image",
        MediaType.Audio => "audio",
        MediaType.Video => "video",
        MediaType.CommandData => "command-data",
        MediaType.Directory => "directory",
        MediaType.ShellLink => "shell-link",
        MediaType.Ambiguous => "ambiguous",
        _ => throw new ArgumentOutOfRangeException(nameof(type), type, "Unsupported media type.")
    };

    private static Dictionary<string, MediaType> Load()
    {
        using var stream = typeof(MediaTypeMap).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException($"Embedded media type mapping '{ResourceName}' is missing.");
        using var document = JsonDocument.Parse(stream);
        var types = new Dictionary<string, MediaType>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in document.RootElement.GetProperty("types").EnumerateArray())
        {
            var typeName = entry.GetProperty("type").GetString();
            if (string.IsNullOrWhiteSpace(typeName))
                throw new InvalidDataException("A media type name is missing or empty.");

            var type = typeName switch
            {
                "executable" => MediaType.Executable,
                "book" => MediaType.Book,
                "structured-data" => MediaType.StructuredData,
                "image" => MediaType.Image,
                "audio" => MediaType.Audio,
                "video" => MediaType.Video,
                "command-data" => MediaType.CommandData,
                _ => throw new InvalidDataException($"Unsupported media type '{typeName}'.")
            };

            foreach (var extensionElement in entry.GetProperty("extensions").EnumerateArray())
            {
                var extension = extensionElement.GetString();
                if (string.IsNullOrWhiteSpace(extension) || extension[0] != '.' || extension.Length == 1)
                    throw new InvalidDataException($"Invalid extension in media type '{typeName}'.");

                if (types.TryGetValue(extension, out var existing))
                {
                    if (existing != type)
                        types[extension] = MediaType.Ambiguous;
                }
                else
                {
                    types.Add(extension, type);
                }
            }
        }

        return types;
    }
}
