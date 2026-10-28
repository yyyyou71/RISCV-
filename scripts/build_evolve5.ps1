param(
    [string]$PdsRoot = 'C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1',
    [string]$Python = 'python',
    [string]$ModelsimBin = 'C:\diskE\modelsim\win64',
    [string]$Distro = 'Ubuntu-22.04',
    [ValidateSet('performance', 'validation')][string]$SeedMode = 'performance',
    [int]$Iterations = 2048,
    [switch]$SkipSmokeTests
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
    $wslRoot = (& wsl.exe -d $Distro --exec wslpath -a $projectRoot.Replace('\', '/')).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve WSL path' }
    & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/check_evolve5_control.py"
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 control/interrupt regression failed' }
    if (-not $SkipSmokeTests) {
        foreach ($mode in @('performance', 'validation')) {
            & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/build_firmware.py" --core evolve5 --iterations 1 --mode $mode
            if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 smoke firmware build failed' }
            & $Python scripts/prepare_ips.py --pds-root $PdsRoot --core evolve5
            if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 IP generation failed' }
            & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin --core evolve5
            if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 official IP CoreMark regression failed' }
        }
    }
    & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/build_firmware.py" --core evolve5 --iterations $Iterations --mode $SeedMode
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 firmware build failed' }
    $durationCheck = @()
    if ($Iterations -ge 2048) { $durationCheck = @('--require-duration') }
    & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/check_verilator.py" --core evolve5 @durationCheck
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 final firmware simulation failed' }
    & $Python scripts/prepare_ips.py --pds-root $PdsRoot --core evolve5
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 final IP generation failed' }
    & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin --core evolve5 --tests TB_evolve5_ip TB_evolve5_memory
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 final IP checks failed' }
    & $Python scripts/evolve5_sources.py
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 PDS source preparation failed' }
    $env:PANGO_LICENSE_FILE = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name PANGO_LICENSE_FILE).PANGO_LICENSE_FILE
    $buildDirectory = Join-Path $projectRoot 'build\pds-evolve5'
    & "$PdsRoot\bin\pds_shell.exe" -file "$PSScriptRoot\implement_evolve5.tcl" -work_dir $buildDirectory -project_name rv32I_evolve5 *> "$buildDirectory\console.log"
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 PDS failed; see build/pds-evolve5/console.log' }
    & $Python scripts/audit_evolve5.py
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 sign-off audit failed' }
    & $Python scripts/export_project.py --pds-root $PdsRoot --source build/pds-evolve5/rv32I_evolve5.pds --destination cores/evolve5/pds/evolve5.pds
    if ($LASTEXITCODE -ne 0) { throw 'EVOLVE5 exported project validation failed' }
}
finally { Pop-Location }
