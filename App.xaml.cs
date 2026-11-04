using System.IO;
using System.Threading;
using System.Windows;

namespace SUTWinExplorer;

/// <summary>
/// Interaction logic for App.xaml
/// </summary>
public partial class App : Application
{
	private Mutex? _instanceMutex;
	private bool _ownsInstanceMutex;

	internal UseCaseStore UseCaseStore { get; private set; } = null!;
	internal UseCaseConfiguration ActiveUseCase { get; private set; } = null!;

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
				MessageBox.Show("KIS Explorer is already running.", "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Information);
				Shutdown();
				return;
			}

			var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "KIS Explorer");
			var cacheDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KIS Explorer");
			ShellIconProvider.InitializeCache(Path.Combine(cacheDirectory, "IconCache.json"));
			UseCaseStore = new UseCaseStore(directory, "default");
			ActiveUseCase = UseCaseStore.LoadOrCreate();
			var window = new MainWindow();
			MainWindow = window;
			window.Show();
		}
		catch (Exception exception)
		{
			MessageBox.Show($"Cannot start KIS Explorer: {exception.Message}", "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
			Shutdown(1);
		}
	}

	protected override void OnExit(ExitEventArgs e)
	{
		if (_ownsInstanceMutex)
		{
			ShellIconProvider.SaveCache();
			_instanceMutex?.ReleaseMutex();
		}
		_instanceMutex?.Dispose();
		base.OnExit(e);
	}
}

