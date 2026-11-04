namespace SUTWinExplorer;

internal sealed class MoveWorkflowState
{
    private string[]? _preparedPaths;

    public static MoveWorkflowState Shared { get; } = new();

    public event EventHandler? Changed;

    public bool IsPrepared => _preparedPaths is not null;

    public IReadOnlyList<string> PreparedPaths => _preparedPaths ??
        throw new InvalidOperationException("There is no prepared move to execute.");

    public void Prepare(IEnumerable<string> paths)
    {
        if (IsPrepared)
            throw new InvalidOperationException("A move is already prepared.");

        var selectedPaths = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (selectedPaths.Length == 0)
            throw new InvalidOperationException("Select one or more items before using Move mark item.");

        _preparedPaths = selectedPaths;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void CompleteExecute() => ClearPreparedPaths();

    public void Abort() => ClearPreparedPaths();

    private void ClearPreparedPaths()
    {
        if (_preparedPaths is null)
            return;

        _preparedPaths = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}