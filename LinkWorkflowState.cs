namespace SUTWinExplorer;

internal sealed class LinkWorkflowState
{
    private string[]? _preparedPaths;

    public static LinkWorkflowState Shared { get; } = new();

    public event EventHandler? Changed;

    public bool IsPrepared => _preparedPaths is not null;

    public IReadOnlyList<string> PreparedPaths => _preparedPaths ??
        throw new InvalidOperationException("There is no prepared link to paste.");

    public void Prepare(IEnumerable<string> paths)
    {
        if (IsPrepared)
            throw new InvalidOperationException("A link is already prepared.");

        var selectedPaths = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (selectedPaths.Length == 0)
            throw new InvalidOperationException("Select one or more items before using Link get.");

        _preparedPaths = selectedPaths;
        Changed?.Invoke(this, EventArgs.Empty);
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