using System.IO;
using System.Windows.Input;

namespace SUTWinExplorer;

internal sealed class SutContextMenuController<T> where T : class
{
    private readonly Func<T, string> _path;
    private readonly Func<IReadOnlyList<string>> _selection;
    private readonly Func<int, int, (T? Target, bool Background)> _hitTest;
    private readonly Action<T?> _select;
    private readonly Func<T, IReadOnlyList<ShellMenuAction>> _actions;
    private readonly Action<T, IReadOnlyList<string>> _showNative;
    private readonly Action _showBackground;
    private IReadOnlyDictionary<string, int>? _baseCommands;
    private string? _basePath;
    private bool _skipNextMenu;
    private int _selectionVersion;

    internal SutContextMenuController(Func<T, string> path, Func<IReadOnlyList<string>> selection,
        Func<int, int, (T? Target, bool Background)> hitTest, Action<T?> select,
        Func<T, IReadOnlyList<ShellMenuAction>> actions, Action<T, IReadOnlyList<string>> showNative,
        Action showBackground)
    {
        _path = path;
        _selection = selection;
        _hitTest = hitTest;
        _select = select;
        _actions = actions;
        _showNative = showNative;
        _showBackground = showBackground;
    }

    internal bool IsDifferentTarget(T target) => _basePath is not null &&
        !string.Equals(_basePath, _path(target), StringComparison.OrdinalIgnoreCase);

    internal void Reset()
    {
        ClearSequence();
        _selectionVersion++;
    }

    private void ClearSequence()
    {
        _baseCommands = null;
        _basePath = null;
        _skipNextMenu = false;
    }

    internal void Show(T? target, IntPtr owner, bool alternate)
    {
        var forceNative = false;
        while (true)
        {
            if (target is null)
            {
                ClearSequence();
                _showBackground();
                return;
            }
            var selectedPaths = _selection();
            if (forceNative || selectedPaths.Count == 0 ||
                !selectedPaths.All(path => File.Exists(path) || Directory.Exists(path)) ||
                (Keyboard.Modifiers & ModifierKeys.Shift) != 0)
            {
                ClearSequence();
                _showNative(target, selectedPaths);
                return;
            }

            var targetPath = _path(target);
            if (alternate && _skipNextMenu &&
                string.Equals(_basePath, targetPath, StringComparison.OrdinalIgnoreCase))
            {
                ClearSequence();
                return;
            }
            if (alternate && _baseCommands is { } baseCommands &&
                string.Equals(_basePath, targetPath, StringComparison.OrdinalIgnoreCase))
            {
                ClearSequence();
                var selectionVersion = _selectionVersion;
                var repeat = false;
                var shift = false;
                using var contentMenu = SutContextMenuFactory.GetContentMenu(selectedPaths, owner, baseCommands);
                contentMenu.Show((screenX, screenY, overOwner, shiftPressed) =>
                {
                    if (!overOwner || _hitTest(screenX, screenY).Target is not { } clicked ||
                        !string.Equals(_path(clicked), targetPath, StringComparison.OrdinalIgnoreCase))
                        return false;
                    repeat = true;
                    shift = shiftPressed;
                    return true;
                });
                if (repeat && selectionVersion == _selectionVersion)
                {
                    if (shift)
                    {
                        forceNative = true;
                        continue;
                    }
                    return;
                }
                var selectionAfterContent = _selection();
                if (selectionVersion == _selectionVersion && selectedPaths.Count == selectionAfterContent.Count &&
                    selectedPaths.All(path => selectionAfterContent.Contains(path, StringComparer.OrdinalIgnoreCase)))
                {
                    _basePath = targetPath;
                    _skipNextMenu = true;
                }
                return;
            }

            ClearSequence();
            var version = _selectionVersion;
            T? clickedTarget = null;
            var clickedBackground = false;
            var clickedElsewhere = false;
            var clickedWithShift = false;
            using var baseMenu = SutContextMenuFactory.GetBaseMenu(selectedPaths, owner, _actions(target));
            var shownCommands = baseMenu.Show(
                alternate ? (screenX, screenY, overOwner, shiftPressed) =>
                {
                    if (overOwner)
                    {
                        var hit = _hitTest(screenX, screenY);
                        if (hit.Target is not null)
                        {
                            clickedTarget = hit.Target;
                            clickedWithShift = shiftPressed;
                            return true;
                        }
                        if (hit.Background)
                        {
                            clickedBackground = true;
                            return true;
                        }
                    }
                    clickedElsewhere = true;
                    return false;
                } : null)!;
            var currentSelection = _selection();
            if (!alternate || clickedElsewhere || version != _selectionVersion ||
                selectedPaths.Count != currentSelection.Count ||
                !selectedPaths.All(path => currentSelection.Contains(path, StringComparer.OrdinalIgnoreCase)))
                return;

            _baseCommands = shownCommands;
            _basePath = targetPath;
            if (clickedTarget is not null && clickedWithShift)
            {
                if (!string.Equals(_path(clickedTarget), targetPath, StringComparison.OrdinalIgnoreCase))
                    _select(clickedTarget);
                target = clickedTarget;
                forceNative = true;
                continue;
            }
            if (clickedTarget is not null && string.Equals(_path(clickedTarget), targetPath, StringComparison.OrdinalIgnoreCase))
                continue;
            if (clickedTarget is not null || clickedBackground)
            {
                _select(clickedTarget);
                target = clickedTarget;
                continue;
            }
            return;
        }
    }
}