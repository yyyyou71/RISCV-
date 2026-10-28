param(
    [string]$PdsRoot = 'C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1',
    [string]$Python = 'python',
    [string]$ModelsimBin = 'C:\diskE\modelsim\win64',
    [string]$Distro = 'Ubuntu-22.04',
    [ValidateSet('performance', 'validation')][string]$SeedMode = 'performance',
    [int]$Iterations = 1000,
    [switch]$SkipSmokeTests
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
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
    $durationCheck = @()
    if ($Iterations -ge 1000) { $durationCheck = @('--require-duration') }
    & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/check_verilator.py" --core acore_dual @durationCheck
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual final firmware simulation failed' }
    & $Python scripts/prepare_ips.py --pds-root $PdsRoot --core acore_dual
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual final IP generation failed' }
    & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin --core acore_dual --tests TB_acore_fetch_ip TB_acore_ram_ip TB_multiplier_ip
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual final IP checks failed' }
    $env:PANGO_LICENSE_FILE = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name PANGO_LICENSE_FILE).PANGO_LICENSE_FILE
    $buildDirectory = Join-Path $projectRoot 'build\pds-acore-dual'
    New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
    & "$PdsRoot\bin\pds_shell.exe" -file "$PSScriptRoot\implement_acore_dual.tcl" -work_dir $buildDirectory -project_name rv32I_acore_dual *> "$buildDirectory\console.log"
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual PDS failed; see build/pds-acore-dual/console.log' }
    & $Python scripts/audit_acore_dual.py
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual signoff audit failed' }
    & $Python scripts/export_project.py --pds-root $PdsRoot --source build/pds-acore-dual/rv32I_acore_dual.pds --destination projects/acore_dual/acore_dual.pds
    if ($LASTEXITCODE -ne 0) { throw 'Acore dual exported project validation failed' }
}
finally { Pop-Location }
