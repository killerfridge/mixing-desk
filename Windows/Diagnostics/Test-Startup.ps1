# Launch the published app with a fresh session, render its window, initialize
# the native host, then quit without starting audio or loading a saved session.
param([string]$AppDirectory = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = "Stop"
$app = Join-Path $AppDirectory "MixingDesk.exe"
if (-not (Test-Path $app)) { throw "MixingDesk.exe was not found in $AppDirectory" }
$process = Start-Process -FilePath $app -ArgumentList "--smoke-test" -PassThru
$log = Join-Path $env:LOCALAPPDATA "Mixing Desk/Logs/startup-$($process.Id).log"
try {
    if (-not $process.WaitForExit(30000)) {
        throw "Desktop startup timed out after 30 seconds."
    }
    if ($process.ExitCode -ne 0) {
        throw "Desktop startup failed with exit code $($process.ExitCode)."
    }
    if (-not (Test-Path $log) -or -not (Select-String -Path $log -SimpleMatch "PASS: desktop startup" -Quiet)) {
        throw "The app exited without confirming that its window rendered and native host initialized."
    }
    Write-Host "PASS: published Windows app opened, rendered, initialized its native host and quit."
} finally {
    if (-not $process.HasExited) {
        # This is only the test process created above; other instances are untouched.
        $process.Kill()
        $process.WaitForExit()
    }
    if (Test-Path $log) { Get-Content $log | Write-Host }
    $process.Dispose()
}
