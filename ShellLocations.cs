namespace SUTWinExplorer;

internal static class ShellLocations
{
    internal const string TopPath = "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}";

    internal static bool IsTopPath(string? path) =>
        string.Equals(path, TopPath, StringComparison.OrdinalIgnoreCase);
}
