using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;

namespace SUTWinExplorer;

internal static class ViewUtilities
{
    internal static T? FindVisualChild<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match)
                return match;

            if (FindVisualChild<T>(child) is { } descendant)
                return descendant;
        }

        return null;
    }

    internal static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
    {
        while (current is not null)
        {
            if (current is T match)
                return match;
            current = VisualTreeHelper.GetParent(current);
        }

        return null;
    }

    internal static bool IsListChrome(DependencyObject? source) =>
        FindAncestor<GridViewColumnHeader>(source) is not null || FindAncestor<ScrollBar>(source) is not null;

    internal static void ShowNativeMenu(FrameworkElement element, string path, Action? rename = null)
    {
        try
        {
            var owner = new WindowInteropHelper(Window.GetWindow(element)!).Handle;
            SutShell.ShowItemMenu([path], owner, rename);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(element), exception.Message, "Shell context menu failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    internal static void ShowNativeBackgroundMenu(FrameworkElement element, string path)
    {
        try
        {
            var owner = new WindowInteropHelper(Window.GetWindow(element)!).Handle;
            SutShell.ShowBackgroundMenu(path, owner);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(element), exception.Message, "Shell context menu failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
