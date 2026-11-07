using System.Globalization;
using System.Resources;
using System.Windows.Markup;

namespace SUTWinExplorer;

internal static class LocalizedText
{
    private static readonly ResourceManager Resources = new("SUTWinExplorer.Assets.Strings.Strings", typeof(LocalizedText).Assembly);

    internal static string Get(string id) => Resources.GetString(id) ??
        throw new InvalidOperationException($"Missing string resource: {id}");

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
    }
}

[MarkupExtensionReturnType(typeof(string))]
public sealed class LocalizedExtension(string id) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => LocalizedText.Get(id);
}