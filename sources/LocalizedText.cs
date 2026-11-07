using System.Globalization;
using System.ComponentModel;
using System.Resources;
using System.Runtime.InteropServices;
using System.Windows.Markup;

namespace SUTWinExplorer;

internal static class LocalizedText
{
    private static readonly ResourceManager Resources = new("SUTWinExplorer.Assets.Strings.Strings", typeof(LocalizedText).Assembly);
    internal static bool PreferEnglishShellMenus { get; private set; }

    internal static string Get(string id) => Resources.GetString(id) ??
        throw new InvalidOperationException($"Missing string resource: {id}");

    internal static void ApplyProcessLanguageSelection(LanguageSelection selection)
    {
        var languages = selection switch
        {
            LanguageSelection.English => "en-US\0\0",
            LanguageSelection.SystemDefault => null,
            _ => throw new ArgumentOutOfRangeException(nameof(selection))
        };
        if (!SetProcessPreferredUILanguages(0x8, languages, out var count))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (selection == LanguageSelection.English && count == 0)
            throw new InvalidOperationException("Could not set the process UI language to English.");
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessPreferredUILanguages(uint flags, string? languages, out uint count);

    internal static void ApplyLanguageSelection(LanguageSelection selection, CultureInfo systemCulture)
    {
        var culture = selection switch
        {
            LanguageSelection.English => CultureInfo.GetCultureInfo("en"),
            LanguageSelection.SystemDefault => systemCulture,
            _ => throw new ArgumentOutOfRangeException(nameof(selection))
        };
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.CurrentUICulture = culture;
        PreferEnglishShellMenus = selection == LanguageSelection.English;
    }
}

internal sealed class ShellMenuLanguage : IDisposable
{
    private const uint LanguageName = 0x8;
    private const uint ThreadLanguages = 0x40;
    private readonly string _previousLanguages;

    private ShellMenuLanguage(string previousLanguages) => _previousLanguages = previousLanguages;

    internal static ShellMenuLanguage? Enter()
    {
        if (!LocalizedText.PreferEnglishShellMenus)
            return null;

        uint count = 0;
        uint size = 0;
        if (!GetThreadPreferredUILanguages(LanguageName | ThreadLanguages, out count, null, ref size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        var buffer = new char[size];
        if (!GetThreadPreferredUILanguages(LanguageName | ThreadLanguages, out count, buffer, ref size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!SetThreadPreferredUILanguages(LanguageName, "en-US\0\0", out count))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return new ShellMenuLanguage(new string(buffer));
    }

    public void Dispose()
    {
        if (!SetThreadPreferredUILanguages(LanguageName, _previousLanguages, out _))
            System.Diagnostics.Trace.TraceError("Could not restore thread UI languages: {0}", Marshal.GetLastWin32Error());
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetThreadPreferredUILanguages(uint flags, out uint count, [Out] char[]? languages, ref uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetThreadPreferredUILanguages(uint flags, string languages, out uint count);
}

[MarkupExtensionReturnType(typeof(string))]
public sealed class LocalizedExtension(string id) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => LocalizedText.Get(id);
}