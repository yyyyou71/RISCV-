param(
    [string]$PdsRoot = 'C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1',
    [string]$Python = 'python',
    [string]$ModelsimBin = 'C:\diskE\modelsim\win64',
    [string]$Distro = 'Ubuntu-22.04',
    [ValidateSet('performance', 'validation')][string]$SeedMode = 'performance',
    [int]$Iterations = 2700,
    [switch]$SkipSmokeTests,
    [switch]$RunLongSimulation
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (Select-String -LiteralPath (Join-Path $projectRoot 'rv32I.pds') -SimpleMatch 'board/acore_video_platform.v' -Quiet) {
    throw 'The root project now includes HDMI/PCIe/shared DDR (M2). This historical CoreMark flow would overwrite it. Follow docs/video_integration_m2.md and build the root rv32I.pds in PDS.'
}
Push-Location -LiteralPath $projectRoot
try {
    $wslRoot = (& wsl.exe -d $Distro --exec wslpath -a $projectRoot.Replace('\', '/')).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve WSL path' }
    foreach ($test in @('test_acore_dual.py', 'test_acore_dual_interrupt.py', 'test_interrupt.py')) {
        & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/$test"
        if ($LASTEXITCODE -ne 0) { throw "Acore regression failed: $test" }
    }
    if (-not $SkipSmokeTests) {
        foreach ($mode in @('performance', 'validation')) {
            & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/build_firmware.py" --core acore_dual --iterations 1 --mode $mode
            if ($LASTEXITCODE -ne 0) { throw 'Acore dual smoke firmware build failed' }
            & $Python scripts/prepare_ips.py --pds-root $PdsRoot --core acore_dual
            if ($LASTEXITCODE -ne 0) { throw 'Acore dual IP generation failed' }
            & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin --core acore_dual
            if ($LASTEXITCODE -ne 0) { throw 'Acore dual official IP regression failed' }
        }
    }
    & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/build_firmware.py" --core acore_dual --iterations $Iterations --mode $SeedMode
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual final firmware build failed' }
    $auditOptions = @('--skip-long-simulation')
    if ($RunLongSimulation) {
        $durationCheck = @('--allow-long-run')
        if ($Iterations -ge 1000) { $durationCheck = @('--require-duration') }
        & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/check_verilator.py" --core acore_dual @durationCheck
        if ($LASTEXITCODE -ne 0) { throw 'Acore dual final firmware simulation failed' }
        $auditOptions = @()
    }
    & $Python scripts/prepare_ips.py --pds-root $PdsRoot --core acore_dual
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual final IP generation failed' }
    & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin --core acore_dual --tests TB_acore_fetch_ip TB_acore_ram_ip TB_multiplier_ip
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual final IP checks failed' }
    $env:PANGO_LICENSE_FILE = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name PANGO_LICENSE_FILE).PANGO_LICENSE_FILE
    $buildDirectory = Join-Path $projectRoot 'build\pds-acore-dual'
    New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
    & "$PdsRoot\bin\pds_shell.exe" -file "$PSScriptRoot\implement_acore_dual.tcl" -work_dir $buildDirectory -project_name rv32I_acore_dual *> "$buildDirectory\console.log"
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual PDS failed; see build/pds-acore-dual/console.log' }
    & $Python scripts/audit_acore_dual.py @auditOptions
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual signoff audit failed' }
    & $Python scripts/export_project.py --pds-root $PdsRoot --source build/pds-acore-dual/rv32I_acore_dual.pds --destination rv32I.pds
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual exported project validation failed' }
}
finally { Pop-Location }
