$ErrorActionPreference = 'Stop'

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Add-TestCommit([string]$directory, [string]$message, [string]$body = '') {
    $arguments = @('-C', $directory, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-q', '-m', $message)
    if ($body) { $arguments += @('-m', $body) }
    & git @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Could not create test commit.' }
}

$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-release-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & git -C $directory init -q
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize test repository.' }
    Copy-Item (Join-Path $PSScriptRoot '..\release.ps1') $directory
    $script = Join-Path $directory 'release.ps1'
    $versionPath = Join-Path $directory 'VERSION_READONLY'
    $releasePath = Join-Path $directory 'RELEASES.html'
    Add-TestCommit $directory 'First & <commit>'
    $longLine = 'x' * 300
    $message = "Second commit`n`nFirst body line`n  Second body line`n$longLine`n"
    Add-TestCommit $directory 'Second commit' "First body line`n  Second body line`n$longLine"
    $firstHead = (& git -C $directory rev-parse HEAD).Trim()
    $seconds = [long](& git -C $directory show -s '--format=%ct' HEAD)
    $timestamp = [DateTimeOffset]::FromUnixTimeSeconds($seconds).ToLocalTime().ToString("yyyy-MM-dd'T'HH:mm:sszzz", [System.Globalization.CultureInfo]::InvariantCulture)
    $initialComment = "First release <safe> & details`nSecond line"
    & $script '1.01' $initialComment
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    $styles = $list.SelectSingleNode('/html/head/style').InnerText
    Assert-True ($styles -match '\.commits \.message\s*\{[^}]*min-width:\s*calc\(122ch \+ 25px\)') 'Message column does not reserve 122 character widths.'
    Assert-True ($styles -match '\.releases \.version\s*\{[^}]*width:\s*65px' -and $styles -match '\.commits \.row-version\s*\{[^}]*width:\s*65px') 'Version columns are not 65 pixels wide.'
    Assert-True ($styles -match '(?m)^header\s*\{[^}]*position:\s*fixed') 'The page title is not fixed.'
    Assert-True ($styles -match '#sticky-header\s*\{[^}]*position:\s*fixed') 'The two-row header is not fixed.'
    $root = '/html/body/main/div/table/tbody/tr'
    Assert-True ($list.SelectNodes($root).Count -eq 1) 'First release missing.'
    Assert-True ($list.SelectSingleNode("$root[1]").GetAttribute('data-release-comment') -ceq $initialComment) 'Initial release comment did not round-trip.'
    Assert-True ($list.SelectNodes("$root[1]/td[2]/table/tbody/tr").Count -eq 2) 'First release must include all commits.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[2]/table/tbody/tr[1]/td[1]").InnerText -ceq $timestamp) 'Commit timestamp is not in the local time zone.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[2]/table/tbody/tr[1]/td[2]").InnerText -ceq $message) 'Multiline commit message did not round-trip.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[2]/table/tbody/tr[1]/td[3]").InnerText -ceq $firstHead) 'Newest commit must be first.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[2]/table/tbody/tr[2]/td[2]").InnerText -ceq "First & <commit>`n") 'Commit message did not round-trip.'
    & $script '1.01' 'Updated comment without commits'
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    Assert-True ($list.SelectSingleNode("$root[1]").GetAttribute('data-release-comment') -ceq 'Updated comment without commits') 'Comment-only update failed.'
    & $script '1.01' ''
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    Assert-True ($list.SelectSingleNode("$root[1]").GetAttribute('data-release-comment') -ceq '') 'Empty comment did not clear the comment.'

    $legacy = [System.Xml.XmlDocument]::new()
    $legacy.LoadXml('<table><tbody><tr><td>1.01</td><td><table><tbody></tbody></table></td></tr></tbody></table>')
    $legacyBody = $legacy.SelectSingleNode('/table/tbody/tr/td[2]/table/tbody')
    foreach ($commitCell in $list.SelectNodes("$root[1]/td[2]/table/tbody/tr/td[3]")) {
        $row = $legacy.CreateElement('tr')
        $cell = $legacy.CreateElement('td')
        $cell.InnerText = $commitCell.InnerText
        [void]$row.AppendChild($cell)
        [void]$legacyBody.AppendChild($row)
    }
    $legacyPath = Join-Path $directory 'RELEASES.md'
    $legacy.Save($legacyPath)
    Remove-Item -LiteralPath $releasePath
    & $script -Migrate
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    Assert-True ($list.SelectSingleNode("$root[1]/td[2]/table/tbody/tr[1]/td[2]").InnerText -ceq $message) 'Migration did not recover the full commit message.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[2]/table/tbody/tr[1]/td[3]").InnerText -ceq $firstHead) 'Migration changed the release boundary.'
    Assert-True ((Get-Content -LiteralPath $versionPath -Raw).Trim() -ceq '1.01') 'Migration changed the version.'

    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $checkWrapping = @'
const fs = require('fs');
const vm = require('vm');
const html = fs.readFileSync(process.argv[1], 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const cell = { textContent: 'x'.repeat(300) + '\nshort' };
function element() {
    return { style: {}, children: [], offsetHeight: 76, scrollLeft: 0, textContent: '', get firstElementChild() { return this.children[0]; }, appendChild(child) { this.children.push(child); }, insertBefore(child) { this.children.unshift(child); }, setAttribute(name, value) { this[name] = value; }, addEventListener(name, handler) { this[name] = handler; }, getBoundingClientRect() { return { left: 130, bottom: 169 }; } };
}
const headings = [130, 335, 1235].map(left => ({ textContent: 'header', getBoundingClientRect: () => ({ left }) }));
const heading = element();
heading.children = headings.slice();
const secondHeading = element();
secondHeading.children = headings.map(item => ({ ...item }));
function release(version, top, releaseHeading, count = 2, comment = '') {
    const rows = Array.from({ length: count }, element);
    const commentHeading = element();
    releaseHeading.querySelector = () => commentHeading;
    return { rows, commentHeading, getAttribute: () => comment, querySelector: selector => selector === 'td.version' ? { textContent: version } : releaseHeading, querySelectorAll: () => rows, getBoundingClientRect: () => ({ top }) };
}
const thirdHeading = element();
const fourthHeading = element();
const releases = [release('1.01', 550, heading, 2, 'Release <details>\nSecond line'), release('1.00', 1200, secondHeading), release('0.99', 1600, thirdHeading, 1), release('0.98', 1800, fourthHeading)];
const table = { tBodies: [{ rows: releases }], querySelectorAll: () => heading.children, getBoundingClientRect: () => ({ left: 0 }) };
let fixedHeader;
const surface = { scrollWidth: 1580, clientWidth: 900, scrollLeft: 0, addEventListener() {}, querySelector: () => table, getBoundingClientRect: () => ({ left: 24, width: 900 }), parentNode: { insertBefore: header => { fixedHeader = header; } } };
const elements = { 'table-scroll': surface, 'bottom-scroll': { clientWidth: 900, scrollLeft: 0, addEventListener() {} }, 'scroll-width': { style: {} } };
const document = { body: { style: {} }, querySelector: () => ({ offsetHeight: 93 }), querySelectorAll: selector => selector === '.commits tbody .message' ? [cell] : headings, getElementById: name => elements[name], createElement: element };
const scrolls = [];
vm.runInNewContext(script, { document, window: { addEventListener() {}, scrollBy: value => scrolls.push(value) } });
const lines = cell.textContent.split('\n');
if (lines.some(line => Array.from(line).length > 120) || lines.length !== 4 || !lines[0].endsWith('\u2026') || !lines[1].startsWith('\u2026') || !lines[1].endsWith('\u2026') || !lines[2].startsWith('\u2026') || lines[3] !== 'short' || lines.slice(0, 3).map((line, index) => line.slice(index ? 1 : 0, index === 2 ? undefined : -1)).join('') !== 'x'.repeat(300)) process.exit(1);
if (!fixedHeader || fixedHeader.style.top !== '93px' || document.body.style.paddingTop !== '169px' || fixedHeader.children[0].children.length !== 2 || fixedHeader.children[0].children[0].children.map(item => item.textContent).join('|') !== 'Version|Changes' || fixedHeader.children[0].children[1].children.map(item => item.textContent).join('|') !== '||Version|Timestamp|Commit Message|Commit ID' || headings.some(heading => heading.textContent)) process.exit(1);
if (releases[0].commentHeading.textContent !== 'Release <details>\nSecond line' || releases[1].commentHeading.textContent !== '') process.exit(1);
const firstUp = releases[0].rows[0].children[0].children[0];
const firstDown = releases[0].rows[1].children[0].children[0];
const singleUp = releases[2].rows[0].children[0].children[0];
const oldestDown = releases[3].rows[1].children[0].children[0];
if (firstUp.textContent !== '\u2191' || firstDown.textContent !== '\u2193' || firstDown.disabled || singleUp.textContent !== '\u2191' || singleUp.disabled || !oldestDown.disabled || releases.some(release => release.rows.some(row => row.children[1].textContent !== release.querySelector('td.version').textContent))) process.exit(1);
firstUp.click();
firstDown.click();
if (scrolls.length !== 2 || scrolls[0].top !== 381 || scrolls[1].top !== 1031) process.exit(1);
'@
        & $node.Source -e $checkWrapping $releasePath
    if ($LASTEXITCODE -ne 0) { throw 'Generated HTML did not render the header or wrap long messages correctly.' }
    }

    Add-TestCommit $directory 'Third commit'
    $secondHead = (& git -C $directory rev-parse HEAD).Trim()
    $version = 'Preview "A" & <B> / 2'
    $releaseComment = 'Preview release & <details>'
    & $script $version $releaseComment
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    Assert-True ($list.SelectNodes($root).Count -eq 2) 'Second release missing.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[1]").InnerText -ceq $version) 'Version did not round-trip.'
    Assert-True ($list.SelectSingleNode("$root[1]").GetAttribute('data-release-comment') -ceq $releaseComment) 'Second release comment was not saved.'
    Assert-True ($list.SelectNodes("$root[1]/td[2]/table/tbody/tr").Count -eq 1) 'Second release included the wrong commits.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[2]/table/tbody/tr[1]/td[3]").InnerText -ceq $secondHead) 'Second release has the wrong boundary.'
    Assert-True ((Get-Content -LiteralPath $versionPath -Raw).Trim() -ceq $version) 'Version file has the wrong contents.'

    Add-TestCommit $directory 'Fourth commit'
    $fourthHead = (& git -C $directory rev-parse HEAD).Trim()
    Add-TestCommit $directory 'Fifth commit'
    $fifthHead = (& git -C $directory rev-parse HEAD).Trim()
    & $script $version
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    Assert-True ($list.SelectNodes($root).Count -eq 2) 'Extending a version created a duplicate release.'
    $extendedIds = @($list.SelectNodes("$root[1]/td[2]/table/tbody/tr/td[3]") | ForEach-Object { $_.InnerText })
    Assert-True (($extendedIds -join ',') -ceq (@($fifthHead, $fourthHead, $secondHead) -join ',')) 'New commits were not prepended in order or existing commits changed.'
    Assert-True ($list.SelectSingleNode("$root[1]").GetAttribute('data-release-comment') -ceq $releaseComment) 'Extending without a comment did not preserve the previous comment.'

    & $script '1.01' 'Older release comment'
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    Assert-True ($list.SelectSingleNode("$root[1]/td[1]").InnerText -ceq $version -and $list.SelectSingleNode("$root[2]").GetAttribute('data-release-comment') -ceq 'Older release comment') 'Comment-only update reordered releases or did not update the older release.'
    Assert-True ((Get-Content -LiteralPath $versionPath -Raw).Trim() -ceq $version) 'Comment-only update changed the active version.'

    Add-TestCommit $directory 'Sixth commit'
    $sixthHead = (& git -C $directory rev-parse HEAD).Trim()
    & $script '1.01'
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    Assert-True ($list.SelectNodes($root).Count -eq 2) 'Extending an older version created a duplicate release.'
    Assert-True ($list.SelectSingleNode("$root[1]/td[1]").InnerText -ceq '1.01') 'Extended older version did not move to the top.'
    $olderIds = @($list.SelectNodes("$root[1]/td[2]/table/tbody/tr/td[3]") | ForEach-Object { $_.InnerText })
    Assert-True ($olderIds.Count -eq 3 -and $olderIds[0] -ceq $sixthHead -and $olderIds[1] -ceq $firstHead) 'Older version did not retain its commits.'
    Assert-True ($list.SelectSingleNode("$root[1]").GetAttribute('data-release-comment') -ceq 'Older release comment') 'Extending an older version lost its comment.'
    Assert-True ($list.SelectSingleNode("$root[2]/td[1]").InnerText -ceq $version) 'Another release changed when extending an older version.'
    Assert-True ((Get-Content -LiteralPath $versionPath -Raw).Trim() -ceq '1.01') 'Version file was not updated when extending an older version.'

    Add-TestCommit $directory 'Seventh commit'
    $seventhHead = (& git -C $directory rev-parse HEAD).Trim()
    $version = 'next'
    & $script $version
    [xml]$list = Get-Content -LiteralPath $releasePath -Raw
    $newIds = @($list.SelectNodes("$root[1]/td[2]/table/tbody/tr/td[3]") | ForEach-Object { $_.InnerText })
    Assert-True ($newIds.Count -eq 1 -and $newIds[0] -ceq $seventhHead) 'The next release reused commits from an extended release.'

    $before = [System.IO.File]::ReadAllText($releasePath)
    foreach ($invalidVersion in @('another', '1.01', 'next')) {
        $failed = $false
        try { & $script $invalidVersion } catch { $failed = $true }
        Assert-True $failed 'A release with no new commits was accepted.'
        Assert-True ([System.IO.File]::ReadAllText($releasePath) -ceq $before) 'Failed release changed the list.'
        Assert-True ((Get-Content -LiteralPath $versionPath -Raw).Trim() -ceq $version) 'Failed release changed the version.'
    }

    & git -C $directory checkout --orphan unrelated -q
    Add-TestCommit $directory 'Unrelated history'
    $failed = $false
    try { & $script 'unrelated' } catch { $failed = $true }
    Assert-True $failed 'A release with an unrelated previous commit was accepted.'
    Assert-True ([System.IO.File]::ReadAllText($releasePath) -ceq $before) 'Unrelated history changed the list.'
    Write-Host 'Release tests passed.'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}