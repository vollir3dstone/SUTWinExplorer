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
    public string? TabColor { get; set; }
    public required string Path { get; set; }
    public required string ActionOnProfileActivation { get; set; }
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalProperties { get; set; }
}

internal sealed class ProfileStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _filePath;
    private readonly string _directory;
    private readonly string _profileName;

    public ProfileStore(string directory, string profileName)
    {
        if (string.IsNullOrWhiteSpace(profileName) || profileName.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0)
            throw new ArgumentException("The profile name cannot be used in a filename.", nameof(profileName));
        _directory = directory;
        _profileName = profileName;
        _filePath = System.IO.Path.Combine(directory, $"Profile \u201e{profileName}\u201c.kisexplorer.json");
    }

    public ProfileConfiguration LoadOrCreate()
    {
        try
        {
            return Load();
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
    }

    public ProfileConfiguration Load()
    {
        ProfileConfiguration loaded;
        using (var stream = File.OpenRead(_filePath))
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
                (view.TabColor is not null &&
                 (view.TabColor.Length != 9 || view.TabColor[0] != '#' || !view.TabColor[1..].All(Uri.IsHexDigit))) ||
                !paths.Add(System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(view.Path))))
                throw new InvalidDataException("The profile contains an invalid or duplicate Pathview.");
        }
        return loaded;
    }

    public IReadOnlyList<string> GetProfileNames()
    {
        const string prefix = "Profile \u201e";
        const string suffix = "\u201c.kisexplorer.json";
        return Directory.EnumerateFiles(_directory, "*.kisexplorer.json")
            .Select(System.IO.Path.GetFileName)
            .Where(name => name is not null && name.StartsWith(prefix, StringComparison.Ordinal) &&
                           name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) && name.Length > prefix.Length + suffix.Length)
            .Select(name => name![prefix.Length..^suffix.Length])
            .OrderBy(name => name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    public ProfileStore ForProfile(string profileName) => new(_directory, profileName);

    public void Save(ProfileConfiguration profile) => Write(profile, overwrite: true);

    public void Create(ProfileConfiguration profile)
    {
        if (string.Equals(_profileName, "new", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The name 'new' is reserved.");
        Write(profile, overwrite: false);
    }

    public ProfileStore Rename(ProfileConfiguration profile, string newName)
    {
        if (string.Equals(_profileName, "default", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The default profile cannot be renamed.");
        if (string.Equals(newName, "new", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("The name 'new' is reserved.", nameof(newName));
        if (profile.ProfileName != _profileName)
            throw new InvalidDataException("The profile name does not match its filename.");

        var target = ForProfile(newName);
        if (string.Equals(_profileName, newName, StringComparison.Ordinal))
            return target;

        var renamed = new ProfileConfiguration
        {
            Type = profile.Type,
            ProfileName = newName,
            Pathviews = profile.Pathviews,
            AdditionalProperties = profile.AdditionalProperties
        };
        using (File.OpenRead(_filePath)) { }

        if (string.Equals(_profileName, newName, StringComparison.OrdinalIgnoreCase))
        {
            var backupPath = System.IO.Path.Combine(_directory, $".{Guid.NewGuid():N}.tmp");
            File.Move(_filePath, backupPath);
            try
            {
                target.Create(renamed);
            }
            catch
            {
                File.Move(backupPath, _filePath);
                throw;
            }
            try
            {
                File.Delete(backupPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                System.Diagnostics.Debug.WriteLine($"Cannot remove profile rename backup: {exception}");
            }
        }
        else
        {
            target.Create(renamed);
            try
            {
                File.Delete(_filePath);
            }
            catch
            {
                File.Delete(target._filePath);
                throw;
            }
        }

        profile.ProfileName = newName;
        return target;
    }

    public void Delete()
    {
        if (string.Equals(_profileName, "default", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The default profile cannot be deleted.");
        using (File.OpenRead(_filePath)) { }
        File.Delete(_filePath);
    }

    private void Write(ProfileConfiguration profile, bool overwrite)
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
            File.Move(temporaryPath, _filePath, overwrite);
        }
        finally
        {
            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);
        }
    }
}