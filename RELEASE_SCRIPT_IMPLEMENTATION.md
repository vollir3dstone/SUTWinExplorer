# Versioning and Release List Implementation

This document describes the implementation. For usage, see [RELEASE_GUIDE.md](RELEASE_GUIDE.md).

## Files and Responsibilities

- [release.ps1](release.ps1) orchestrates the local build, installer, release commits, list updates, and annotated Git tag.
- [create_release_notes.ps1](create_release_notes.ps1) reads the release description and Git history and maintains releases and comments without modifying the description file.
- [ReleaseDescription.txt](ReleaseDescription.txt) is edited by hand; its first line is the shared version and the remaining text is the release comment.
- [RELEASES.html](RELEASES.html) contains both the stored release data and its browser presentation.
- [SUTWinExplorer.csproj](SUTWinExplorer.csproj) reads the version as `InformationalVersion`, suppresses the automatically appended source revision, and fails the build if the version file is missing or empty. The numeric Windows file version remains `1.0.0.0`.
- [installer-config/build-installer.ps1](installer-config/build-installer.ps1) reads the same version for Inno Setup metadata and encodes filename-prohibited characters for the output filename.
- [tests/Release.Tests.ps1](tests/Release.Tests.ps1) exercises the workflow in an isolated temporary Git repository.
- [tests/ReleaseWorkflow.Tests.ps1](tests/ReleaseWorkflow.Tests.ps1) tests the orchestration in a temporary Git repository with simulated builds.

## Release Processing

The script takes no parameters. It reads [ReleaseDescription.txt](ReleaseDescription.txt) as text, splits at the first line ending, and uses the remainder as the comment, preserving subsequent line endings. A missing file, blank version, leading or trailing version whitespace, control characters, or characters that cannot be represented in XML are rejected. The comment must also contain valid XML characters. Versions are compared case-sensitively.

For a new list, `git log --topo-order` reads all commits reachable from `HEAD`. If a list exists, the script reads it with `XmlDocument`, validates its release rows, and uses the first commit ID of the top release as the boundary. The ID must be a full 40- or 64-character hexadecimal hash and an ancestor of `HEAD`. Git then enumerates `<boundary>..HEAD` in topological order. Uncommitted changes and Git tags are not used.

Each new commit is read with `git show`, including its full message and Unix timestamp. At insertion, the timestamp is converted to the configured local time zone and stored in ISO format with its applicable offset. Previously stored timestamps and messages are not regenerated during normal updates.

When new commits exist, a new version is inserted at the top, or commits are prepended to the matching existing version, which is moved to the top. Moving an older release to the top keeps its newest added commit as the global boundary; other releases and their commits remain intact.

The comment from the file is saved in the release row's `data-release-comment` attribute; an empty comment clears its displayed text. If no commits are available, a changed comment can update an existing release without moving it. All other no-commit runs fail. Boundary validation still applies to comment-only updates. The script uses the working-tree description, while commit entries come from `HEAD`.

## HTML Data and Presentation

The saved document is both browser-renderable HTML and XML. DTD processing is prohibited when reading it. The outer table has one row per release, containing a version cell and an inner commit table. Each saved commit row has timestamp, message, and commit ID cells, in that order. The script locates releases and the next boundary using XPath, so the saved element structure and cell positions are part of its data contract. XML text nodes and attributes escape special characters and preserve comment line breaks.

The template, CSS, and JavaScript live in `New-ReleaseDocument`. Existing HTML is read and extended rather than replaced with the current template, so presentation changes must be applied to both the template and an existing release list. Template line endings are normalized before XML parsing; the XML writer entitizes newlines where necessary to preserve embedded text and attributes.

Browsers do not decode XML entities inside `style` and `script` elements. The embedded selectors therefore avoid characters that the XML writer escapes. When an older list is updated, the script replaces the former affected selectors so they remain usable after serialization. Tests compare the browser-visible raw text with the XML text for both blocks.

In the browser, JavaScript clears the per-release table headings, then copies the comment into the colored separator's `Commit Message` cell using `textContent`. This displays literal text, including line breaks, rather than interpreting HTML. A release without a comment has an empty separator.

JavaScript also wraps commit messages for display only. It preserves existing line breaks and limits each displayed line, including markers, to 120 Unicode code points. Inserted breaks have an ellipsis at the end of one line and the beginning of the next. The message column reserves at least 122 monospace character widths plus cell padding and borders; the stored message is unchanged.

Navigation and repeated-version cells are added to the browser DOM only, leaving saved XPath positions unchanged. Arrows alternate within each release, beginning with up; up targets that release, down targets the next older release, and a missing target disables the button. Scrolling accounts for the fixed header.

JavaScript constructs the fixed two-row header beneath the fixed page title from the table column positions. It synchronizes the header and the fixed bottom scrollbar with the table's horizontal scrolling and recalculates dimensions on resize. The document can be opened locally without a server; interactive presentation requires JavaScript.

## Writing and Legacy Lists

The script serializes the HTML to a temporary UTF-8 file in the project directory, replaces an existing release list with a backup or moves the temporary file into place, and removes temporary files and backups afterward. It never writes the description file.

If an older `RELEASES.md` exists without `RELEASES.html`, the script refuses to create a new list. Migration is no longer a parameter of the publication script; the earlier migration-capable script is required for legacy lists.

## Verification

```powershell
.\tests\Release.Tests.ps1
```

The test covers release boundaries, the two-publication workflow and the next release, extension and ordering, full messages, local timestamps, comment storage and updates, and error cases. If Node.js is available, a DOM mock also checks generated JavaScript for message wrapping, comment text, navigation, and the fixed header.