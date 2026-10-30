param(
    [string]$PdsRoot = 'C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $projectRoot 'rv32I.pds'
$running = Get-CimInstance Win32_Process -Filter "Name='pds_shell.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.Replace('\', '/').Contains($projectPath.Replace('\', '/'))
}
if ($running) {
    throw "A PDS flow for this project is already running (PID: $($running.ProcessId -join ', ')). Stop it before starting another build."
}
if (-not (Select-String -LiteralPath $projectPath -SimpleMatch 'board/acore_video_platform.v' -Quiet)) {
    throw 'This build requires the HDMI/PCIe/shared DDR root project.'
}
$outputDirectory = Join-Path $projectRoot 'build\video-platform'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
if (-not $env:PANGO_LICENSE_FILE) {
    $env:PANGO_LICENSE_FILE = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name PANGO_LICENSE_FILE).PANGO_LICENSE_FILE
}
$started = Get-Date
$consoleLog = Join-Path $outputDirectory 'pds_console.log'
Push-Location -LiteralPath $projectRoot
try {
    # Intentionally run the root PDS's full flow. Do not use legacy exporters,
    # regenerate CPU memory IPs, or replace the maintained project with a stub.
    & "$PdsRoot\bin\pds_shell.exe" -project $projectPath *> $consoleLog
    $pdsExit = $LASTEXITCODE
    $errors = Select-String -LiteralPath $consoleLog -Pattern '^E:'
    if ($pdsExit -ne 0 -or $errors) {
        Get-Content -LiteralPath $consoleLog -Tail 24
        throw "PDS failed; see $consoleLog"
    }
    $bitstream = Join-Path $projectRoot 'generate_bitstream\acore_dual_top.sbit'
    if (-not (Test-Path -LiteralPath $bitstream)) { throw 'PDS did not generate the expected bitstream.' }
    if ((Get-Item -LiteralPath $bitstream).LastWriteTime -lt $started) {
        throw 'Only an older bitstream exists; this build is not verified.'
    }
    $finalTiming = Join-Path $projectRoot 'place_route\acore_dual_top.rtr'
    if (-not (Select-String -LiteralPath $finalTiming -SimpleMatch 'Design Summary : All Constraints Met.' -Quiet) -or
        (Select-String -LiteralPath $finalTiming -SimpleMatch 'Slack (VIOLATED)' -Quiet)) {
        throw "A bitstream was generated, but final post-route timing failed; see $finalTiming"
    }
    Write-Output "BITSTREAM_READY $bitstream"
    Write-Output 'Read place_route/acore_dual_top.prr and acore_dual_top.rtr for resources/timing; bitstream generation alone does not prove timing closure.'
}
finally { Pop-Location }
