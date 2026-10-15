using System.IO;

namespace SUTWinExplorer;

internal static class InternalItemFilter
{
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