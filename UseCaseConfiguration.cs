using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SUTWinExplorer;

internal sealed class UseCaseConfiguration
{
    [JsonPropertyName("_type")]
    [JsonPropertyOrder(-2)]
    public required string Type { get; set; }
    [JsonPropertyOrder(-1)]
    public required string UseCaseName { get; set; }
    public required List<UseCasePathview> Pathviews { get; set; }
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalProperties { get; set; }
}

internal sealed class UseCasePathview
{
    [JsonPropertyName("_type")]
    public required string Type { get; set; }
    public required string? Name { get; set; }
    public string? TabColor { get; set; }
    public required string Path { get; set; }
    public required string ActionOnUseCaseActivation { get; set; }
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalProperties { get; set; }
}

internal sealed class UseCaseStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _filePath;
    private readonly string _directory;
    private readonly string _useCaseName;

    public UseCaseStore(string directory, string useCaseName)
    {
        if (string.IsNullOrWhiteSpace(useCaseName) || useCaseName.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0)
            throw new ArgumentException(LocalizedText.Get("UseCaseStore_Error_InvalidFilename"), nameof(useCaseName));
        _directory = directory;
        _useCaseName = useCaseName;
        _filePath = System.IO.Path.Combine(directory, $"Use case \u201e{useCaseName}\u201c.kisexplorer.json");
    }

    public UseCaseConfiguration LoadOrCreate()
    {
        try
        {
            return Load();
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            var useCase = new UseCaseConfiguration
            {
                Type = "KIS Explorer use case",
                UseCaseName = _useCaseName,
                Pathviews = []
            };
            Save(useCase);
            return useCase;
        }
    }

    public UseCaseConfiguration Load()
    {
        UseCaseConfiguration loaded;
        using (var stream = File.OpenRead(_filePath))
            loaded = JsonSerializer.Deserialize<UseCaseConfiguration>(stream, JsonOptions)
                ?? throw new InvalidDataException(LocalizedText.Get("UseCaseStore_Error_Empty"));
        Validate(loaded, _useCaseName);
        return loaded;
    }

    private static void Validate(UseCaseConfiguration loaded, string useCaseName)
    {
        if (loaded.Type != "KIS Explorer use case" || loaded.UseCaseName != useCaseName || loaded.Pathviews is null)
            throw new InvalidDataException(LocalizedText.Get("UseCaseStore_Error_Invalid"));

        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var view in loaded.Pathviews)
        {
            if (view is null || view.Type != "Pathview" || string.IsNullOrWhiteSpace(view.Path) ||
                !System.IO.Path.IsPathFullyQualified(view.Path) ||
                view.ActionOnUseCaseActivation != "open" ||
                (view.TabColor is not null &&
                 (view.TabColor.Length != 9 || view.TabColor[0] != '#' || !view.TabColor[1..].All(Uri.IsHexDigit))) ||
                !paths.Add(System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(view.Path))))
                throw new InvalidDataException(LocalizedText.Get("UseCaseStore_Error_InvalidPathview"));
        }
    }

    public IReadOnlyList<string> GetUseCaseNames()
    {
        const string prefix = "Use case \u201e";
        const string suffix = "\u201c.kisexplorer.json";
        return Directory.EnumerateFiles(_directory, "*.kisexplorer.json")
            .Select(System.IO.Path.GetFileName)
            .Where(name => name is not null && name.StartsWith(prefix, StringComparison.Ordinal) &&
                           name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) && name.Length > prefix.Length + suffix.Length)
            .Select(name => name![prefix.Length..^suffix.Length])
            .OrderBy(name => name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    public UseCaseStore ForUseCase(string useCaseName) => new(_directory, useCaseName);

    public void Save(UseCaseConfiguration useCase) => Write(useCase, overwrite: true);

    public void Create(UseCaseConfiguration useCase)
    {
        if (string.Equals(_useCaseName, "new", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(LocalizedText.Get("UseCaseStore_Error_ReservedName"));
        Write(useCase, overwrite: false);
    }

    public UseCaseStore Rename(UseCaseConfiguration useCase, string newName)
    {
        if (string.Equals(_useCaseName, "default", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(LocalizedText.Get("UseCaseStore_Error_RenameDefault"));
        if (string.Equals(newName, "new", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException(LocalizedText.Get("UseCaseStore_Error_ReservedName"), nameof(newName));
        if (useCase.UseCaseName != _useCaseName)
            throw new InvalidDataException(LocalizedText.Get("UseCaseStore_Error_NameMismatch"));

        var target = ForUseCase(newName);
        if (string.Equals(_useCaseName, newName, StringComparison.Ordinal))
            return target;

        var renamed = new UseCaseConfiguration
        {
            Type = useCase.Type,
            UseCaseName = newName,
            Pathviews = useCase.Pathviews,
            AdditionalProperties = useCase.AdditionalProperties
        };
        using (File.OpenRead(_filePath)) { }

        if (string.Equals(_useCaseName, newName, StringComparison.OrdinalIgnoreCase))
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
                System.Diagnostics.Debug.WriteLine($"Cannot remove use case rename backup: {exception}");
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

        useCase.UseCaseName = newName;
        return target;
    }

    public void Delete()
    {
        if (string.Equals(_useCaseName, "default", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(LocalizedText.Get("UseCaseStore_Error_DeleteDefault"));
        using (File.OpenRead(_filePath)) { }
        File.Delete(_filePath);
    }

    private void Write(UseCaseConfiguration useCase, bool overwrite)
    {
        if (useCase.UseCaseName != _useCaseName)
            throw new InvalidDataException(LocalizedText.Get("UseCaseStore_Error_NameMismatch"));
        var directory = System.IO.Path.GetDirectoryName(_filePath)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = System.IO.Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, useCase, JsonOptions);
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