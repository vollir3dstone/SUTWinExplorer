[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$descriptionPath = Join-Path $PSScriptRoot 'ReleaseDescription.txt'
$releasePath = Join-Path $PSScriptRoot 'RELEASES.html'
$legacyPath = Join-Path $PSScriptRoot 'RELEASES.md'
if (-not (Test-Path -LiteralPath $descriptionPath -PathType Leaf)) { throw 'ReleaseDescription.txt was not found.' }
$description = [System.IO.File]::ReadAllText($descriptionPath)
$parts = [regex]::new("\r\n|\n|\r").Split($description, 2)
$Version = $parts[0]
$Comment = if ($parts.Count -gt 1) { $parts[1] } else { '' }
if ([string]::IsNullOrWhiteSpace($Version) -or $Version -cne $Version.Trim() -or $Version -match '[\x00-\x1f\x7f]') {
    throw 'The version must be a non-empty, single-line string without leading or trailing whitespace or control characters.'
}
try { [void][System.Xml.XmlConvert]::VerifyXmlChars($Version) }
catch { throw 'The version contains characters that cannot be stored in the release list.' }
try { [void][System.Xml.XmlConvert]::VerifyXmlChars($Comment) }
catch { throw 'The comment contains characters that cannot be stored in the release list.' }

function Get-CommitDetails([string]$commitId) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.Arguments = "-c i18n.logOutputEncoding=UTF-8 show --no-patch --format=format:%ct%x00%B $commitId"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $text = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Could not read commit $commitId`: $errorText" }
    } finally { $process.Dispose() }
    $separator = $text.IndexOf([char]0)
    if ($separator -lt 1) { throw "Unexpected Git output for commit $commitId." }
    $seconds = [long]::Parse($text.Substring(0, $separator), [System.Globalization.CultureInfo]::InvariantCulture)
    return @{
        Timestamp = [DateTimeOffset]::FromUnixTimeSeconds($seconds).ToLocalTime().ToString("yyyy-MM-dd'T'HH:mm:sszzz", [System.Globalization.CultureInfo]::InvariantCulture)
        Message = $text.Substring($separator + 1)
    }
}

function Read-ReleaseXml([string]$path) {
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create($path, $settings)
    $xml = [System.Xml.XmlDocument]::new()
    $xml.PreserveWhitespace = $true
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    return $xml
}

function New-ReleaseDocument {
    $xml = [System.Xml.XmlDocument]::new()
    $xml.PreserveWhitespace = $true
    $template = @'
<html lang="de">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>KIS Explorer - Releases</title>
<style>
:root { color-scheme: light; font-family: "Segoe UI", sans-serif; color: #202b2a; background: #f3f5f4; }
* { box-sizing: border-box; }
body { margin: 0; padding-bottom: 30px; }
header { position: fixed; top: 0; left: 0; right: 0; z-index: 4; padding: 22px 24px 18px; background: #163d39; color: white; }
header p { margin: 0 0 4px; font-size: 13px; color: #b7d9cf; }
h1 { margin: 0; font-size: 24px; font-weight: 600; }
main { padding: 20px 24px 24px; }
#sticky-header { position: fixed; top: 0; z-index: 3; overflow: hidden; background: #e5eeea; }
#header-track { width: max-content; color: #304c46; font-size: 13px; font-weight: 600; }
.header-row { display: grid; }
.header-row div { padding: 10px 12px; border: 1px solid #d5dfdb; }
#table-scroll { overflow-x: auto; }
table { border-collapse: collapse; }
.releases { width: max-content; min-width: 100%; table-layout: auto; background: white; }
.releases th, .releases td { border: 1px solid #d5dfdb; text-align: left; vertical-align: top; }
.releases th { background: #e5eeea; color: #304c46; font-size: 13px; padding: 10px 12px; }
.releases thead { display: none; }
.releases .commits thead { display: table-header-group; }
.releases .version { width: 65px; overflow-wrap: anywhere; font-weight: 600; padding: 12px; }
.releases .changes { padding: 0; }
.commits { width: max-content; min-width: 100%; table-layout: fixed; }
.commits th, .commits td { border-top: 0; border-left: 0; padding: 10px 12px; }
.commits th { padding: 5px 0; font-size: 0; line-height: 0; color: transparent; }
.commits thead th.message { padding: 5px 12px; color: #304c46; font-size: 13px; font-weight: 600; line-height: 1.5; white-space: pre-wrap; overflow-wrap: anywhere; }
.commits th:last-child, .commits td:last-child { border-right: 0; }
.commits tr:last-child td { border-bottom: 0; }
.commits .row-navigation { width: 46px; text-align: center; padding: 5px; }
.commits .row-version { width: 65px; overflow-wrap: anywhere; font-size: 13px; }
.row-navigation button { width: 30px; height: 30px; padding: 0; border: 1px solid #b7c9c2; background: #f3f8f5; color: #224e43; cursor: pointer; font-size: 18px; }
.row-navigation button:hover:not(:disabled) { background: #dcece4; }
.row-navigation button:disabled { opacity: 0.35; cursor: default; }
.commits .timestamp { width: 205px; white-space: nowrap; font-size: 13px; font-variant-numeric: tabular-nums; }
.commits .message { width: calc(122ch + 25px); min-width: calc(122ch + 25px); white-space: pre-wrap; overflow-wrap: anywhere; font-family: Consolas, monospace; font-size: 13px; line-height: 1.5; }
.commits .commit-id { width: 345px; font-family: Consolas, monospace; font-size: 12px; overflow-wrap: anywhere; }
#bottom-scroll { position: fixed; z-index: 2; bottom: 0; left: 0; width: 100%; height: 20px; overflow-x: scroll; overflow-y: hidden; background: #dce5e1; scrollbar-color: #527b6e #dce5e1; scrollbar-width: auto; }
#scroll-width { height: 1px; }
@media (max-width: 600px) { header { padding: 18px 16px; } main { padding: 16px; } }
</style>
</head>
<body>
<header><p>KIS Explorer</p><h1>Releases</h1></header>
<main><div id="table-scroll"><table class="releases"><thead><tr><th class="version">Version</th><th>Changes</th></tr></thead><tbody></tbody></table></div></main>
<div id="bottom-scroll" tabindex="0" aria-label="Tabelle horizontal scrollen"><div id="scroll-width"> </div></div>
<script>
function wrapMessageLine(line) {
    let remaining = Array.from(line);
    let prefix = '';
    const ellipsis = String.fromCodePoint(0x2026);
    const lines = [];
    while (remaining[120 - prefix.length] !== undefined) {
        const count = 119 - prefix.length;
        lines.push(prefix + remaining.slice(0, count).join('') + ellipsis);
        remaining = remaining.slice(count);
        prefix = ellipsis;
    }
    lines.push(prefix + remaining.join(''));
    return lines.join('\n');
}
document.querySelectorAll('.commits tbody .message').forEach(function (cell) {
    cell.textContent = cell.textContent.split('\n').map(wrapMessageLine).join('\n');
});
document.querySelectorAll('.commits thead th').forEach(function (cell) { cell.textContent = ''; });
const surface = document.getElementById('table-scroll');
const scrollbar = document.getElementById('bottom-scroll');
const scrollWidth = document.getElementById('scroll-width');
const pageTitle = document.querySelector('body header');
const stickyHeader = document.createElement('div');
stickyHeader.id = 'sticky-header';
const headerTrack = document.createElement('div');
headerTrack.id = 'header-track';
const releases = Array.from(surface.querySelector('.releases').tBodies[0].rows);
releases.forEach(function (release, releaseIndex) {
    const version = release.querySelector('td.version').textContent;
    const heading = release.querySelector('.commits thead tr');
    heading.querySelector('th.message').textContent = release.getAttribute('data-release-comment') || '';
    ['row-version', 'row-navigation'].forEach(function (className) {
        const cell = document.createElement('th');
        cell.className = className;
        heading.insertBefore(cell, heading.firstElementChild);
    });
    release.querySelectorAll('.commits tbody tr').forEach(function (row, rowIndex) {
        const versionCell = document.createElement('td');
        versionCell.className = 'row-version';
        versionCell.textContent = version;
        row.insertBefore(versionCell, row.firstElementChild);
        const navigationCell = document.createElement('td');
        navigationCell.className = 'row-navigation';
        const button = document.createElement('button');
        const upwards = rowIndex % 2 === 0;
        const target = upwards ? release : releases[releaseIndex + 1];
        const label = upwards ? 'Zum Anfang dieser Version' : 'Zum vorherigen Release';
        button.type = 'button';
        button.textContent = String.fromCodePoint(upwards ? 0x2191 : 0x2193);
        button.title = label;
        button.setAttribute('aria-label', label);
        button.disabled = !target;
        if (target) {
            button.addEventListener('click', function () {
                window.scrollBy({ top: target.getBoundingClientRect().top - stickyHeader.getBoundingClientRect().bottom, behavior: 'smooth' });
            });
        }
        navigationCell.appendChild(button);
        row.insertBefore(navigationCell, row.firstElementChild);
    });
});
const headerRows = [['Version', 'Changes'], ['', '', 'Version', 'Timestamp', 'Commit Message', 'Commit ID']].map(function (labels) {
    const row = document.createElement('div');
    row.className = 'header-row';
    labels.forEach(function (label) {
        const cell = document.createElement('div');
        cell.textContent = label;
        row.appendChild(cell);
    });
    headerTrack.appendChild(row);
    return row;
});
stickyHeader.appendChild(headerTrack);
surface.parentNode.insertBefore(stickyHeader, surface);
function resizeScrollbar() {
    scrollWidth.style.width = (surface.scrollWidth + scrollbar.clientWidth - surface.clientWidth) + 'px';
    scrollbar.scrollLeft = surface.scrollLeft;
    const surfaceBounds = surface.getBoundingClientRect();
    stickyHeader.style.top = pageTitle.offsetHeight + 'px';
    stickyHeader.style.left = surfaceBounds.left + 'px';
    stickyHeader.style.width = surfaceBounds.width + 'px';
    const table = surface.querySelector('.releases');
    const headings = table.querySelectorAll('.commits thead th');
    if (headings.length) {
        const tableLeft = table.getBoundingClientRect().left;
        const positions = Array.from(headings).slice(0, 5).map(function (heading) { return heading.getBoundingClientRect().left - tableLeft; });
        const widths = [positions[0]].concat(positions.slice(1).map(function (position, index) { return position - positions[index]; }));
        headerTrack.style.width = surface.scrollWidth + 'px';
        headerRows[0].style.gridTemplateColumns = positions[2] + 'px 1fr';
        headerRows[1].style.gridTemplateColumns = widths.map(function (width) { return width + 'px'; }).join(' ') + ' 1fr';
    }
    stickyHeader.scrollLeft = surface.scrollLeft;
    document.body.style.paddingTop = (pageTitle.offsetHeight + stickyHeader.offsetHeight) + 'px';
}
surface.addEventListener('scroll', function () { scrollbar.scrollLeft = surface.scrollLeft; stickyHeader.scrollLeft = surface.scrollLeft; });
scrollbar.addEventListener('scroll', function () { surface.scrollLeft = scrollbar.scrollLeft; });
window.addEventListener('resize', resizeScrollbar);
resizeScrollbar();
</script>
</body>
</html>
'@
    $xml.LoadXml($template.Replace("`r`n", "`n"))
    return $xml
}

function New-ReleaseRow($document, [string]$releaseVersion, [string[]]$commitIds) {
    $row = $document.CreateElement('tr')
    $versionCell = $document.CreateElement('td')
    $versionCell.SetAttribute('class', 'version')
    $versionCell.InnerText = $releaseVersion
    [void]$row.AppendChild($versionCell)
    $changesCell = $document.CreateElement('td')
    $changesCell.SetAttribute('class', 'changes')
    [void]$row.AppendChild($changesCell)
    $commitTable = $document.CreateElement('table')
    $commitTable.SetAttribute('class', 'commits')
    [void]$changesCell.AppendChild($commitTable)
    $commitHead = $document.CreateElement('thead')
    [void]$commitTable.AppendChild($commitHead)
    $commitHeading = $document.CreateElement('tr')
    [void]$commitHead.AppendChild($commitHeading)
    $columns = @(@('Timestamp', 'timestamp'), @('Commit Message', 'message'), @('Commit ID', 'commit-id'))
    foreach ($column in $columns) {
        $cell = $document.CreateElement('th')
        $cell.SetAttribute('class', $column[1])
        $cell.InnerText = $column[0]
        [void]$commitHeading.AppendChild($cell)
    }
    $commitBody = $document.CreateElement('tbody')
    [void]$commitTable.AppendChild($commitBody)
    foreach ($commitId in $commitIds) {
        if ($commitId -cnotmatch '^([0-9a-f]{40}|[0-9a-f]{64})$') { throw 'The release list contains an invalid commit ID.' }
        $details = Get-CommitDetails $commitId
        $commitRow = $document.CreateElement('tr')
        $values = @($details.Timestamp, $details.Message, $commitId)
        for ($index = 0; $index -lt $columns.Count; $index++) {
            $cell = $document.CreateElement('td')
            $cell.SetAttribute('class', $columns[$index][1])
            $cell.InnerText = $values[$index]
            [void]$commitRow.AppendChild($cell)
        }
        [void]$commitBody.AppendChild($commitRow)
    }
    return $row
}

$existingRelease = $null
if (Test-Path -LiteralPath $releasePath) {
    $document = Read-ReleaseXml $releasePath
    $style = $document.SelectSingleNode('/html/head/style')
    $script = $document.SelectSingleNode('/html/body/script')
    if ($style) { $style.InnerText = $style.InnerText.Replace('.releases > thead { display: none; }', ".releases thead { display: none; }`n.releases .commits thead { display: table-header-group; }") }
    if ($script) { $script.InnerText = $script.InnerText.Replace("document.querySelector('body > header')", "document.querySelector('body header')") }
    $body = $document.SelectSingleNode('/html/body/main/div/table/tbody')
    $releases = @($document.SelectNodes('/html/body/main/div/table/tbody/tr'))
    if (-not $body -or $releases.Count -eq 0) { throw 'RELEASES.html has an invalid or empty release table.' }
    foreach ($release in $releases) {
        $cells = @($release.SelectNodes('./td'))
        $commits = @($release.SelectNodes('./td[2]/table/tbody/tr'))
        if ($cells.Count -ne 2 -or $commits.Count -eq 0) { throw 'RELEASES.html has an invalid release entry.' }
        if ($cells[0].InnerText -ceq $Version -and -not $existingRelease) { $existingRelease = $release }
    }
    $previousCommitCell = $releases[0].SelectSingleNode('./td[2]/table/tbody/tr[1]/td[3]')
    if (-not $previousCommitCell) { throw 'The latest release does not contain a commit ID.' }
    $previousCommit = $previousCommitCell.InnerText
    if ($previousCommit -cnotmatch '^([0-9a-f]{40}|[0-9a-f]{64})$') { throw 'The latest release does not contain a valid full commit ID.' }
    & git -C $PSScriptRoot merge-base --is-ancestor $previousCommit HEAD
    if ($LASTEXITCODE -ne 0) { throw 'The latest release commit is not an ancestor of HEAD.' }
    $range = "$previousCommit..HEAD"
} else {
    if (Test-Path -LiteralPath $legacyPath) { throw 'RELEASES.md exists but RELEASES.html is missing; migrate the legacy list before publishing.' }
    $document = New-ReleaseDocument
    $body = $document.SelectSingleNode('/html/body/main/div/table/tbody')
    $range = 'HEAD'
}

$lines = @(& git -C $PSScriptRoot log --topo-order '--format=%H' $range)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the Git history.' }
if ($lines.Count -eq 0) {
    if (-not $existingRelease -or $existingRelease.GetAttribute('data-release-comment') -ceq $Comment) {
        throw 'There are no new commits or comment changes to publish.'
    }
    $targetRelease = $existingRelease
} else {
    $newRelease = New-ReleaseRow $document $Version $lines
    if ($existingRelease) {
        $existingCommits = $existingRelease.SelectSingleNode('./td[2]/table/tbody')
        $newCommits = @($newRelease.SelectNodes('./td[2]/table/tbody/tr'))
        for ($index = $newCommits.Count - 1; $index -ge 0; $index--) {
            [void]$existingCommits.PrependChild($newCommits[$index])
        }
        $targetRelease = $existingRelease
    } else {
        $targetRelease = $newRelease
    }
    [void]$body.PrependChild($targetRelease)
}
$targetRelease.SetAttribute('data-release-comment', $Comment)

$writerSettings = [System.Xml.XmlWriterSettings]::new()
$writerSettings.OmitXmlDeclaration = $true
$writerSettings.Indent = $true
$writerSettings.NewLineChars = "`n"
$writerSettings.NewLineHandling = [System.Xml.NewLineHandling]::Entitize
$output = [System.Text.StringBuilder]::new()
$writer = [System.Xml.XmlWriter]::Create($output, $writerSettings)
try { $document.Save($writer) } finally { $writer.Dispose() }
$encoding = [System.Text.UTF8Encoding]::new($false)
$temporaryRelease = Join-Path $PSScriptRoot ('.releases-' + [guid]::NewGuid().ToString('N') + '.tmp')
$releaseBackup = $temporaryRelease + '.bak'
try {
    [System.IO.File]::WriteAllText($temporaryRelease, $output.ToString() + "`n", $encoding)
    if (Test-Path -LiteralPath $releasePath) { [System.IO.File]::Replace($temporaryRelease, $releasePath, $releaseBackup) }
    else { [System.IO.File]::Move($temporaryRelease, $releasePath) }
} finally {
    Remove-Item -LiteralPath $temporaryRelease, $releaseBackup -ErrorAction SilentlyContinue
}
if ($lines.Count -gt 0) { Write-Host "Published version '$Version' with $($lines.Count) commit(s)." }
else { Write-Host "Updated the comment for version '$Version'." }