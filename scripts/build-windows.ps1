param([string]$Configuration = "Release", [switch]$SkipTests)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    function Run([scriptblock]$Command) { & $Command; if ($LASTEXITCODE -ne 0) { throw "Build step failed with exit code $LASTEXITCODE" } }
    $native = "build/windows-native"
    $publish = "build/windows-release/MixingDesk-win-x64"
    Run { cmake -S . -B $native -A x64 }
    Run { cmake --build $native --config $Configuration --parallel }
    if (-not $SkipTests) {
        Run { ctest --test-dir $native -C $Configuration --output-on-failure }
        Run { dotnet run --project Windows/Tests/DeskModelTests.csproj -c $Configuration }
    }
    Run { dotnet publish Windows/App/MixingDesk.csproj -c $Configuration -r win-x64 --self-contained true -o $publish }
    Copy-Item "$native/$Configuration/DeskWindows.dll", "$native/$Configuration/DeskPluginScanner.exe" $publish
    New-Item -ItemType Directory -Force "$publish/Licenses" | Out-Null
    Copy-Item LICENSE "$publish/Licenses/MixingDesk.txt"
    Copy-Item Sources/DeskAudio/VST3SDK/pluginterfaces/LICENSE.txt "$publish/Licenses/Steinberg.txt"
    Copy-Item "$native/_deps/json-src/LICENSE.MIT" "$publish/Licenses/nlohmann-json.txt"
    Copy-Item "$native/_deps/samplerate-src/COPYING" "$publish/Licenses/libsamplerate.txt"
    $dotnetRoot = Split-Path -Parent (Get-Command dotnet).Source
    Copy-Item "$dotnetRoot/LICENSE.txt" "$publish/Licenses/dotnet.txt"
    Copy-Item "$dotnetRoot/ThirdPartyNotices.txt" "$publish/Licenses/dotnet-third-party.txt"
    Copy-Item Windows/README.md "$publish/README-Windows.md"
    Copy-Item Windows/VALIDATION.md "$publish/VALIDATION.md"
    Copy-Item Windows/PARITY.md "$publish/PARITY.md"
    New-Item -ItemType Directory -Force "$publish/Diagnostics" | Out-Null
    foreach ($binary in @("DeskEngineTests.exe", "DeskWindowsTests.exe", "DeskVstTests.exe", "DeskVstFixture.vst3")) {
        Copy-Item "$native/$Configuration/$binary" "$publish/Diagnostics/$binary"
    }
    Copy-Item Windows/Diagnostics/Test-Native.ps1 "$publish/Diagnostics/Test-Native.ps1"
    Copy-Item Windows/Diagnostics/Test-Startup.ps1 "$publish/Diagnostics/Test-Startup.ps1"
    if (-not $SkipTests) {
        & "$publish/Diagnostics/Test-Startup.ps1"
    }
    $version = (Get-Content release/version.txt -Raw).Trim()
    $archive = "build/windows-release/MixingDesk-$version-windows-dev-x64.zip"
    Compress-Archive -Path "$publish/*" -DestinationPath $archive -Force
    Write-Host "Windows development build: $archive"
    Write-Host "Physical Windows audio and UI acceptance is required before release."
} finally { Pop-Location }
