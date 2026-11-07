# Versions and Releases

## Requirements

Use PowerShell and Git in a Git working directory with at least one commit. Run the commands from the project directory. A browser with JavaScript enabled can open [RELEASES.html](RELEASES.html) directly; no server is required.

## Release Description

Edit [ReleaseDescription.txt](ReleaseDescription.txt) by hand. The first line is the version; all following lines are the release comment:

```text
1.2.0
Improved use case management.
Updated navigation.
```

The version is a complete text string, such as `1.01` or `Preview 1`. It must be nonempty, fit on one line, have no control characters or leading or trailing whitespace, and be valid XML text. Matching is case-sensitive. The comment may be empty and may contain multiple lines and XML-compatible special characters. It appears in the colored separator under **Commit Message**; removing it from the file clears it on the next publication.

Editing this file does not publish a release. Application builds and installer builds use only its first line as the product version. The separate numeric Windows file version remains `1.0.0.0`.

## Automated Release

Edit [ReleaseDescription.txt](ReleaseDescription.txt), then run
[release.ps1](release.ps1) from the project directory:

```powershell
.\release.ps1
```

The script displays the file path and asks you to confirm that its version and
release notes have been edited and checked. Enter exactly `yes` to continue;
any other response cancels the release before the build or Git changes.
The only uncommitted file must be the modified description; staged and unstaged
changes and untracked files are checked, excluding files ignored by Git. The
script requires Windows x64, PowerShell, Git with a configured author and
committer identity, the .NET 10 SDK and Inno Setup 6. The installer compiler
must be on `PATH` or in its standard installation directory; see
[BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md). The version must also produce a
valid Git tag named `v<version>`, and that tag must not already exist.

The script builds Debug, then builds all configured installer profiles. It
terminates an application running from the Debug output before the Debug build;
the installer script stops if a selected Release executable is running. It
commits the description and changes to already tracked Debug and dependent
Release build outputs, updates and commits the release list twice, and creates
an annotated tag on the second list commit. The first commit and tag message
contain `Release <version>` and the full release comment. The other commit
messages are `Update release list for <version>` and `Include release list
commit for <version>`. Nothing is pushed or uploaded.

On failure the script reports the phase and leaves any completed commits,
staged files, and build outputs in place; it does not revert them. Inspect the
Git state before deciding how to continue. Installer outputs remain in the
ignored `installer/Release` directory.

## Manual Release

1. Set the version and comment in [ReleaseDescription.txt](ReleaseDescription.txt).
2. Build the application and, if needed, installers as described in [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md). The installer script builds and publishes each selected Release profile before creating its installer, so no separate Release build or publish is needed first. The Debug build is a separate check and is not used as installer input. Commit the description and the intended build changes.
3. Publish the release list by running `./create_release_notes.ps1` in PowerShell. The script takes no arguments and reads the current description file.
4. Commit [RELEASES.html](RELEASES.html).
5. Run `./create_release_notes.ps1` again with the same description. The new list commit is added to the same version.
6. Commit the updated release list.
7. Create an annotated Git tag named `v<version>` on that second release-list commit. Its message contains `Release <version>` followed by the full release comment. The tag is local; push it separately if needed.

The last commit cannot appear in the list contained in that same commit: changing the list would change the commit itself. It is included in the next release, assuming it remains in the history. Additional commits between publications are included too. Only committed changes appear as commit entries; the script reads the description from the working tree, so commit it before publication to keep the published version and comment traceable.

The first release includes all commits reachable from `HEAD`. Later publications include commits reachable from `HEAD` since the first commit in the top release. The previous boundary must still be an ancestor of `HEAD`. Commits follow Git's topological order, and full commit IDs identify the boundary. The release-notes generator does not use or create Git tags; the separate tagging step marks the completed release. Reusing an existing version extends that release and moves it to the top, even if it was previously an older entry.

Without new commits, a changed comment can still update an existing release without reordering it. A new version cannot be published without new commits, and a repeated run with no new commits or comment change stops with an error. The script never modifies the description file.

An installer built in step 2 cannot contain the release list produced in steps 3-6. The current installer packages the published application, not the repository's release list; distribute the list separately if needed.

## Release List

Each commit shows its local ISO timestamp, full message, and commit ID. The timestamp uses the Windows time zone configured when the entry is created, including the offset applicable at the time of the commit. Messages preserve line breaks and blank lines. For display, long lines are wrapped to at most 120 Unicode code points, including ellipsis markers; the stored message remains unchanged.

The page title and two-row column header remain fixed at the top, and a horizontal scrollbar remains at the bottom. Each commit row repeats its version and has an alternating arrow button. Up arrows jump to the beginning of that release; down arrows jump to the beginning of the next older release and are disabled when none exists.

## Legacy Lists

The parameterless script does not migrate an older `RELEASES.md`. If that file exists without `RELEASES.html`, it stops instead of silently creating a new list. Migrate the old list with the earlier migration-capable script before using this workflow.

## Build and Installers

Build the application or installers as described in [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md). In installer filenames, Windows-prohibited characters and `%`, `{`, `}` are encoded as `%` followed by four hexadecimal digits; installer metadata retains the original version text.