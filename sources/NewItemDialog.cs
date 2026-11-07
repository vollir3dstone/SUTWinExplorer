using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace SUTWinExplorer;

internal sealed class NewItemDialog : Window
{
    private readonly string _directory;
    private readonly ListBox _typePicker;
    private readonly TextBox _nameEditor;
    private string _previousExtension = "";
    private Point _windowsMenuPoint;

    private NewItemDialog(string directory)
    {
        _directory = directory;
        Title = LocalizedText.Get("NewItemDialog_Title");
        Width = 480;
        SizeToContent = SizeToContent.Height;
        MinWidth = 360;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var root = new Grid { Margin = new Thickness(16) };
        for (var index = 0; index < 5; index++) root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var typeLabel = new TextBlock { Text = LocalizedText.Get("NewItemDialog_Label_Type"), Margin = new Thickness(0, 0, 0, 4) };
        root.Children.Add(typeLabel);
        var typeRow = new FrameworkElementFactory(typeof(DockPanel));
        var icon = new FrameworkElementFactory(typeof(Image));
        icon.SetValue(FrameworkElement.WidthProperty, 16d);
        icon.SetValue(FrameworkElement.HeightProperty, 16d);
        icon.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 8, 0));
        icon.SetBinding(Image.SourceProperty, new Binding { Converter = new TypeIconConverter() });
        typeRow.AppendChild(icon);
        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        text.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        text.SetBinding(TextBlock.TextProperty, new Binding(nameof(NewItemType.Name)));
        typeRow.AppendChild(text);
        var dividerLine = new FrameworkElementFactory(typeof(Border));
        dividerLine.SetValue(FrameworkElement.HeightProperty, 1d);
        dividerLine.SetValue(FrameworkElement.MarginProperty, new Thickness(6, 0, 6, 0));
        dividerLine.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        dividerLine.SetValue(Border.BackgroundProperty, new SolidColorBrush(Color.FromRgb(190, 195, 200)));
        var types = NewItemOperations.GetTypes().Cast<object>().ToList();
        types.Insert(2, new ListBoxItem { IsEnabled = false, Focusable = false, IsHitTestVisible = false, Height = 9,
            Template = new ControlTemplate(typeof(ListBoxItem)) { VisualTree = dividerLine } });
        var itemStyle = new Style(typeof(ListBoxItem));
        itemStyle.Setters.Add(new Setter(FrameworkElement.HeightProperty, 26d));
        itemStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(6, 2, 6, 2)));
        itemStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _typePicker = new ListBox { Name = "TypePicker", ItemsSource = types, Margin = new Thickness(0, 0, 0, 12), Height = 262,
            ItemTemplate = new DataTemplate { VisualTree = typeRow }, ItemContainerStyle = itemStyle };
        ScrollViewer.SetVerticalScrollBarVisibility(_typePicker, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollBarVisibility(_typePicker, ScrollBarVisibility.Disabled);
        Grid.SetRow(_typePicker, 1);
        root.Children.Add(_typePicker);
        var nameLabel = new TextBlock { Text = LocalizedText.Get("NewItemDialog_Label_Name"), Margin = new Thickness(0, 0, 0, 4) };
        Grid.SetRow(nameLabel, 2);
        root.Children.Add(nameLabel);
        _nameEditor = new TextBox { Name = "NameEditor", MinHeight = 26, VerticalContentAlignment = VerticalAlignment.Center };
        Grid.SetRow(_nameEditor, 3);
        root.Children.Add(_nameEditor);

        var buttons = new Grid { Margin = new Thickness(0, 16, 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var windowsButton = new Button { Name = "WindowsButton", Content = LocalizedText.Get("NewItemDialog_Button_Windows"), ToolTip = LocalizedText.Get("NewItemDialog_Button_Windows_Tooltip"), HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(8, 3, 8, 3) };
        windowsButton.Click += (_, _) =>
        {
            _windowsMenuPoint = windowsButton.PointToScreen(new Point(0, windowsButton.ActualHeight));
            UseWindowsMenu = true;
            DialogResult = false;
        };
        buttons.Children.Add(windowsButton);
        var cancel = new Button { Name = "CancelButton", Content = LocalizedText.Get("Common_Button_Cancel"), MinWidth = 72, Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        Grid.SetColumn(cancel, 1);
        buttons.Children.Add(cancel);
        var create = new Button { Name = "CreateButton", Content = LocalizedText.Get("NewItemDialog_Button_Create"), MinWidth = 72, Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
        create.Click += Create_Click;
        Grid.SetColumn(create, 2);
        buttons.Children.Add(create);
        Grid.SetRow(buttons, 4);
        root.Children.Add(buttons);
        Content = root;
        _typePicker.SelectionChanged += TypePicker_SelectionChanged;
        _typePicker.AddHandler(MouseLeftButtonUpEvent, new MouseButtonEventHandler(TypePicker_MouseLeftButtonUp), true);
        _typePicker.SelectedIndex = 1;
        Loaded += (_, _) => _nameEditor.Focus();
    }

    internal bool UseWindowsMenu { get; private set; }
    internal string? CreatedPath { get; private set; }
    private bool CreatedDirectory { get; set; }

    internal static (string Path, bool IsDirectory)? ShowForDirectory(string directory, Window owner)
    {
        var dialog = new NewItemDialog(directory) { Owner = owner };
        dialog.ShowDialog();
        if (dialog.UseWindowsMenu)
            SutShell.ShowNewMenu(directory, new WindowInteropHelper(owner).Handle, (int)dialog._windowsMenuPoint.X, (int)dialog._windowsMenuPoint.Y);
        return dialog.CreatedPath is { } path ? (path, dialog.CreatedDirectory) : null;
    }

    private void TypePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_typePicker.SelectedItem is not NewItemType type) return;
        var name = _nameEditor.Text;
        var customExtension = false;
        if (_previousExtension.Length > 0 && name.EndsWith(_previousExtension, StringComparison.OrdinalIgnoreCase))
            name = name[..^_previousExtension.Length];
        else if (name.Length > 0 && Path.HasExtension(name))
            customExtension = true;
        _nameEditor.Text = customExtension ? name : name + type.Extension;
        _previousExtension = type.Extension;
        _nameEditor.CaretIndex = Math.Max(0, _nameEditor.Text.Length - (customExtension ? 0 : type.Extension.Length));
    }

    private void TypePicker_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && ItemsControl.ContainerFromElement(_typePicker, source) is ListBoxItem)
            _ = Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => { if (IsActive) _nameEditor.Focus(); }));
    }

    private void Create_Click(object sender, RoutedEventArgs e)
    {
        if (_typePicker.SelectedItem is not NewItemType type) return;
        var name = _nameEditor.Text;
        if (type.Extension.Length > 0 && !name.EndsWith(type.Extension, StringComparison.OrdinalIgnoreCase) &&
            MessageBox.Show(this, string.Format(LocalizedText.Get("NewItemDialog_ConfirmExtension"), type.Extension), LocalizedText.Get("NewItemDialog_ConfirmExtension_Title"),
                MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            return;
        try
        {
            CreatedPath = NewItemOperations.Create(_directory, name, type);
            CreatedDirectory = type.Kind == NewItemKind.Directory;
            DialogResult = true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            MessageBox.Show(this, exception.Message, LocalizedText.Get("NewItemDialog_CreateError_Title"), MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private sealed class TypeIconConverter : IValueConverter
    {
        public object? Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) =>
            value is NewItemType type ? ShellIconProvider.GetTypeIcon(type.Extension, type.Kind == NewItemKind.Directory) : null;

        public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) =>
            Binding.DoNothing;
    }
}