using System.IO;

namespace SUTWinExplorer;

internal static class ShellLocations
{
    internal const string TopPath = "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}";

    internal static bool IsTopPath(string? path) =>
        string.Equals(path, TopPath, StringComparison.OrdinalIgnoreCase);

    internal static string RemapPath(string path, string oldPath, string newPath)
    {
        if (string.IsNullOrEmpty(path) || IsTopPath(path))
            return path;

        var relative = Path.GetRelativePath(oldPath, path);
        if (relative == ".")
            return newPath;
        if (Path.IsPathRooted(relative) || relative == ".." ||
            relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            return path;
        return Path.Combine(newPath, relative);
    }
}
