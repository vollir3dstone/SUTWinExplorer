namespace SUTWinExplorer;

internal sealed class CopyWorkflowState
{
    private string[]? _preparedPaths;

    public static CopyWorkflowState Shared { get; } = new();

    public event EventHandler? Changed;

    public bool IsPrepared => _preparedPaths is not null;

    public IReadOnlyList<string> PreparedPaths => _preparedPaths ??
        throw new InvalidOperationException("There is no prepared copy to paste.");

    public void Prepare(IEnumerable<string> paths)
    {
        if (IsPrepared)
            throw new InvalidOperationException("A copy is already prepared.");

        var selectedPaths = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (selectedPaths.Length == 0)
            throw new InvalidOperationException("Select one or more items before using Copy get.");

        _preparedPaths = selectedPaths;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public bool TryPrepareFromShell(IEnumerable<string> paths)
    {
        if (IsPrepared)
            return false;

        var selectedPaths = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (selectedPaths.Length == 0)
            return false;

        _preparedPaths = selectedPaths;
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public void CompletePaste() => ClearPreparedPaths();

    public void Abort() => ClearPreparedPaths();

    private void ClearPreparedPaths()
    {
        if (_preparedPaths is null)
            return;

        _preparedPaths = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}