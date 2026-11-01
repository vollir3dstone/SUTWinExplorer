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

	internal ProfileStore ProfileStore { get; private set; } = null!;
	internal ProfileConfiguration ActiveProfile { get; private set; } = null!;

	internal void SetActiveProfile(ProfileStore store, ProfileConfiguration profile)
	{
		ProfileStore = store;
		ActiveProfile = profile;
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
			ProfileStore = new ProfileStore(directory, "default");
			ActiveProfile = ProfileStore.LoadOrCreate();
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
			_instanceMutex?.ReleaseMutex();
		_instanceMutex?.Dispose();
		base.OnExit(e);
	}
}

