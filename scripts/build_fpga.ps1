param(
    [string]$PdsRoot = 'C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1',
    [string]$Python = 'python',
    [string]$ModelsimBin = 'C:\diskE\modelsim\win64',
    [string]$Distro = 'Ubuntu-22.04',
    [ValidateSet('single', 'acore_dual')][string]$Core = 'acore_dual',
    [ValidateSet('coremark', 'selftest')][string]$Application = 'coremark',
    [ValidateSet('performance', 'validation')][string]$SeedMode = 'performance',
    [int]$Iterations = 1000,
    [switch]$SkipSmokeTests
)

$ErrorActionPreference = 'Stop'
if ($Core -eq 'acore_dual') {
    if ($Application -ne 'coremark') {
        throw 'Dual issue currently supports CoreMark; use -Core single -Application selftest for the original selftest.'
    }
    & "$PSScriptRoot/build_acore_dual.ps1" -PdsRoot $PdsRoot -Python $Python -ModelsimBin $ModelsimBin -Distro $Distro -SeedMode $SeedMode -Iterations $Iterations -SkipSmokeTests:$SkipSmokeTests
    return
}
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
    $wslRoot = (& wsl.exe -d $Distro --exec wslpath -a $projectRoot.Replace('\', '/')).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the WSL project path' }
    if ($Application -eq 'coremark' -and -not $SkipSmokeTests) {
        foreach ($mode in @('performance', 'validation')) {
            & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/build_firmware.py" --iterations 1 --mode $mode
            if ($LASTEXITCODE -ne 0) { throw 'CoreMark smoke firmware build failed' }
            & $Python scripts/prepare_ips.py --pds-root $PdsRoot
            if ($LASTEXITCODE -ne 0) { throw 'Pango IP generation failed' }
            & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin --tests TB_coremark
            if ($LASTEXITCODE -ne 0) { throw 'Official IP CoreMark CRC regression failed' }
        }
    }
    & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/build_firmware.py" --application $Application --iterations $Iterations --mode $SeedMode
    if ($LASTEXITCODE -ne 0) { throw 'Firmware build failed' }
    if ($Application -eq 'coremark') {
        $durationCheck = @()
        if ($Iterations -ge 1000) { $durationCheck = @('--require-duration') }
        & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/check_verilator.py" @durationCheck
        if ($LASTEXITCODE -ne 0) { throw 'Final CoreMark firmware simulation failed' }
    }
    & $Python scripts/prepare_ips.py --pds-root $PdsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Pango IP generation failed' }
    $tests = @('TB_storage_images', 'TB_memory_core', 'TB_mem', 'TB_multiplier_ip')
    if ($Application -eq 'selftest') { $tests += 'TB_board' }
    & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin --tests @tests
    if ($LASTEXITCODE -ne 0) { throw 'Official IP simulation failed' }
    $env:PANGO_LICENSE_FILE = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name PANGO_LICENSE_FILE).PANGO_LICENSE_FILE
    $buildDirectory = Join-Path $projectRoot 'build\pds'
    New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
    Write-Output 'Running PDS implementation; log: build/pds/console.log'
    & "$PdsRoot\bin\pds_shell.exe" -file "$PSScriptRoot\implement.tcl" -work_dir $buildDirectory -project_name rv32I *> "$buildDirectory\console.log"
    if ($LASTEXITCODE -ne 0) { throw 'PDS implementation failed; see build/pds/console.log' }
    & $Python scripts/audit_build.py
    if ($LASTEXITCODE -ne 0) { throw 'Implementation audit failed' }
    & $Python scripts/export_project.py --pds-root $PdsRoot --source build/pds/rv32I.pds --destination rv32I.pds
    if ($LASTEXITCODE -ne 0) { throw 'Root PDS project validation failed' }
}
finally {
    Pop-Location
}
