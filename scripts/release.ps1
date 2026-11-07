[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$phase = 'preflight'
$messagePath = $null

try {
    $descriptionPath = Join-Path $root 'ReleaseDescription.txt'
    Write-Host "Release information: $descriptionPath"
    Write-Host 'The first line must contain the version; the remaining lines contain the release notes.'
    $confirmation = Read-Host 'Have you edited and checked this file for the release? Type yes to confirm'
    if ($confirmation -cne 'yes') { throw 'Release was not confirmed.' }
    if (-not (Test-Path -LiteralPath $descriptionPath -PathType Leaf)) { throw 'ReleaseDescription.txt was not found.' }
    $description = [System.IO.File]::ReadAllText($descriptionPath)
    $parts = [regex]::new("\r\n|\n|\r").Split($description, 2)
    $version = $parts[0]
    $comment = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    if ([string]::IsNullOrWhiteSpace($version) -or $version -cne $version.Trim() -or $version -match '[\x00-\x1f\x7f]') {
        throw 'The version must be a non-empty, single-line string without leading or trailing whitespace or control characters.'
    }
    try { [void][System.Xml.XmlConvert]::VerifyXmlChars($version); [void][System.Xml.XmlConvert]::VerifyXmlChars($comment) }
    catch { throw 'The version or comment contains characters that cannot be stored in the release list.' }

    $status = @(& git -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Git working tree status.' }
    if ($status.Count -ne 1 -or $status[0] -cnotmatch '^( M|M |MM) ReleaseDescription\.txt$') {
        throw 'The only uncommitted file must be the modified ReleaseDescription.txt, with no other staged, unstaged, or untracked files.'
    }
    & git -C $root diff --quiet HEAD -- ReleaseDescription.txt
    if ($LASTEXITCODE -ne 1) { throw 'ReleaseDescription.txt must differ from HEAD.' }

    $tag = "v$version"
    & git -C $root check-ref-format "refs/tags/$tag"
    if ($LASTEXITCODE -ne 0) { throw "Invalid Git tag name: $tag" }
    & git -C $root show-ref --verify --quiet "refs/tags/$tag"
    if ($LASTEXITCODE -eq 0) { throw "Git tag already exists: $tag" }
    if ($LASTEXITCODE -ne 1) { throw 'Could not check existing Git tags.' }
    foreach ($identity in @('GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT')) {
        $null = & git -C $root var $identity
        if ($LASTEXITCODE -ne 0) { throw "Git identity is not configured: $identity" }
    }

    $releasePath = Join-Path $root 'RELEASES.html'
    if (Test-Path -LiteralPath $releasePath) {
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $reader = [System.Xml.XmlReader]::Create($releasePath, $settings)
        $document = [System.Xml.XmlDocument]::new()
        try { $document.Load($reader) } finally { $reader.Dispose() }
        $releases = @($document.SelectNodes('/html/body/main/div/table/tbody/tr'))
        if ($releases.Count -eq 0) { throw 'RELEASES.html has an invalid or empty release table.' }
        foreach ($release in $releases) {
            if (@($release.SelectNodes('./td')).Count -ne 2 -or @($release.SelectNodes('./td[2]/table/tbody/tr')).Count -eq 0) {
                throw 'RELEASES.html has an invalid release entry.'
            }
        }
        $previousCommitCell = $releases[0].SelectSingleNode('./td[2]/table/tbody/tr[1]/td[3]')
        if (-not $previousCommitCell -or $previousCommitCell.InnerText -cnotmatch '^([0-9a-f]{40}|[0-9a-f]{64})$') {
            throw 'The latest release does not contain a valid full commit ID.'
        }
        & git -C $root merge-base --is-ancestor $previousCommitCell.InnerText HEAD
        if ($LASTEXITCODE -ne 0) { throw 'The latest release commit is not an ancestor of HEAD.' }
    } elseif (Test-Path -LiteralPath (Join-Path $root 'RELEASES.md')) {
        throw 'RELEASES.md exists but RELEASES.html is missing; migrate the legacy list before publishing.'
    }

    $message = "Release $version"
    if ($comment.Length -gt 0) { $message += "`n`n" + $comment }
    $messagePath = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-release-message-' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($messagePath, $message, [System.Text.UTF8Encoding]::new($false))

    $phase = 'Debug build'
    $debugDirectory = Join-Path $root 'bin\Debug\net10.0-windows'
    $debugExecutables = @('KIS Explorer.exe', 'SUTWinExplorer.exe') | ForEach-Object { Join-Path $debugDirectory $_ }
    $runningDebugProcesses = @(Get-Process -Name 'KIS Explorer', 'SUTWinExplorer' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path -in $debugExecutables } catch { $false }
    })
    if ($runningDebugProcesses.Count -gt 0) {
        $runningDebugProcesses | Stop-Process -ErrorAction Stop
        $runningDebugProcesses | Wait-Process -ErrorAction Stop
    }
    & dotnet build (Join-Path $root 'SUTWinExplorer.csproj') -c Debug
    if ($LASTEXITCODE -ne 0) { throw "Debug build failed with exit code $LASTEXITCODE." }

    $phase = 'installer builds'
    & (Join-Path $PSScriptRoot 'build-installer.ps1')

    $phase = 'release commit'
    & git -C $root add -- ReleaseDescription.txt
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage ReleaseDescription.txt.' }
    & git -C $root add -u -- bin/Debug/net10.0-windows bin/Release/net10.0-dependent
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage tracked build outputs.' }
    & git -C $root commit --cleanup=verbatim -F $messagePath
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the release commit.' }

    $phase = 'first release-list update'
    & (Join-Path $PSScriptRoot 'create_release_notes.ps1')
    & git -C $root add -- RELEASES.html
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the release list.' }
    & git -C $root commit -m "Update release list for $version"
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the first release-list update.' }

    $phase = 'second release-list update'
    & (Join-Path $PSScriptRoot 'create_release_notes.ps1')
    & git -C $root add -- RELEASES.html
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the release list.' }
    & git -C $root commit -m "Include release list commit for $version"
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the second release-list update.' }

    $phase = 'Git tag'
    & git -C $root tag -a $tag --cleanup=verbatim -F $messagePath HEAD
    if ($LASTEXITCODE -ne 0) { throw "Could not create Git tag '$tag'." }
    Write-Host "Release '$version' completed locally with tag '$tag'. Nothing was pushed."
} catch {
    throw "Release stopped during ${phase}: $($_.Exception.Message) No commits or changes were automatically reverted."
} finally {
    if ($messagePath) { Remove-Item -LiteralPath $messagePath -ErrorAction SilentlyContinue }
}