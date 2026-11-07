using System.IO;
using System.Threading;
using System.Windows;

namespace SUTWinExplorer;

/// <summary>
/// Interaction logic for App.xaml
/// </summary>
public partial class App : Application
{
	static App() => LocalizedText.ApplyProcessLanguageSelection(LanguageSelection.English);

	private Mutex? _instanceMutex;
	private bool _ownsInstanceMutex;
	private IconChangeObserver? _iconChangeObserver;

	internal UseCaseStore UseCaseStore { get; private set; } = null!;
	internal UseCaseConfiguration ActiveUseCase { get; private set; } = null!;
	internal ExplorerConfigurationStore ConfigurationStore { get; private set; } = null!;
	internal ExplorerConfiguration Configuration { get; set; } = ExplorerConfiguration.CreateDefault();

	internal void SetActiveUseCase(UseCaseStore store, UseCaseConfiguration useCase)
	{
		UseCaseStore = store;
		ActiveUseCase = useCase;
	}

	protected override void OnStartup(StartupEventArgs e)
	{
		base.OnStartup(e);
		try
		{
			_instanceMutex = new Mutex(true, @"Global\KIS Explorer", out _ownsInstanceMutex);
			if (!_ownsInstanceMutex)
			{
				MessageBox.Show(LocalizedText.Get("App_Error_AlreadyRunning"), LocalizedText.Get("MainWindow_Title"), MessageBoxButton.OK, MessageBoxImage.Information);
				Shutdown();
				return;
			}

			var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "KIS Explorer");
			ConfigurationStore = new ExplorerConfigurationStore(directory);
			Configuration = ConfigurationStore.LoadOrCreate();
			LocalizedText.ApplyProcessLanguageSelection(Configuration.Interface.LanguageSelection);
			LocalizedText.ApplyLanguageSelection(Configuration.Interface.LanguageSelection, System.Globalization.CultureInfo.CurrentUICulture);
			var cacheDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KIS Explorer");
			ShellIconProvider.InitializeCache(Path.Combine(cacheDirectory, "IconCache.json"));
			_iconChangeObserver = new IconChangeObserver(ShellIconProvider.Cache!, Dispatcher);
			UseCaseStore = new UseCaseStore(directory, "default");
			ActiveUseCase = UseCaseStore.LoadOrCreate();
			var window = new MainWindow();
			MainWindow = window;
			window.Show();
		}
		catch (Exception exception)
		{
			MessageBox.Show(string.Format(LocalizedText.Get("App_Error_CannotStart"), exception.Message), LocalizedText.Get("MainWindow_Title"), MessageBoxButton.OK, MessageBoxImage.Error);
			Shutdown(1);
		}
	}

	protected override void OnExit(ExitEventArgs e)
	{
		if (_ownsInstanceMutex)
		{
			_iconChangeObserver?.Dispose();
			ShellIconProvider.SaveCache();
			_instanceMutex?.ReleaseMutex();
		}
		_instanceMutex?.Dispose();
		base.OnExit(e);
	}
}

