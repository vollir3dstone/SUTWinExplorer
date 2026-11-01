using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SUTWinExplorer;

internal sealed class ProfileConfiguration
{
    [JsonPropertyName("_type")]
    public required string Type { get; set; }
    public required string ProfileName { get; set; }
    public required List<ProfilePathview> Pathviews { get; set; }
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalProperties { get; set; }
}

internal sealed class ProfilePathview
{
    [JsonPropertyName("_type")]
    public required string Type { get; set; }
    public required string? Name { get; set; }
    public required string Path { get; set; }
    public required string ActionOnProfileActivation { get; set; }
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalProperties { get; set; }
}

internal sealed class ProfileStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _filePath;
    private readonly string _profileName;

    public ProfileStore(string directory, string profileName)
    {
        if (string.IsNullOrWhiteSpace(profileName) || profileName.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0)
            throw new ArgumentException("The profile name cannot be used in a filename.", nameof(profileName));
        _profileName = profileName;
        _filePath = System.IO.Path.Combine(directory, $"Profile \u201e{profileName}\u201c.kisexplorer.json");
    }

    public ProfileConfiguration LoadOrCreate()
    {
        FileStream stream;
        try
        {
            stream = File.OpenRead(_filePath);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            var profile = new ProfileConfiguration
            {
                Type = "KIS Explorer profile",
                ProfileName = _profileName,
                Pathviews = []
            };
            Save(profile);
            return profile;
        }

        ProfileConfiguration loaded;
        using (stream)
            loaded = JsonSerializer.Deserialize<ProfileConfiguration>(stream, JsonOptions)
                ?? throw new InvalidDataException("The profile is empty.");
        if (loaded.Type != "KIS Explorer profile" || loaded.ProfileName != _profileName || loaded.Pathviews is null)
            throw new InvalidDataException("The profile has an invalid type, name, or Pathviews list.");

        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var view in loaded.Pathviews)
        {
            if (view is null || view.Type != "Pathview" || string.IsNullOrWhiteSpace(view.Path) ||
                !System.IO.Path.IsPathFullyQualified(view.Path) ||
                view.ActionOnProfileActivation != "open" ||
                !paths.Add(System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(view.Path))))
                throw new InvalidDataException("The profile contains an invalid or duplicate Pathview.");
        }
        return loaded;
    }

    public void Save(ProfileConfiguration profile)
    {
        if (profile.ProfileName != _profileName)
            throw new InvalidDataException("The profile name does not match its filename.");
        var directory = System.IO.Path.GetDirectoryName(_filePath)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = System.IO.Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, profile, JsonOptions);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, _filePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);
        }
    }
}