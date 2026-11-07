using System.Resources;
using System.Windows.Markup;

namespace SUTWinExplorer;

internal static class LocalizedText
{
    private static readonly ResourceManager Resources = new("SUTWinExplorer.Strings", typeof(LocalizedText).Assembly);

    internal static string Get(string id) => Resources.GetString(id) ??
        throw new InvalidOperationException($"Missing string resource: {id}");
}

[MarkupExtensionReturnType(typeof(string))]
public sealed class LocalizedExtension(string id) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => LocalizedText.Get(id);
}