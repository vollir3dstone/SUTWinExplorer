# Test Specification

## Automatic Test Selection

Automatically run only tests needed to verify the change and its possible
effects. Select tests based on the changed behavior, its dependencies, and
affected interfaces, not simply on the availability of a full test suite.

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