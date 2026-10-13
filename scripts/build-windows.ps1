param([string]$Configuration = "Release", [switch]$SkipTests, [string]$Generator = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    function Run([scriptblock]$Command) { & $Command; if ($LASTEXITCODE -ne 0) { throw "Build step failed with exit code $LASTEXITCODE" } }
    # Do not inherit CMAKE_GENERATOR from a Developer PowerShell terminal: NMake
    # cannot accept -A x64 or produce the configuration folders used below.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        $vswhereCommand = Get-Command vswhere.exe -ErrorAction SilentlyContinue
        if (-not $vswhereCommand) { throw "Visual Studio Installer was not found. Install Visual Studio Build Tools with Desktop development with C++ and a Windows SDK." }
        $vswhere = $vswhereCommand.Source
    }
    $vsJson = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json
    if ($LASTEXITCODE -ne 0) { throw "Visual Studio toolchain discovery failed with exit code $LASTEXITCODE." }
    $installations = @((($vsJson -join "`n") | ConvertFrom-Json) | Sort-Object { [version]$_.installationVersion } -Descending)
    if ($installations.Count -eq 0) { throw "No Visual Studio C++ toolchain was found. In Visual Studio Installer, add Desktop development with C++ and a Windows SDK." }
    $cmakeJson = & cmake -E capabilities
    if ($LASTEXITCODE -ne 0) { throw "Could not read CMake's supported generators. Install CMake 3.24 or newer (4.2 or newer for Visual Studio 2026)." }
    $generators = (($cmakeJson -join "`n") | ConvertFrom-Json).generators
    $visualStudio = $null
    foreach ($installation in $installations) {
        $major = ([version]$installation.installationVersion).Major
        $match = $generators | Where-Object { $_.name -match "^Visual Studio $major " -and (!$Generator -or $_.name -eq $Generator) } | Select-Object -First 1
        if ($match) {
            $visualStudio = $installation
            $Generator = $match.name
            break
        }
    }
    if (-not $visualStudio) { throw "No installed Visual Studio C++ toolchain matches this CMake's supported generators or the requested -Generator '$Generator'. Update CMake (Visual Studio 2026 requires CMake 4.2 or newer), or select an installed version such as -Generator 'Visual Studio 17 2022'." }
    # Keep failed NMake caches and other Visual Studio versions separate. Never
    # remove a user's existing build directory to change generators.
    $native = "build/windows-native-vs$(([version]$visualStudio.installationVersion).Major)-x64"
    $publish = "build/windows-release/MixingDesk-win-x64"
    Write-Host "Native toolchain: $Generator (x64)"
    Write-Host "Native build folder: $native"
    Run { cmake -S . -B $native -G $Generator -A x64 "-DCMAKE_GENERATOR_INSTANCE=$($visualStudio.installationPath)" }
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
