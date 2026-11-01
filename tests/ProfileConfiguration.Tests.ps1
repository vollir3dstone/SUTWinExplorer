$ErrorActionPreference = 'Stop'

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Invoke-Store($store, [string] $method, [object[]] $arguments = @()) {
    return $store.GetType().GetMethod($method).Invoke($store, $arguments)
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
$storeType = $assembly.GetType('SUTWinExplorer.ProfileStore', $true)
$entryType = $assembly.GetType('SUTWinExplorer.ProfilePathview', $true)
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-profile-test-' + [guid]::NewGuid().ToString('N'))
$filePath = Join-Path $directory "Profile $([char]0x201e)default$([char]0x201c).kisexplorer.json"

try {
    $constructor = $storeType.GetConstructor([type[]] @([string], [string]))
    $store = $constructor.Invoke([object[]] @([string] $directory, 'default'))
    $profile = Invoke-Store $store 'LoadOrCreate'
    Assert-True (Test-Path -LiteralPath $filePath) 'Default profile file was not created.'
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json._type -eq 'KIS Explorer profile' -and $json.ProfileName -eq 'default' -and $json.Pathviews.Count -eq 0) 'Invalid default profile.'

    $entry = [Activator]::CreateInstance($entryType, $true)
    $entry.Type = 'Pathview'
    $entryType.GetProperty('Name').SetValue($entry, $null)
    $entry.Path = Join-Path $directory 'first'
    $entry.ActionOnProfileActivation = 'open'
    $profile.Pathviews.Add($entry)
    Invoke-Store $store 'Save' @($profile)
    $profile = Invoke-Store $store 'LoadOrCreate'
    Assert-True ($profile.Pathviews.Count -eq 1 -and $null -eq $profile.Pathviews[0].Name) 'Pathview did not round-trip with a null name.'

    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json.Pathviews[0].ContainsKey('TabColor') -and $null -eq $json.Pathviews[0].TabColor) 'Default TabColor was not saved as null.'
    $json.Pathviews[0].Remove('TabColor')
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $profile = Invoke-Store $store 'Load'
    Assert-True ($null -eq $profile.Pathviews[0].TabColor) 'A legacy Pathview without TabColor did not load.'
    $profile.Pathviews[0].TabColor = '#FF85ADE9'
    Invoke-Store $store 'Save' @($profile)
    $profile = Invoke-Store $store 'Load'
    Assert-True ($profile.Pathviews[0].TabColor -ceq '#FF85ADE9') 'Pathview color did not round-trip.'
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    $json.Pathviews[0].TabColor = '#invalid'
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $before = [System.IO.File]::ReadAllText($filePath)
    $failed = $false
    try { Invoke-Store $store 'Load' } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($filePath) -ceq $before) 'Invalid TabColor was accepted or overwritten.'
    Invoke-Store $store 'Save' @($profile)

    $profile.Pathviews[0].Name = 'Custom name'
    Invoke-Store $store 'Save' @($profile)
    $profile = Invoke-Store $store 'Load'
    Assert-True ($profile.Pathviews[0].Name -eq 'Custom name') 'Custom Pathview name did not round-trip.'
    $entryType.GetProperty('Name').SetValue($profile.Pathviews[0], $null)
    Invoke-Store $store 'Save' @($profile)
    $profile = Invoke-Store $store 'Load'
    Assert-True ($null -eq $profile.Pathviews[0].Name) 'Cleared Pathview name did not round-trip as null.'

    $profile.Pathviews[0].Path = Join-Path $directory 'renamed'
    Invoke-Store $store 'Save' @($profile)
    Assert-True ((Invoke-Store $store 'LoadOrCreate').Pathviews[0].Path -eq (Join-Path $directory 'renamed')) 'Renamed path was not saved.'

    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    $json['FutureSetting'] = @{ value = 42 }
    $json.Pathviews[0]['FuturePathviewSetting'] = 'kept'
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $profile = Invoke-Store $store 'LoadOrCreate'
    Invoke-Store $store 'Save' @($profile)
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($json.FutureSetting.value -eq 42 -and $json.Pathviews[0].FuturePathviewSetting -eq 'kept') 'Unknown properties were lost.'

    $locked = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $failed = $false
        try { Invoke-Store $store 'Save' @($profile) } catch { $failed = $true }
        Assert-True $failed 'A locked profile unexpectedly saved.'
    } finally { $locked.Dispose() }
    Assert-True ((Invoke-Store $store 'LoadOrCreate').Pathviews.Count -eq 1) 'Save failure damaged the previous profile.'

    $profile.Pathviews.Clear()
    Invoke-Store $store 'Save' @($profile)
    Assert-True ((Invoke-Store $store 'LoadOrCreate').Pathviews.Count -eq 0) 'Removed Pathview returned.'

    $otherStore = $constructor.Invoke([object[]] @([string] $directory, 'other'))
    $otherProfile = Invoke-Store $otherStore 'LoadOrCreate'
    Assert-True ($otherProfile.ProfileName -eq 'other' -and (Test-Path -LiteralPath (Join-Path $directory "Profile $([char]0x201e)other$([char]0x201c).kisexplorer.json"))) 'A second profile could not be stored independently.'
    $otherPath = Join-Path $directory "Profile $([char]0x201e)other$([char]0x201c).kisexplorer.json"
    $otherJson = Get-Content -LiteralPath $otherPath -Raw | ConvertFrom-Json -AsHashtable
    $otherJson.FutureSetting = @{ value = 42 }
    $otherJson.Pathviews = @($json.Pathviews[0])
    $otherJson | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $otherPath -Encoding utf8
    $otherProfile = Invoke-Store $otherStore 'Load'
    $beforeOther = [System.IO.File]::ReadAllText($otherPath)
    $failed = $false
    try { Invoke-Store $otherStore 'Create' @($otherProfile) } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($otherPath) -ceq $beforeOther) 'Creating an existing profile overwrote it.'
    $names = @(Invoke-Store $store 'GetProfileNames')
    Assert-True ($names.Count -eq 2 -and 'default' -in $names -and 'other' -in $names) 'Profile discovery did not return both profile names.'
    $missingStore = Invoke-Store $store 'ForProfile' @('missing')
    $failed = $false
    try { Invoke-Store $missingStore 'Load' } catch { $failed = $true }
    Assert-True ($failed -and @(Invoke-Store $store 'GetProfileNames').Count -eq 2) 'Loading a missing profile unexpectedly created it.'

    $failed = $false
    try { Invoke-Store $store 'Delete' } catch { $failed = $true }
    Assert-True ($failed -and (Test-Path -LiteralPath $filePath)) 'The default profile could be deleted.'
    $failed = $false
    try { Invoke-Store $store 'Rename' @($profile, 'renamed-default') } catch { $failed = $true }
    Assert-True ($failed -and (Test-Path -LiteralPath $filePath)) 'The default profile could be renamed.'

    $failed = $false
    try { Invoke-Store $otherStore 'Rename' @($otherProfile, 'default') } catch { $failed = $true }
    Assert-True ($failed -and $otherProfile.ProfileName -eq 'other' -and (Test-Path -LiteralPath $filePath)) 'Renaming overwrote an existing profile.'
    $failed = $false
    try { Invoke-Store $otherStore 'Rename' @($otherProfile, 'new') } catch { $failed = $true }
    Assert-True ($failed -and $otherProfile.ProfileName -eq 'other') 'The reserved name was accepted.'

    $otherStore = Invoke-Store $otherStore 'Rename' @($otherProfile, 'renamed')
    Assert-True ($otherProfile.ProfileName -eq 'renamed' -and (Invoke-Store $otherStore 'Load').ProfileName -eq 'renamed') 'Profile rename did not update the filename and JSON name.'
    $renamedPath = Join-Path $directory "Profile $([char]0x201e)renamed$([char]0x201c).kisexplorer.json"
    $renamedJson = Get-Content -LiteralPath $renamedPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($renamedJson.FutureSetting.value -eq 42 -and $renamedJson.Pathviews[0].FuturePathviewSetting -eq 'kept') 'Profile rename lost Pathviews or unknown properties.'
    $otherStore = Invoke-Store $otherStore 'Rename' @($otherProfile, 'RENAMED')
    Assert-True ($otherProfile.ProfileName -eq 'RENAMED' -and (Invoke-Store $otherStore 'Load').ProfileName -eq 'RENAMED') 'Case-only profile rename failed.'
    Invoke-Store $otherStore 'Delete'
    Assert-True (@(Invoke-Store $store 'GetProfileNames').Count -eq 1) 'Deleted profile remains in discovery.'

    $savedPath = $json.Pathviews[0].Path
    $json.Pathviews[0].Path = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $failed = $false
    try { Invoke-Store $store 'LoadOrCreate' } catch { $failed = $true }
    Assert-True $failed 'A virtual This PC location was accepted as a filesystem path.'
    $json.Pathviews[0].Path = $savedPath

    $json.Pathviews += $json.Pathviews[0]
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8
    $before = [System.IO.File]::ReadAllText($filePath)
    $failed = $false
    try { Invoke-Store $store 'LoadOrCreate' } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($filePath) -ceq $before) 'Duplicate paths were accepted or overwritten.'

    [System.IO.File]::WriteAllText($filePath, '{invalid json')
    $failed = $false
    try { Invoke-Store $store 'LoadOrCreate' } catch { $failed = $true }
    Assert-True ($failed -and [System.IO.File]::ReadAllText($filePath) -ceq '{invalid json') 'Malformed profile was accepted or overwritten.'
    Write-Output 'Profile configuration tests passed.'
} finally {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}