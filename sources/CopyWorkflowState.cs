namespace SUTWinExplorer;

internal sealed class CopyWorkflowState
{
    private string[]? _preparedPaths;

    public static CopyWorkflowState Shared { get; } = new();

    public event EventHandler? Changed;

    public bool IsPrepared => _preparedPaths is not null;

    public IReadOnlyList<string> PreparedPaths => _preparedPaths ??
        throw new InvalidOperationException(LocalizedText.Get("Transfer_Error_CopyNotPrepared"));

    public void Prepare(IEnumerable<string> paths)
    {
        if (IsPrepared)
            throw new InvalidOperationException(LocalizedText.Get("Transfer_Error_CopyPrepared"));

        var selectedPaths = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (selectedPaths.Length == 0)
            throw new InvalidOperationException(LocalizedText.Get("Transfer_Error_CopyNoSelection"));

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