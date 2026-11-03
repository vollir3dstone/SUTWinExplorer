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
    private readonly Func<string> _backgroundPath;
    private readonly Func<IReadOnlyList<ShellMenuAction>> _backgroundActions;
    private readonly Action<string> _showNew;
    private readonly Func<IReadOnlyList<string>, ShellMenuAction?>? _openLocation;
    private IReadOnlyDictionary<string, int>? _baseCommands;
    private string? _basePath;
    private bool _baseIsBackground;
    private bool _skipNextMenu;
    private int _selectionVersion;

    internal SutContextMenuController(Func<T, string> path, Func<IReadOnlyList<string>> selection,
        Func<int, int, (T? Target, bool Background)> hitTest, Action<T?> select,
        Func<T, IReadOnlyList<ShellMenuAction>> actions, Action<T, IReadOnlyList<string>> showNative,
        Action showBackground, Func<string> backgroundPath, Func<IReadOnlyList<ShellMenuAction>> backgroundActions, Action<string> showNew,
        Func<IReadOnlyList<string>, ShellMenuAction?>? openLocation = null)
    {
        _path = path;
        _selection = selection;
        _hitTest = hitTest;
        _select = select;
        _actions = actions;
        _showNative = showNative;
        _showBackground = showBackground;
        _backgroundPath = backgroundPath;
        _backgroundActions = backgroundActions;
        _showNew = showNew;
        _openLocation = openLocation;
    }

    internal bool IsDifferentTarget(T target) => _basePath is not null &&
        (_baseIsBackground || !string.Equals(_basePath, _path(target), StringComparison.OrdinalIgnoreCase));

    internal void Reset()
    {
        ClearSequence();
        _selectionVersion++;
    }

    private void ClearSequence()
    {
        _baseCommands = null;
        _basePath = null;
        _baseIsBackground = false;
        _skipNextMenu = false;
    }

    internal void Show(T? target, IntPtr owner, bool alternate)
    {
        var forceNative = false;
        while (true)
        {
            var background = target is null;
            IReadOnlyList<string> selectedPaths = background ? [_backgroundPath()] : _selection();
            if (forceNative || selectedPaths.Count == 0 ||
                !selectedPaths.All(path => File.Exists(path) || Directory.Exists(path)) ||
                (Keyboard.Modifiers & ModifierKeys.Shift) != 0)
            {
                ClearSequence();
                if (background) _showBackground();
                else _showNative(target!, selectedPaths);
                return;
            }

            var targetPath = background ? selectedPaths[0] : _path(target!);
            if (alternate && _skipNextMenu && _baseIsBackground == background &&
                string.Equals(_basePath, targetPath, StringComparison.OrdinalIgnoreCase))
            {
                ClearSequence();
                return;
            }
            if (alternate && _baseCommands is { } baseCommands && _baseIsBackground == background &&
                string.Equals(_basePath, targetPath, StringComparison.OrdinalIgnoreCase))
            {
                ClearSequence();
                var selectionVersion = _selectionVersion;
                var repeat = false;
                var shift = false;
                var newAction = background ? new ShellMenuAction("New", "New…", true, () => _showNew(targetPath)) : null;
                using var contentMenu = SutContextMenuFactory.GetContentMenuForContext(selectedPaths, owner, baseCommands, background, newAction,
                    background ? null : _openLocation?.Invoke(selectedPaths));
                contentMenu.Show((screenX, screenY, overOwner, shiftPressed) =>
                {
                    if (!overOwner)
                        return false;
                    var hit = _hitTest(screenX, screenY);
                    if (background ? hit.Target is not null || !hit.Background : hit.Target is not { } clicked ||
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
                IReadOnlyList<string> selectionAfterContent = background ? [_backgroundPath()] : _selection();
                if (selectionVersion == _selectionVersion && selectedPaths.Count == selectionAfterContent.Count &&
                    selectedPaths.All(path => selectionAfterContent.Contains(path, StringComparer.OrdinalIgnoreCase)))
                {
                    _basePath = targetPath;
                    _baseIsBackground = background;
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
            using var baseMenu = SutContextMenuFactory.GetBaseMenuForContext(selectedPaths, owner,
                background ? _backgroundActions() : _actions(target!), background);
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
                            clickedWithShift = shiftPressed;
                            return true;
                        }
                    }
                    clickedElsewhere = true;
                    return false;
                } : null)!;
            IReadOnlyList<string> currentSelection = background ? [_backgroundPath()] : _selection();
            if (!alternate || clickedElsewhere || version != _selectionVersion ||
                selectedPaths.Count != currentSelection.Count ||
                !selectedPaths.All(path => currentSelection.Contains(path, StringComparer.OrdinalIgnoreCase)))
                return;

            _baseCommands = shownCommands;
            _basePath = targetPath;
            _baseIsBackground = background;
            if (clickedTarget is not null && clickedWithShift)
            {
                if (background || !string.Equals(_path(clickedTarget), targetPath, StringComparison.OrdinalIgnoreCase))
                    _select(clickedTarget);
                target = clickedTarget;
                forceNative = true;
                continue;
            }
            if (clickedTarget is not null && string.Equals(_path(clickedTarget), targetPath, StringComparison.OrdinalIgnoreCase))
            {
                if (!background) continue;
            }
            if (clickedBackground && clickedWithShift)
            {
                if (!background) _select(null);
                target = null;
                forceNative = true;
                continue;
            }
            if (clickedBackground && background)
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