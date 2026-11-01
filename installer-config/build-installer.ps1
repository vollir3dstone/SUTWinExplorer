[CmdletBinding()]
param(
    [string[]]$ProfileId,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "installer.json")
)

$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$projectPath = Join-Path $repositoryRoot "SUTWinExplorer.csproj"
$issPath = Join-Path $PSScriptRoot "installer.iss"
$installerRoot = Join-Path $repositoryRoot "installer"
$outputDirectory = Join-Path $installerRoot "Release"
$temporaryDirectory = Join-Path $installerRoot "Temp"
$executableName = "KIS Explorer.exe"

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
if ($config._type -ne "installer_profiles") {
    throw "The configuration _type must be 'installer_profiles'."
}

foreach ($requiredProperty in @("appName", "appVersion", "publisher", "profiles")) {
    if (-not $config.PSObject.Properties[$requiredProperty]) {
        throw "Missing required configuration property '$requiredProperty'."
    }
}

$profiles = @($config.profiles)
if ($ProfileId.Count -gt 0) {
    $unknownProfileIds = @($ProfileId | Where-Object { $_ -notin $profiles.profileId })
    if ($unknownProfileIds.Count -gt 0) {
        throw "Unknown profile ID(s): $($unknownProfileIds -join ', ')"
    }

    $profiles = @($profiles | Where-Object { $_.profileId -in $ProfileId })
}

$publishDirectories = @{
    Included  = Join-Path $repositoryRoot "bin\Release\net10.0-included"
    Dependent = Join-Path $repositoryRoot "bin\Release\net10.0-dependent"
}

$compilerCommand = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
$compilerPath = if ($compilerCommand) { $compilerCommand.Source } else { $null }
if (-not $compilerPath) {
    $compilerCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    )
    $compilerPath = $compilerCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $compilerPath) {
    throw "ISCC.exe was not found. Add Inno Setup to PATH or install Inno Setup 6."
}

New-Item -ItemType Directory -Path $outputDirectory, $temporaryDirectory -Force | Out-Null

foreach ($profile in $profiles) {
    if ($profile._type -ne "profile" -or -not $profile.profileId -or -not $profile.configuration) {
        throw "Each profile must have _type 'profile', a profileId, and a configuration object."
    }

    $publishProfile = [string]$profile.configuration.publishProfile
    if (-not $publishDirectories.ContainsKey($publishProfile)) {
        throw "Profile '$($profile.profileId)' has unsupported publishProfile '$publishProfile'."
    }

    $publishDirectory = $publishDirectories[$publishProfile]
    $executablePath = Join-Path $publishDirectory $executableName
    $runningProcesses = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($executableName)) -ErrorAction SilentlyContinue | Where-Object {
        try {
            [string]::Equals($_.Path, $executablePath, [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
    }
    if ($runningProcesses) {
        $processIds = ($runningProcesses | ForEach-Object { $_.Id }) -join ", "
        throw "Close $executableName from '$publishDirectory' before building (process ID(s): $processIds)."
    }

    Write-Host "Publishing profile '$($profile.profileId)' using '$publishProfile'..."
    & dotnet publish $projectPath "-p:PublishProfile=$publishProfile"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for profile '$($profile.profileId)' with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path $executablePath)) {
        throw "Expected publish output was not found: $executablePath"
    }

    $generatedScriptPath = Join-Path $temporaryDirectory "$($profile.profileId).iss"
    $definitions = @(
        "#define AppName `"$($config.appName)`""
        "#define AppVersion `"$($config.appVersion)`""
        "#define AppPublisher `"$($config.publisher)`""
        "#define AppExeName `"$executableName`""
        "#define ProfileId `"$($profile.profileId)`""
        "#define PublishDir `"$publishDirectory`""
        "#define InstallerOutputDir `"$outputDirectory`""
        "#define AddFolderContextMenu $(([bool]$profile.configuration.addFolderContextMenu).ToString().ToLowerInvariant())"
    )
    $templateContent = Get-Content -Raw -Path $issPath
    Set-Content -Path $generatedScriptPath -Value (($definitions -join "`r`n") + "`r`n" + $templateContent) -Encoding utf8

    $previousTemp = $env:TEMP
    $previousTmp = $env:TMP
    try {
        $env:TEMP = $temporaryDirectory
        $env:TMP = $temporaryDirectory
        Write-Host "Compiling installer for '$($profile.profileId)'..."
        & $compilerPath $generatedScriptPath
        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup failed for profile '$($profile.profileId)' with exit code $LASTEXITCODE."
        }
    }
    finally {
        $env:TEMP = $previousTemp
        $env:TMP = $previousTmp
    }
}