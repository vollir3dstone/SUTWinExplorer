using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace SUTWinExplorer;

internal sealed record NewItemType(string Name, string Extension, NewItemKind Kind, byte[]? Data = null, string? Template = null)
{
    public override string ToString() => Name;
}

internal enum NewItemKind { Directory, EmptyFile, Data, Template }

internal static class NewItemOperations
{
    internal static IReadOnlyList<NewItemType> GetTypes()
    {
        var types = new List<NewItemType> { new("Directory", "", NewItemKind.Directory) };
        foreach (var extension in Registry.ClassesRoot.GetSubKeyNames().Where(name => name.StartsWith('.') && name.Length > 1))
        {
            try
            {
                using var extensionKey = Registry.ClassesRoot.OpenSubKey(extension);
                if (extensionKey is null) continue;
                var programId = extensionKey.GetValue(null) as string;
                using var newKey = (!string.IsNullOrEmpty(programId) ? extensionKey.OpenSubKey(programId + "\\ShellNew") : null)
                    ?? extensionKey.OpenSubKey("ShellNew")
                    ?? (!string.IsNullOrEmpty(programId) ? Registry.ClassesRoot.OpenSubKey(programId + "\\ShellNew") : null);
                if (newKey is null) continue;
                var valueNames = newKey.GetValueNames();
                if (valueNames.Contains("Command", StringComparer.OrdinalIgnoreCase)) continue;
                NewItemKind kind;
                byte[]? data = null;
                string? template = null;
                if (valueNames.Contains("NullFile", StringComparer.OrdinalIgnoreCase))
                    kind = NewItemKind.EmptyFile;
                else if (newKey.GetValue("FileName") is string fileName && !string.IsNullOrWhiteSpace(fileName))
                {
                    kind = NewItemKind.Template;
                    template = FindTemplate(fileName);
                    if (template is null) continue;
                }
                else if (newKey.GetValue("Data") is byte[] bytes)
                {
                    kind = NewItemKind.Data;
                    data = bytes;
                }
                else continue;

                using var programKey = string.IsNullOrEmpty(programId) ? null : Registry.ClassesRoot.OpenSubKey(programId);
                var name = programKey?.GetValue(null) as string;
                if (string.IsNullOrWhiteSpace(name)) name = extension + " file";
                types.Add(new NewItemType($"{name} ({extension})", extension, kind, data, template));
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                System.Diagnostics.Trace.TraceWarning("Could not read ShellNew registration {0}: {1}", extension, exception.Message);
            }
        }
        if (!types.Any(type => type.Extension.Equals(".txt", StringComparison.OrdinalIgnoreCase)))
            types.Add(new NewItemType("Textfile", ".txt", NewItemKind.EmptyFile));
        return types.Select(type => type.Extension.Equals(".txt", StringComparison.OrdinalIgnoreCase)
                ? type with { Name = "Textfile" } : type)
            .OrderBy(type => type.Kind == NewItemKind.Directory ? 0 :
                type.Extension.Equals(".txt", StringComparison.OrdinalIgnoreCase) ? 1 : 2)
            .ThenBy(type => type.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }

    private static string? FindTemplate(string fileName)
    {
        var expanded = Environment.ExpandEnvironmentVariables(fileName);
        if (Path.IsPathFullyQualified(expanded)) return File.Exists(expanded) ? expanded : null;
        if (Path.GetFileName(expanded) != expanded) return null;
        foreach (var directory in new[] { Environment.GetFolderPath(Environment.SpecialFolder.Templates),
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "ShellNew") })
        {
            var candidate = Path.Combine(directory, expanded);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    internal static string Create(string directory, string name, NewItemType type)
    {
        if (!Directory.Exists(directory)) throw new DirectoryNotFoundException("The destination directory is unavailable.");
        if (string.IsNullOrWhiteSpace(name) || name is "." or ".." || name != name.TrimEnd(' ', '.') ||
            name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw new ArgumentException("Enter a valid file or directory name.");
        var deviceName = name.Split('.')[0];
        if (deviceName.Equals("CON", StringComparison.OrdinalIgnoreCase) || deviceName.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
            deviceName.Equals("AUX", StringComparison.OrdinalIgnoreCase) || deviceName.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
            (deviceName.Length == 4 && (deviceName.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
             deviceName.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && deviceName[3] is >= '1' and <= '9'))
            throw new ArgumentException("This name is reserved by Windows.");

        var path = Path.Combine(directory, name);
        if (type.Kind == NewItemKind.Directory)
        {
            if (!CreateDirectory(path, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return path;
        }
        using var source = type.Kind == NewItemKind.Template
            ? File.OpenRead(type.Template ?? throw new InvalidOperationException("The template is unavailable.")) : null;
        using var destination = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        try
        {
            if (source is not null) source.CopyTo(destination);
            else if (type.Kind == NewItemKind.Data) destination.Write(type.Data ?? throw new InvalidOperationException("The initial data is unavailable."));
        }
        catch
        {
            destination.Dispose();
            File.Delete(path);
            throw;
        }
        return path;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectory(string path, IntPtr securityAttributes);
}