using System.IO;
using System.Text.Json;

namespace SUTWinExplorer;

internal static class MediaTypeMap
{
    private const string ResourceName = "SUTWinExplorer.MediaTypes.json";
    private const string Ambiguous = "ambiguous";
    private static readonly IReadOnlyDictionary<string, string> TypesByExtension = Load();

    public static string GetMediaType(string path, bool isDirectory)
    {
        if (isDirectory)
            return "directory";

        var extension = Path.GetExtension(path);
        if (string.Equals(extension, ".lnk", StringComparison.OrdinalIgnoreCase))
            return "shell-link";

        return TypesByExtension.TryGetValue(extension, out var type) ? type : string.Empty;
    }

    private static Dictionary<string, string> Load()
    {
        using var stream = typeof(MediaTypeMap).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException($"Embedded media type mapping '{ResourceName}' is missing.");
        using var document = JsonDocument.Parse(stream);
        var types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in document.RootElement.GetProperty("types").EnumerateArray())
        {
            var type = entry.GetProperty("type").GetString();
            if (string.IsNullOrWhiteSpace(type))
                throw new InvalidDataException("A media type name is missing or empty.");

            foreach (var extensionElement in entry.GetProperty("extensions").EnumerateArray())
            {
                var extension = extensionElement.GetString();
                if (string.IsNullOrWhiteSpace(extension) || extension[0] != '.' || extension.Length == 1)
                    throw new InvalidDataException($"Invalid extension in media type '{type}'.");

                if (types.TryGetValue(extension, out var existing))
                {
                    if (!string.Equals(existing, type, StringComparison.Ordinal))
                        types[extension] = Ambiguous;
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
