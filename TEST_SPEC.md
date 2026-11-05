# Test Specification

## Automatic Test Selection

Automatically run only production tests needed to verify the change and its
possible effects. Select tests based on the changed behavior, its dependencies,
and affected interfaces, not simply on the availability of a full test suite.

A test may be omitted only when it is possible to assess with confidence that
the change cannot affect the functionality it covers. If the impact is unclear,
run the test. Changes to shared code, cross-component contracts, or common
workflows may therefore require broader tests.

Do not routinely run the entire test suite or repeat successful tests without
a specific reason. Run broader suites when the impact cannot be bounded, when
the project or the user explicitly requires them, or when focused verification
reveals a risk that warrants them.

Prefer focused tests for the affected behavior. If no suitable focused test is
available, use the necessary broader test or add a focused test where practical.
Report which checks ran and any relevant behavior that remains unverified.

## Production and Experimental Tests

Production tests cover supported application behavior and belong in the standard
test suite. Experimental tests cover alternative or exploratory implementations
that are not used in production. Keep them separate so known experimental
limitations do not make the production suite fail.

Place standard tests directly in `tests` and experimental tests in
`tests/experimental`. Do not run experimental tests as part of automatic
production verification or the standard full test run. Run the relevant
experimental tests when changing an experiment or when explicitly requested;
report their failures separately rather than ignoring them or counting them as
production failures. Shared changes must still be verified against the affected
production behavior.

When an experimental implementation becomes supported production behavior,
make its applicable tests part of the standard suite and resolve failures that
contradict its production requirements.

## Full Test Run

Run the standard PowerShell tests in separate STA processes with:

```powershell
pwsh -NoProfile -File .\tests\Run-AllTests.ps1
```

Use `-ListOnly` to display the execution order without running the tests.
Test files are discovered automatically; the long-running directory observer
test runs last and covers the production FileSystemWatcher observer. Tests in
`tests/experimental` are excluded from the standard run. The runner selects the
production observer for all its test processes, regardless of the caller's
environment. It continues after failures and reports them at the end.