# Run from an extracted development package; no SDK or audio driver is required.
$ErrorActionPreference = "Stop"
function Run([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Native check failed with exit code $LASTEXITCODE" }
}
$scanResult = Join-Path ([IO.Path]::GetTempPath()) ("MixingDesk-scan-" + [Guid]::NewGuid() + ".json")
try {
    Run { & "$PSScriptRoot/DeskEngineTests.exe" }
    Run { & "$PSScriptRoot/DeskWindowsTests.exe" }
    Run { & "$PSScriptRoot/DeskVstTests.exe" "$PSScriptRoot/DeskVstFixture.vst3" }
    Run { & "$PSScriptRoot/../DeskPluginScanner.exe" "$PSScriptRoot/DeskVstFixture.vst3" $scanResult }
    $catalog = Get-Content $scanResult -Raw | ConvertFrom-Json
    if (@($catalog).Count -ne 2) { throw "The fixture scanner did not return both test effects" }
    Write-Host "PASS: native engine, session/clock, VST3 lifecycle and scanner checks."
    Write-Host "Hardware audio and UI acceptance still need the checks in README-Windows.md."
} finally {
    if (Test-Path $scanResult) { Remove-Item $scanResult }
}
