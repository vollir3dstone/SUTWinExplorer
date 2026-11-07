using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SUTWinExplorer;

internal sealed class ExplorerConfiguration
{
    [JsonPropertyName("_type")]
    [JsonPropertyOrder(-2)]
    public required string Type { get; set; }
    [JsonPropertyName("_version")]
    [JsonPropertyOrder(-1)]
    public required string Version { get; set; }
    public required InterfaceConfiguration Interface { get; set; }
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalProperties { get; set; }

    public static ExplorerConfiguration CreateDefault() => new()
    {
        Type = "KIS Explorer Configuration",
        Version = "1.01",
        Interface = new InterfaceConfiguration
        {
            ShowDirectoryRowActionButtons = false,
            ShowDirectoryColumnActionButtons = false,
            ShowSelectedItemsActionButtons = false
        }
    };
}

internal sealed class InterfaceConfiguration
{
    public required bool ShowDirectoryRowActionButtons { get; set; }
    public required bool ShowDirectoryColumnActionButtons { get; set; }
    public required bool ShowSelectedItemsActionButtons { get; set; }
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalProperties { get; set; }

}

internal sealed class ExplorerConfigurationStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _filePath;

    public ExplorerConfigurationStore(string directory) =>
        _filePath = Path.Combine(directory, "KIS Explorer Configuration.kisexplorer.json");

    public ExplorerConfiguration LoadOrCreate()
    {
        try { return Load(); }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            var configuration = ExplorerConfiguration.CreateDefault();
            Write(configuration, overwrite: false);
            return configuration;
        }
    }

    public ExplorerConfiguration Load()
    {
        using var stream = File.OpenRead(_filePath);
        var configuration = JsonSerializer.Deserialize<ExplorerConfiguration>(stream, JsonOptions)
            ?? throw new InvalidDataException("The configuration is empty.");
        Validate(configuration);
        return configuration;
    }

    public void Save(ExplorerConfiguration configuration) => Write(configuration, overwrite: true);

    private static void Validate(ExplorerConfiguration configuration)
    {
        if (configuration.Type != "KIS Explorer Configuration" || configuration.Version != "1.01" || configuration.Interface is null)
            throw new InvalidDataException("The configuration has an invalid type, version, or Interface.");
    }

    private void Write(ExplorerConfiguration configuration, bool overwrite)
    {
        Validate(configuration);
        var directory = Path.GetDirectoryName(_filePath)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, configuration, JsonOptions);
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