# Versioning and Release List Implementation

This document describes the implementation. For usage, see [RELEASE_GUIDE.md](RELEASE_GUIDE.md).

## Files and Responsibilities

- [release.ps1](release.ps1) reads Git history, maintains releases and comments, and updates the version file when commits are added.
- [VERSION_READONLY](VERSION_READONLY) contains the shared version and must only be changed by the release script.
- [RELEASES.html](RELEASES.html) contains both the stored release data and its browser presentation.
- [SUTWinExplorer.csproj](SUTWinExplorer.csproj) reads the version as `InformationalVersion`, suppresses the automatically appended source revision, and fails the build if the version file is missing or empty. The numeric Windows file version remains `1.0.0.0`.
- [installer-config/build-installer.ps1](installer-config/build-installer.ps1) reads the same version for Inno Setup metadata and encodes filename-prohibited characters for the output filename.
- [tests/Release.Tests.ps1](tests/Release.Tests.ps1) exercises the workflow in an isolated temporary Git repository.

## Release Processing

The `Release` parameter set accepts mandatory `Version` and optional `Comment` arguments. The script rejects a blank version, leading or trailing whitespace, control characters, and characters that cannot be represented in XML. A supplied comment must also contain valid XML characters. Versions are compared case-sensitively.

For a new list, `git log --topo-order` reads all commits reachable from `HEAD`. If a list exists, the script reads it with `XmlDocument`, validates its release rows, and uses the first commit ID of the top release as the boundary. The ID must be a full 40- or 64-character hexadecimal hash and an ancestor of `HEAD`. Git then enumerates `<boundary>..HEAD` in topological order. Uncommitted changes and Git tags are not used.

Each new commit is read with `git show`, including its full message and Unix timestamp. At insertion, the timestamp is converted to the configured local time zone and stored in ISO format with its applicable offset. Previously stored timestamps and messages are not regenerated during normal updates.

When new commits exist, a new version is inserted at the top, or commits are prepended to the matching existing version, which is moved to the top. The version file is updated in either case. Moving an older release to the top keeps its newest added commit as the global boundary; other releases and their commits remain intact.

The script distinguishes an omitted comment from an explicitly empty one via `PSBoundParameters`. A supplied value is saved in the release row's `data-release-comment` attribute; omission preserves an existing value and an empty string clears its displayed text. If no commits are available, an explicitly supplied comment can update an existing release without moving it or updating the version file. All other no-commit runs fail. Boundary validation still applies to comment-only updates.

## HTML Data and Presentation

The saved document is both browser-renderable HTML and XML. DTD processing is prohibited when reading it. The outer table has one row per release, containing a version cell and an inner commit table. Each saved commit row has timestamp, message, and commit ID cells, in that order. The script locates releases and the next boundary using XPath, so the saved element structure and cell positions are part of its data contract. XML text nodes and attributes escape special characters and preserve comment line breaks.

The template, CSS, and JavaScript live in `New-ReleaseDocument`. Existing HTML is read and extended rather than replaced with the current template, so presentation changes must be applied to both the template and an existing release list. Template line endings are normalized before XML parsing; the XML writer entitizes newlines where necessary to preserve embedded text and attributes.

In the browser, JavaScript clears the per-release table headings, then copies the comment into the colored separator's `Commit Message` cell using `textContent`. This displays literal text, including line breaks, rather than interpreting HTML. A release without a comment has an empty separator.

JavaScript also wraps commit messages for display only. It preserves existing line breaks and limits each displayed line, including markers, to 120 Unicode code points. Inserted breaks have an ellipsis at the end of one line and the beginning of the next. The message column reserves at least 122 monospace character widths plus cell padding and borders; the stored message is unchanged.

Navigation and repeated-version cells are added to the browser DOM only, leaving saved XPath positions unchanged. Arrows alternate within each release, beginning with up; up targets that release, down targets the next older release, and a missing target disables the button. Scrolling accounts for the fixed header.

JavaScript constructs the fixed two-row header beneath the fixed page title from the table column positions. It synchronizes the header and the fixed bottom scrollbar with the table's horizontal scrolling and recalculates dimensions on resize. The document can be opened locally without a server; interactive presentation requires JavaScript.

## Writing and Migration

The script serializes the HTML to a temporary UTF-8 file in the project directory. When updating the active version, it also prepares a temporary version file. Existing destinations are replaced with backups; if an error occurs after the version has changed, the script attempts to restore its previous contents. Temporary files and backups are removed afterward. The two destination files do not form one atomic transaction. Comment-only updates and migration do not write the version file.

The separate `-Migrate` parameter set imports an older `RELEASES.md` when no `RELEASES.html` exists. It reads stored versions and commit IDs, then retrieves commit messages and local timestamps from Git to build the new document. It neither deletes the old file nor changes the version file, and it refuses to overwrite an existing HTML list.

## Verification

```powershell
.\tests\Release.Tests.ps1
```

The test covers release boundaries, extension and ordering, full messages, local timestamps, comment storage and updates, migration, and error cases. If Node.js is available, a DOM mock also checks generated JavaScript for message wrapping, comment text, navigation, and the fixed header.