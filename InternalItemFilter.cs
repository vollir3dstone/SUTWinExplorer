using System.IO;
using System.IO.Enumeration;

namespace SUTWinExplorer;

internal static class InternalItemFilter
{
    public static bool MatchesNamePattern(string itemPath, string pattern)
    {
        if (string.IsNullOrEmpty(pattern))
            return true;

        var itemName = ShellDisplayNameProvider.GetDisplayName(itemPath);
        if (string.IsNullOrEmpty(itemName))
            itemName = Path.GetFileName(Path.TrimEndingDirectorySeparator(itemPath));

        return MatchesName(itemName, pattern);
    }

    public static bool MatchesName(string itemName, string pattern) =>
        string.IsNullOrEmpty(pattern) || FileSystemName.MatchesSimpleExpression(pattern, itemName, ignoreCase: true);

    public static bool ShouldHide(string itemPath, bool isDirectory)
    {
        var itemName = Path.GetFileName(Path.TrimEndingDirectorySeparator(itemPath));
        if (itemName.StartsWith(".", StringComparison.Ordinal) ||
            itemName.StartsWith("$", StringComparison.Ordinal))
            return true;

        FileAttributes attributes;
        try
        {
            attributes = File.GetAttributes(itemPath);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }

        if ((attributes & FileAttributes.System) == 0)
            return false;

        try
        {
            if (isDirectory)
            {
                using var entries = Directory.EnumerateFileSystemEntries(itemPath).GetEnumerator();
                _ = entries.MoveNext();
            }
            else
            {
                using var handle = File.OpenHandle(
                    itemPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
            }

            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return true;
        }
        catch (IOException exception) when ((exception.HResult & 0xFFFF) == 5)
        {
            return true;
        }
    }
}