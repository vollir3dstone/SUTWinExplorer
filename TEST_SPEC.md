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

## Test Organization

### Purpose and Boundaries

Organize tests around the behavior they establish, not just the control or file
that happens to implement it. A test name should identify its primary subject.
The intended boundaries are:

- **Shell access:** Test Shell-facing APIs, native operations and their
	contracts independently of interactive view behavior. Shell integration may
	still require Windows, real files and native dialogs.
- **Components:** Test a reusable component's own rules and presentation in
	a component-focused test. Examples include the directory location dialog,
	context-menu factory and sort-order widget.
- **Actions and workflows:** Group the action's behavior by action, regardless
	of where it can be invoked. Test its inputs, outcomes, errors, state changes
	and relevant variants there. Name the test for the action or workflow, not
	for its current button, menu or view.
- **View interactions:** Test component-specific behavior in ContentView tests
	and interactions within one fixed Pathview in Pathview tests. For an action,
	these tests concentrate on the local trigger, its availability, correct
	target selection and the resulting visible update.
- **Multiple views:** Test coordination between Pathviews in MultiPathview
	integration tests, including shared workflow state, transferred criteria and
	propagation of path changes. Main-window coordination and application startup
	can have their own integration tests.

Filtering and sorting local to ContentView belong with ContentView behavior,
not in separate tests for every control that exposes the same rule. Menu
composition and sequencing belong to menu or view integration tests: they
establish how the menu and its surroundings work together, rather than the
complete behavior of every action in the menu.

### Actions and Triggers

An action is the operation and its behavior; a trigger is an entry point such
as a button, context-menu command or keyboard shortcut. The same action can be
triggered from ContentView, Pathview or another location. A currently exclusive
entry point does not make the action specific to that view: for example,
Relocate is currently exposed by a Pathview button but its action tests are not
named after Pathview, and another trigger may be added later.

Test the behavioral cases once at the action or workflow level where practical.
Separately check each supported trigger and its enabled or disabled state in the
appropriate location-specific test. Establish that it invokes the intended
action for the intended selection or path and that the relevant view updates.
Checking a resulting file, clipboard value or workflow state may be necessary
to prove that wiring; it does not require repeating the action's full matrix of
success, failure and edge cases for every trigger. An end-to-end case is useful
when a lower-level test alone cannot establish that the pieces are connected.

### Current Layout

The current suite is organized around these boundaries, but is not yet a strict
one-test-file-per-subject partition. Important examples are:

- `SutShell.Tests.ps1` covers Shell access; `SutContextMenuFactory.Tests.ps1`,
	`DirectoryLocationDialog.Tests.ps1` and `SortOrderBaseline.Tests.ps1` cover
	components or their baseline behavior.
- `RenameActions.Tests.ps1`, `MoveActions.Tests.ps1`, `CopyActions.Tests.ps1`,
	`LinkActions.Tests.ps1` and `RelocateActions.Tests.ps1` group action cases.
	New item, delete, properties and item clipboard have their own action tests;
	`NewItemOperations.Tests.ps1` also tests the underlying creation component.
- `ContentViewFilteringAndSorting.Tests.ps1`, `ContentViewRename.Tests.ps1`
	and `ContentViewActionInteractions.Tests.ps1` cover ContentView behavior and
	action entry points. `Pathview.Tests.ps1` includes Pathview entry points;
	`MultiPathview.Tests.ps1` covers interactions across Pathviews.
- `InsertedItems.Tests.ps1` tests selection, visibility and filter updates
	after insertion, including interactions across views and actual Pathview
	background-menu execution. `PathviewRename.Tests.ps1` covers path changes
	within one Pathview; `MultiPathviewDirectoryChanges.Tests.ps1` covers their
	propagation and observer coordination across Pathviews.

Some action tests still use a view or dialog to reach the behavior under test.
Copy, Move and Link test successful and failed execution in both existing view
handlers using a shared test helper. The ContentView path raises the execute
button's event; the Pathview path invokes its menu handler directly. Separately,
`InsertedItems.Tests.ps1` selects the commands in the actual Pathview background
menu and checks the resulting selection and filter behavior. These checks cover
different boundaries; the direct handler call alone does not test menu wiring.
Relocate currently invokes Pathview's operation method, while Delete and New
item tests exercise GUI flows. Conversely, location-specific
tests such as `ContentViewActionInteractions.Tests.ps1` still include checks
of workflow state and action outcomes alongside menu and trigger checks. Shell
access and action tests can also overlap on a contract. These are descriptions
of the current coverage, not a claim that the separation is complete.

### Ambiguous Cases and Evolution

Boundaries are not always sharp. A successful trigger test must observe enough
of the action to distinguish correct wiring from a no-op; an action can cause
both a filesystem change and a visible update; and a directory rename or move
can update several views, a tab label, saved configuration and observers.
Choose the primary assertion as the test's home: action rules and edge cases in
the action test, control and visual behavior in the relevant view test, and
coordination or propagation in the integration test. Some overlap is justified
when it proves a different contract at another boundary.

As tests are changed, move clearly independent behavior toward these boundaries
and add missing trigger checks where appropriate. Preserve coverage and
independent fixtures; do not mechanically split a coherent integration scenario
or duplicate every case merely to satisfy file names. If a case fits more than
one category, favor a clear, maintainable home and make its purpose evident.

### Isolation

Each test must create and clean up its own fixtures and must not depend on the
order in which tests run. Use unique temporary paths and restore shared state
such as clipboard contents, prepared workflows, windows and test-created
recycle-bin items when used. Cleanup must also run on failure. Shared helpers
may provide probes and assertions, but must not supply state established by
another test. The standard runner starts each test in a separate STA process;
that process isolation does not replace fixture cleanup.

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

When invoking the runner or an individual test from a persistent interactive
PowerShell session, let the `pwsh -File` child process return normally; do not
call `exit` in the surrounding session. Inspect the child's exit code and
report failures rather than masking them. A session termination reported by the
terminal and a nonzero test-process exit are distinct events and should be
diagnosed separately.

The drag-and-drop integration test also starts external PowerShell probes. It
waits for them to exit normally, requests window closure when needed, and checks
their exit codes. Forced termination is reserved for a probe that does not
close in time and is reported as a test failure.