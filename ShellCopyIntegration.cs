using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace SUTWinExplorer;

internal sealed class ShellCopyIntegration : IDisposable
{
    private const int WmClipboardUpdate = 0x031D;
    private const uint DropEffectCopy = 1;
    private const string PreferredDropEffectFormat = "Preferred DropEffect";
    private readonly HwndSource _source;
    private readonly Action<IReadOnlyList<string>> _shellCopyReceived;
    private readonly bool _listenerRegistered;

    public ShellCopyIntegration(IntPtr windowHandle, Action<IReadOnlyList<string>> shellCopyReceived)
    {
        _source = HwndSource.FromHwnd(windowHandle) ??
            throw new InvalidOperationException("The main window source is unavailable.");
        _shellCopyReceived = shellCopyReceived;
        _source.AddHook(WindowProc);
        _listenerRegistered = AddClipboardFormatListener(windowHandle);
    }

    public void InvokeToolbarCopy(Action? invokeShellCopy)
    {
        try
        {
            invokeShellCopy?.Invoke();
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"Optional Shell Copy integration failed: {exception}");
        }
    }

    public void Dispose()
    {
        _source.RemoveHook(WindowProc);
        if (_listenerRegistered)
            _ = RemoveClipboardFormatListener(_source.Handle);
    }

    private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmClipboardUpdate)
            _ = _source.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(HandleClipboardUpdate));

        return IntPtr.Zero;
    }

    private void HandleClipboardUpdate()
    {
        try
        {
            var clipboardData = Clipboard.GetDataObject();
            if (clipboardData is null ||
                !clipboardData.GetDataPresent(DataFormats.FileDrop, false) ||
                !IsCopyOperation(clipboardData) ||
                clipboardData.GetData(DataFormats.FileDrop, false) is not string[] paths ||
                paths.Length == 0)
                return;

            _shellCopyReceived(paths);
        }
        catch (ExternalException)
        {
        }
        catch (InvalidOperationException)
        {
        }
    }

    private static bool IsCopyOperation(IDataObject clipboardData)
    {
        if (!clipboardData.GetDataPresent(PreferredDropEffectFormat, false))
            return false;

        return clipboardData.GetData(PreferredDropEffectFormat, false) switch
        {
            MemoryStream stream when stream.Length >= sizeof(uint) =>
                BitConverter.ToUInt32(stream.ToArray(), 0) == DropEffectCopy,
            byte[] bytes when bytes.Length >= sizeof(uint) =>
                BitConverter.ToUInt32(bytes, 0) == DropEffectCopy,
            uint effect => effect == DropEffectCopy,
            int effect => effect == DropEffectCopy,
            _ => false
        };
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
}