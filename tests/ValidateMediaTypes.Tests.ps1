$ErrorActionPreference = 'Stop'
$validator = Join-Path (Split-Path $PSScriptRoot -Parent) 'ValidateMediaTypes.ps1'
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("media-types-test-{0}.json" -f [guid]::NewGuid())

try {
    $cases = @(
        @{ Name = 'valid'; Json = '{"types":[{"type":"book","extensions":{"render":[".PDF"],"edit":[".doc"]},"comment":"test"},{"type":"box","extensions":[".zip"]}]}'; Success = $true },
        @{ Name = 'repeated assignment'; Json = '{"types":[{"type":"book","extensions":{"render":[".pdf",".PDF"]}}]}'; Success = $true },
        @{ Name = 'conflicting types'; Json = '{"types":[{"type":"book","extensions":[".pdf"]},{"type":"image","extensions":[".PDF"]}]}'; Success = $false; Message = 'conflicting assignments' },
        @{ Name = 'conflicting subtypes'; Json = '{"types":[{"type":"book","extensions":{"render":[".pdf"],"edit":[".PDF"]}}]}'; Success = $false; Message = 'conflicting assignments' },
        @{ Name = 'invalid JSON'; Json = '{"types":['; Success = $false; Message = 'Media type validation failed' },
        @{ Name = 'trailing comma'; Json = '{"types":[],}'; Success = $false; Message = 'Media type validation failed' },
        @{ Name = 'invalid extensions'; Json = '{"types":[{"type":"book","extensions":{"render":["pdf"]}}]}'; Success = $false; Message = 'Invalid extension' }
    )

    foreach ($case in $cases) {
        [System.IO.File]::WriteAllText($fixture, $case.Json)
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -Path $fixture 2>&1 | Out-String
        $success = $LASTEXITCODE -eq 0
        if ($success -ne $case.Success -or (-not $success -and $output -notlike "*$($case.Message)*")) {
            throw "Case '$($case.Name)' failed. Exit code: $LASTEXITCODE. Output: $output"
        }
    }
    Write-Output 'Media type validation tests passed.'
} finally {
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
}