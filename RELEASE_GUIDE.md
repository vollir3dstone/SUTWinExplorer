# Versions and Releases

## Requirements

Use PowerShell and Git in a Git working directory with at least one commit. Run the commands from the project directory. A browser with JavaScript enabled can open [RELEASES.html](RELEASES.html) directly; no server is required.

## Prepare a Release

```powershell
.\release.ps1 "1.2.0"
```

The version is a complete text string, such as `1.01` or `Preview 1`. It must be nonempty, fit on one line, and have no control characters or leading or trailing whitespace. Quote values containing spaces. Version matching is case-sensitive.

The script writes the version to `VERSION_READONLY` and updates the release list. Do not edit `VERSION_READONLY` manually: it supplies the application product version and installer version. The separate numeric Windows file version remains `1.0.0.0`.

The first release includes all commits reachable from `HEAD`. Later releases include commits reachable from `HEAD` since the first commit in the top release. The previous boundary must still be an ancestor of `HEAD`. Commits follow Git's topological order, and full commit IDs identify the boundary; Git tags are neither required nor created.

Running the script with an existing version adds new commits to that release. It moves to the top, even if it was previously an older entry, and becomes the active version. A new release cannot be created without new commits. Uncommitted changes are not included; a subsequent commit containing the version file and release list appears in a later release. Commit both files together with the release.

## Release Comments

Add an optional description as the second argument, or use named parameters:

```powershell
.\release.ps1 "1.2.0" "Improved profile management and navigation"
.\release.ps1 -Version "1.2.0" -Comment "Release overview"
```

The comment appears in the colored separator under **Commit Message**. It may contain line breaks and special characters. When extending a release, omitting the comment preserves the existing one; supplying a comment replaces it. Pass an empty string to clear it:

```powershell
.\release.ps1 "1.2.0" ""
```

If there are no new commits, supplying a comment updates an existing release without changing the active version or release order. If new commits are available, the same command adds them to the specified release and makes that version active. Without new commits, omitting the comment or specifying a new version is an error.

## Release List

Each commit shows its local ISO timestamp, full message, and commit ID. The timestamp uses the Windows time zone configured when the entry is created, including the offset applicable at the time of the commit. Messages preserve line breaks and blank lines. For display, long lines are wrapped to at most 120 Unicode code points, including ellipsis markers; the stored message remains unchanged.

The page title and two-row column header remain fixed at the top, and a horizontal scrollbar remains at the bottom. Each commit row repeats its version and has an alternating arrow button. Up arrows jump to the beginning of that release; down arrows jump to the beginning of the next older release and are disabled when none exists.

## Migration

If an older `RELEASES.md` exists and `RELEASES.html` does not, migrate before preparing another release:

```powershell
.\release.ps1 -Migrate
```

Migration rebuilds the list from the stored commit IDs, so the commits must still be available in Git. It does not change `VERSION_READONLY` or delete `RELEASES.md`, and it refuses to overwrite an existing HTML list.

## Build and Installers

Build the application or installers as described in [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md). In installer filenames, Windows-prohibited characters and `%`, `{`, `}` are encoded as `%` followed by four hexadecimal digits; installer metadata retains the original version text.