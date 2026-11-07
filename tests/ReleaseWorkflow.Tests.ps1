$ErrorActionPreference = 'Stop'

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-release-workflow-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & git -C $directory init -q
    & git -C $directory config user.name 'Release Test'
    & git -C $directory config user.email 'release-test@example.com'
    & git -C $directory config commit.gpgsign false
    & git -C $directory config tag.gpgsign false
    Copy-Item (Join-Path $PSScriptRoot '..\release.ps1'), (Join-Path $PSScriptRoot '..\create_release_notes.ps1') $directory
    New-Item -ItemType Directory -Path (Join-Path $directory 'installer-config'), (Join-Path $directory 'bin\Debug\net10.0-windows'), (Join-Path $directory 'bin\Release\net10.0-dependent') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'SUTWinExplorer.csproj'), 'fixture')
    [System.IO.File]::WriteAllText((Join-Path $directory 'ReleaseDescription.txt'), "1.00`nOld release`n")
    [System.IO.File]::WriteAllText((Join-Path $directory 'bin\Debug\net10.0-windows\app.dll'), 'old debug')
    [System.IO.File]::WriteAllText((Join-Path $directory 'bin\Release\net10.0-dependent\app.exe'), 'old release')
    $installerStub = @'
if ($global:releaseTestFailInstaller) { throw 'Simulated installer failure.' }
$output = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Release\net10.0-dependent\app.exe'
[System.IO.File]::WriteAllText($output, 'new release')
'@
    [System.IO.File]::WriteAllText((Join-Path $directory 'installer-config\build-installer.ps1'), $installerStub)
    & git -C $directory add --all
    & git -C $directory commit -q -m 'Initial fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the test fixture.' }
    $initialHead = (& git -C $directory rev-parse HEAD).Trim()
    $script = Join-Path $directory 'release.ps1'
    $descriptionPath = Join-Path $directory 'ReleaseDescription.txt'
    $global:releaseTestFailBuild = $false
    $global:releaseTestFailInstaller = $false
    $global:releaseTestConfirmation = 'yes'
    function Read-Host {
        param([string]$Prompt)
        return $global:releaseTestConfirmation
    }
    function dotnet {
        if ($global:releaseTestFailBuild) { $global:LASTEXITCODE = 1; return }
        [System.IO.File]::WriteAllText((Join-Path $directory 'bin\Debug\net10.0-windows\app.dll'), 'new debug')
        $global:LASTEXITCODE = 0
    }

    foreach ($answer in @('', 'n', 'y', 'Yes', ' yes ', 'unexpected')) {
        $global:releaseTestConfirmation = $answer
        $failed = $false
        try { & $script } catch { $failed = $_.Exception.Message -match 'not confirmed' }
        Assert-True $failed 'A release without explicit confirmation was accepted.'
        Assert-True ((& git -C $directory rev-parse HEAD).Trim() -ceq $initialHead) 'A declined release changed HEAD.'
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $directory 'bin\Debug\net10.0-windows\app.dll')) -ceq 'old debug') 'A declined release started the build.'
    }
    $global:releaseTestConfirmation = 'yes'
    $failed = $false
    try { & $script } catch { $failed = $true }
    Assert-True $failed 'A clean workspace was accepted without a modified version file.'
    [System.IO.File]::WriteAllText($descriptionPath, "2.02`nFirst line`nSecond line`n")
    [System.IO.File]::WriteAllText((Join-Path $directory 'unrelated.txt'), 'unrelated')
    $failed = $false
    try { & $script } catch { $failed = $true }
    Assert-True $failed 'An unrelated untracked file was accepted.'
    Assert-True ((& git -C $directory rev-parse HEAD).Trim() -ceq $initialHead) 'Preflight changed HEAD.'
    Remove-Item -LiteralPath (Join-Path $directory 'unrelated.txt')
    [System.IO.File]::WriteAllText((Join-Path $directory 'SUTWinExplorer.csproj'), 'changed')
    & git -C $directory add -- SUTWinExplorer.csproj
    $failed = $false
    try { & $script } catch { $failed = $true }
    Assert-True $failed 'An unrelated staged file was accepted.'
    & git -C $directory restore --staged --worktree -- SUTWinExplorer.csproj

    [System.IO.File]::WriteAllText($descriptionPath, "bad version`nComment`n")
    $failed = $false
    try { & $script } catch { $failed = $true }
    Assert-True $failed 'An invalid Git tag was accepted.'
    [System.IO.File]::WriteAllText($descriptionPath, "2.02`nFirst line`nSecond line`n")
    & git -C $directory tag v2.02
    $failed = $false
    try { & $script } catch { $failed = $true }
    Assert-True $failed 'An existing Git tag was accepted.'
    & git -C $directory tag -d v2.02 | Out-Null

    $global:releaseTestFailBuild = $true
    $failed = $false
    try { & $script } catch { $failed = $_.Exception.Message -match 'Debug build' }
    Assert-True $failed 'A failing Debug build did not stop the release.'
    Assert-True ((& git -C $directory rev-parse HEAD).Trim() -ceq $initialHead) 'A failing build created a commit.'
    $global:releaseTestFailBuild = $false
    $global:releaseTestFailInstaller = $true
    $failed = $false
    try { & $script } catch { $failed = $_.Exception.Message -match 'installer builds' }
    Assert-True $failed 'A failing installer build did not stop the release.'
    Assert-True ((& git -C $directory rev-parse HEAD).Trim() -ceq $initialHead) 'A failing installer build created a commit.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $directory 'bin\Debug\net10.0-windows\app.dll')) -ceq 'new debug') 'A failed release unexpectedly reverted a build output.'
    [System.IO.File]::WriteAllText((Join-Path $directory 'bin\Debug\net10.0-windows\app.dll'), 'old debug')
    $global:releaseTestFailInstaller = $false

    & git -C $directory add -- ReleaseDescription.txt
    & $script
    $messages = @(& git -C $directory log -3 --format=%s)
    Assert-True (($messages -join '|') -ceq 'Include release list commit for 2.02|Update release list for 2.02|Release 2.02') 'Release commits have unexpected subjects or order.'
    $body = (& git -C $directory log -1 --format=%B HEAD~2 | Out-String).Trim()
    Assert-True ($body -match '(?s)^Release 2\.02\s+First line\s+Second line$') 'The release commit did not include the full description.'
    $commitFiles = @(& git -C $directory diff-tree --no-commit-id --name-only -r HEAD~2)
    Assert-True ($commitFiles.Count -eq 3 -and 'ReleaseDescription.txt' -in $commitFiles -and 'bin/Debug/net10.0-windows/app.dll' -in $commitFiles -and 'bin/Release/net10.0-dependent/app.exe' -in $commitFiles) 'The release commit did not include the version and tracked build outputs.'
    $taggedCommit = (& git -C $directory rev-parse 'v2.02^{}').Trim()
    Assert-True ($taggedCommit -ceq (& git -C $directory rev-parse HEAD).Trim()) 'The tag does not point to the final release-list commit.'
    Assert-True ((& git -C $directory cat-file -t v2.02).Trim() -ceq 'tag') 'The release tag is not annotated.'
    $tagMessage = (& git -C $directory for-each-ref '--format=%(contents)' refs/tags/v2.02 | Out-String).Trim()
    Assert-True ($tagMessage -match '(?s)^Release 2\.02\s+First line\s+Second line$') 'The annotated tag does not contain the release description.'
    [xml]$list = Get-Content -LiteralPath (Join-Path $directory 'RELEASES.html') -Raw
    $release = $list.SelectSingleNode('/html/body/main/div/table/tbody/tr[1]')
    $firstListCommit = (& git -C $directory rev-parse HEAD~1).Trim()
    Assert-True ($release.SelectSingleNode('./td[1]').InnerText -ceq '2.02' -and $release.SelectSingleNode('./td[2]/table/tbody/tr[1]/td[3]').InnerText -ceq $firstListCommit) 'The final list does not contain the first release-list commit.'
    Assert-True (@(& git -C $directory status --porcelain=v1 --untracked-files=all).Count -eq 0) 'The successful release left uncommitted changes.'
    Write-Host 'Release workflow tests passed.'
} finally {
    Remove-Variable -Name releaseTestFailBuild -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name releaseTestFailInstaller -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name releaseTestConfirmation -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $directory -Recurse -Force
}