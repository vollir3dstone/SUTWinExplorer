using System.IO;
using System.Text.Json;

namespace SUTWinExplorer;

internal enum MediaType
{
    None,
    Executable,
    LinesText,
    Book,
    StructuredData,
    Image,
    Audio,
    Video,
    Box,
    CommandData,
    Directory,
    ShellLink,
    Url,
    Ambiguous
}

internal enum MediaTypeSubType
{
    WITHOUT_SUBTYPE,
    LINES_TEXT_TEXT_BASED,
    STRUCTURED_DATA_TEXT_BASED,
    STRUCTURED_DATA_APP_SPECIFIC,
    COMMAND_DATA_TEXT_BASED,
    BOOK_RENDER,
    BOOK_EDIT,
    IMAGE_RENDER,
    IMAGE_EDIT,
    AUDIO_RENDER,
    VIDEO_RENDER
}

internal static class MediaTypeMap
{
    private const string ResourceName = "SUTWinExplorer.MediaTypes.json";
    private static readonly IReadOnlyDictionary<string, (MediaType Type, MediaTypeSubType MediaTypeSubType)> TypesByExtension = Load();

    public static MediaType GetMediaType(string path, bool isDirectory)
    {
        if (isDirectory)
            return MediaType.Directory;

        var extension = Path.GetExtension(path);
        if (string.Equals(extension, ".lnk", StringComparison.OrdinalIgnoreCase))
            return MediaType.ShellLink;
        else if (string.Equals(extension, ".url", StringComparison.OrdinalIgnoreCase))
            return MediaType.Url;

        return TypesByExtension.TryGetValue(extension, out var type) ? type.Type : MediaType.None;
    }

    public static MediaTypeSubType GetMediaTypeSubType(string path, bool isDirectory)
    {
        if (isDirectory)
            return MediaTypeSubType.WITHOUT_SUBTYPE;

        var extension = Path.GetExtension(path);
        if (string.Equals(extension, ".lnk", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(extension, ".url", StringComparison.OrdinalIgnoreCase))
            return MediaTypeSubType.WITHOUT_SUBTYPE;

        return TypesByExtension.TryGetValue(extension, out var type) ? type.MediaTypeSubType : MediaTypeSubType.WITHOUT_SUBTYPE;
    }

    public static string GetName(MediaType type) => type switch
    {
        MediaType.None => string.Empty,
        MediaType.Executable => "executable",
        MediaType.LinesText => "lines-text",
        MediaType.Url => "url",
        MediaType.Book => "book",
        MediaType.StructuredData => "structured-data",
        MediaType.Image => "image",
        MediaType.Audio => "audio",
        MediaType.Video => "video",
        MediaType.CommandData => "command-data",
        MediaType.Directory => "directory",
        MediaType.ShellLink => "shell-link",
        MediaType.Box => "box",
        MediaType.Ambiguous => "ambiguous",
        _ => throw new ArgumentOutOfRangeException(nameof(type), type, "Unsupported media type.")
    };

    public static string FormatMediaTypeSubType(MediaTypeSubType mediaTypeSubType) => mediaTypeSubType switch
    {
        MediaTypeSubType.WITHOUT_SUBTYPE => string.Empty,
        MediaTypeSubType.LINES_TEXT_TEXT_BASED or MediaTypeSubType.STRUCTURED_DATA_TEXT_BASED or
            MediaTypeSubType.COMMAND_DATA_TEXT_BASED => "TB",
        MediaTypeSubType.STRUCTURED_DATA_APP_SPECIFIC => "AS",
        MediaTypeSubType.BOOK_RENDER or MediaTypeSubType.IMAGE_RENDER or MediaTypeSubType.AUDIO_RENDER or
            MediaTypeSubType.VIDEO_RENDER => "RE",
        MediaTypeSubType.BOOK_EDIT or MediaTypeSubType.IMAGE_EDIT => "ED",
        _ => throw new ArgumentOutOfRangeException(nameof(mediaTypeSubType), mediaTypeSubType, "Unsupported media type sub type.")
    };

    private static Dictionary<string, (MediaType Type, MediaTypeSubType MediaTypeSubType)> Load()
    {
        using var stream = typeof(MediaTypeMap).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException($"Embedded media type mapping '{ResourceName}' is missing.");
        using var document = JsonDocument.Parse(stream);
        var types = new Dictionary<string, (MediaType Type, MediaTypeSubType MediaTypeSubType)>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in document.RootElement.GetProperty("types").EnumerateArray())
        {
            var typeName = entry.GetProperty("type").GetString();
            if (string.IsNullOrWhiteSpace(typeName))
                throw new InvalidDataException("A media type name is missing or empty.");

            var type = typeName switch
            {
                "executable" => MediaType.Executable,
                "lines-text" => MediaType.LinesText,
                "book" => MediaType.Book,
                "structured-data" => MediaType.StructuredData,
                "image" => MediaType.Image,
                "audio" => MediaType.Audio,
                "video" => MediaType.Video,
                "box" => MediaType.Box,
                "command-data" => MediaType.CommandData,
                _ => throw new InvalidDataException($"Unsupported media type '{typeName}'.")
            };

            var extensions = entry.GetProperty("extensions");
            if (extensions.ValueKind == JsonValueKind.Array)
            {
                AddExtensions(types, extensions, type, MediaTypeSubType.WITHOUT_SUBTYPE, typeName);
                continue;
            }

            foreach (var group in extensions.EnumerateObject())
            {
                var mediaTypeSubType = (type, group.Name) switch
                {
                    (MediaType.LinesText, "text-based") => MediaTypeSubType.LINES_TEXT_TEXT_BASED,
                    (MediaType.StructuredData, "text-based") => MediaTypeSubType.STRUCTURED_DATA_TEXT_BASED,
                    (MediaType.StructuredData, "app-specific") => MediaTypeSubType.STRUCTURED_DATA_APP_SPECIFIC,
                    (MediaType.CommandData, "text-based") => MediaTypeSubType.COMMAND_DATA_TEXT_BASED,
                    (MediaType.Book, "render") => MediaTypeSubType.BOOK_RENDER,
                    (MediaType.Book, "edit") => MediaTypeSubType.BOOK_EDIT,
                    (MediaType.Image, "render") => MediaTypeSubType.IMAGE_RENDER,
                    (MediaType.Image, "edit") => MediaTypeSubType.IMAGE_EDIT,
                    (MediaType.Audio, "render") => MediaTypeSubType.AUDIO_RENDER,
                    (MediaType.Video, "render") => MediaTypeSubType.VIDEO_RENDER,
                    _ => throw new InvalidDataException($"Unsupported media type sub type '{typeName}/{group.Name}'.")
                };
                AddExtensions(types, group.Value, type, mediaTypeSubType, typeName);
            }
        }

        return types;
    }

    private static void AddExtensions(Dictionary<string, (MediaType Type, MediaTypeSubType MediaTypeSubType)> types,
        JsonElement extensions, MediaType type, MediaTypeSubType mediaTypeSubType, string typeName)
    {
        foreach (var extensionElement in extensions.EnumerateArray())
        {
            var extension = extensionElement.GetString();
            if (string.IsNullOrWhiteSpace(extension) || extension[0] != '.' || extension.Length == 1)
                throw new InvalidDataException($"Invalid extension in media type '{typeName}'.");

            if (types.TryGetValue(extension, out var existing))
            {
                if (existing.Type != type)
                    types[extension] = (MediaType.Ambiguous, MediaTypeSubType.WITHOUT_SUBTYPE);
                else if (existing.MediaTypeSubType != mediaTypeSubType)
                    types[extension] = (type, MediaTypeSubType.WITHOUT_SUBTYPE);
            }
            else
            {
                types.Add(extension, (type, mediaTypeSubType));
            }
        }
    }
}
