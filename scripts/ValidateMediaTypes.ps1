param(
    [Parameter(Mandatory = $true)]
    [string] $Path
)

$ErrorActionPreference = 'Stop'

try {
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($config.types -isnot [array]) {
        throw "The 'types' property must be an array."
    }

    $assignments = @{}
    foreach ($entry in $config.types) {
        if ($entry.type -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.type)) {
            throw 'A media type name is missing or empty.'
        }

        $groups = if ($entry.extensions -is [array]) {
            @([pscustomobject]@{ Name = ''; Value = $entry.extensions })
        } elseif ($entry.extensions -is [pscustomobject]) {
            @($entry.extensions.PSObject.Properties)
        } else {
            throw "Extensions for '$($entry.type)' must be an array or an object of subtype arrays."
        }

        foreach ($group in $groups) {
            if ($group.Value -isnot [array]) {
                throw "Extensions for '$($entry.type)/$($group.Name)' must be an array."
            }
            foreach ($extension in $group.Value) {
                if ($extension -isnot [string] -or $extension.Length -le 1 -or $extension[0] -ne '.') {
                    throw "Invalid extension in '$($entry.type)/$($group.Name)'."
                }

                $assignment = "$($entry.type)/$($group.Name)"
                if ($assignments.ContainsKey($extension) -and $assignments[$extension] -ne $assignment) {
                    throw "Extension '$extension' has conflicting assignments: '$($assignments[$extension])' and '$assignment'."
                }
                $assignments[$extension] = $assignment
            }
        }
    }
} catch {
    [Console]::Error.WriteLine("Media type validation failed for '$Path': $($_.Exception.Message)")
    exit 1
}