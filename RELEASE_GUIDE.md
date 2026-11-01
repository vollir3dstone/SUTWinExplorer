# Versions and Releases

## Requirements

Use PowerShell and Git in a Git working directory with at least one commit. Run the commands from the project directory. A browser with JavaScript enabled can open [RELEASES.html](RELEASES.html) directly; no server is required.

## Release Description

Edit [ReleaseDescription.txt](ReleaseDescription.txt) by hand. The first line is the version; all following lines are the release comment:

```text
1.2.0
Improved profile management.
Updated navigation.
```

The version is a complete text string, such as `1.01` or `Preview 1`. It must be nonempty, fit on one line, have no control characters or leading or trailing whitespace, and be valid XML text. Matching is case-sensitive. The comment may be empty and may contain multiple lines and XML-compatible special characters. It appears in the colored separator under **Commit Message**; removing it from the file clears it on the next publication.

Editing this file does not publish a release. Application builds and installer builds use only its first line as the product version. The separate numeric Windows file version remains `1.0.0.0`.

## Publish a Release

1. Set the version and comment in [ReleaseDescription.txt](ReleaseDescription.txt).
2. Build the application and, if needed, installers as described in [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md). Commit the description and the intended build changes.
3. Publish the release list by running `./release.ps1` in PowerShell. The script takes no arguments and reads the current description file.
4. Commit [RELEASES.html](RELEASES.html).
5. Run `./release.ps1` again with the same description. The new list commit is added to the same version.
6. Commit the updated release list.

The last commit cannot appear in the list contained in that same commit: changing the list would change the commit itself. It is included in the next release, assuming it remains in the history. Additional commits between publications are included too. Only committed changes appear as commit entries; the script reads the description from the working tree, so commit it before publication to keep the published version and comment traceable.

The first release includes all commits reachable from `HEAD`. Later publications include commits reachable from `HEAD` since the first commit in the top release. The previous boundary must still be an ancestor of `HEAD`. Commits follow Git's topological order, and full commit IDs identify the boundary; Git tags are neither required nor created. Reusing an existing version extends that release and moves it to the top, even if it was previously an older entry.

Without new commits, a changed comment can still update an existing release without reordering it. A new version cannot be published without new commits, and a repeated run with no new commits or comment change stops with an error. The script never modifies the description file.

An installer built in step 2 cannot contain the release list produced in steps 3-6. The current installer packages the published application, not the repository's release list; distribute the list separately if needed.

## Release List

Each commit shows its local ISO timestamp, full message, and commit ID. The timestamp uses the Windows time zone configured when the entry is created, including the offset applicable at the time of the commit. Messages preserve line breaks and blank lines. For display, long lines are wrapped to at most 120 Unicode code points, including ellipsis markers; the stored message remains unchanged.

The page title and two-row column header remain fixed at the top, and a horizontal scrollbar remains at the bottom. Each commit row repeats its version and has an alternating arrow button. Up arrows jump to the beginning of that release; down arrows jump to the beginning of the next older release and are disabled when none exists.

## Legacy Lists

The parameterless script does not migrate an older `RELEASES.md`. If that file exists without `RELEASES.html`, it stops instead of silently creating a new list. Migrate the old list with the earlier migration-capable script before using this workflow.

## Build and Installers

Build the application or installers as described in [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md). In installer filenames, Windows-prohibited characters and `%`, `{`, `}` are encoded as `%` followed by four hexadecimal digits; installer metadata retains the original version text.