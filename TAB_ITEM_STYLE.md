# WPF Tab Item Style

## Purpose

`App.xaml` merges `Styles/TabItemStyle.xaml` into application resources. Its
implicit `TabItem` style therefore applies to the application tabs and the
Pathview's nested tabs. The style keeps WPF's `TabPanel`; it does not replace
the `TabControl` template or implement tab placement and selection in code.

## Source

The template and its state/placement triggers are based on the **Aero2.NormalColor**
`TabItem` style in Microsoft's WPF source, pinned to release tag `v10.0.0`:

- [TabItem.xaml, Aero2.NormalColor](https://github.com/dotnet/wpf/blob/v10.0.0/src/Microsoft.DotNet.Wpf/src/Themes/XAML/TabItem.xaml)
- [TabPanel.cs](https://github.com/dotnet/wpf/blob/v10.0.0/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/TabPanel.cs)

The Aero2 `TabItem` style was copied because `CornerRadius` belongs to the
template's `Border` elements; `TabItem` has no built-in corner-radius property
that can be set while retaining the stock template. The `TabPanel` source was
also checked: it measures and arranges tabs using their margins, but does not
overlap neighboring tabs to merge their borders.

## Intentional Adaptations

This is an app-level copy, not a live reference to the operating-system theme.
The following changes are deliberate:

- The original Aero2 brush resources used by the copied template are declared
  in `TabItemStyle.xaml` with their source values. A `StaticResource` lookup
  from the application dictionary could not resolve the theme-scoped
  `TabItem.Static.Border` at runtime; WPF received `UnsetValue` for
  `BorderBrush` and threw a `XamlParseException` during layout. Keeping these
  brushes beside the style makes those lookups deterministic. The copied brush
  values do not automatically follow a future theme change.
- Both template borders bind to `TabItemChrome.CornerRadius`. Its default is
  `5,5,0,0`, so existing tabs keep their current appearance. The same value is
  used for the outer and selected-state border to prevent mismatched corners.
- Aero2 draws a one-DIP border on both sides of each unselected top/bottom tab.
  Since `TabPanel` does not overlap the adjacent tabs, that produces a
  two-stroke separator. The adapted top/bottom triggers set the right margin to
  `-1` DIP, overlapping that shared edge by one DIP.
- Aero2's selected top/bottom margins expand the tab horizontally. The adapted
  margins preserve the original two-DIP vertical selected overlap and z-order,
  but use the same horizontal margins as unselected tabs so selecting a tab
  does not widen it.

The remaining Aero2 state behavior, including hover/disabled resources,
placement-specific border thickness, selected content layering, and
`Panel.ZIndex`, remains in the template. The side-placement trigger values are
retained, but the app's tab strips currently use the default top placement.

## Customization

Set a radius per tab in XAML:

```xaml
xmlns:chrome="clr-namespace:SUTWinExplorer"

<TabItem Header="BROWSE"
         chrome:TabItemChrome.CornerRadius="8,8,0,0" />
```

The `CornerRadius` values are ordered top-left, top-right, bottom-right,
bottom-left. In code, use `TabItemChrome.SetCornerRadius(tabItem, radius)`.
Height and padding remain ordinary `TabItem` properties and can be set per item
or in a more specific style. Avoid overriding the horizontal selected margins
unless a different separator or selected-width behavior is intended.