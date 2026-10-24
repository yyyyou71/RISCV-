param(
    [string]$PdsRoot = 'C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1',
    [string]$Python = 'python',
    [string]$ModelsimBin = 'C:\diskE\modelsim\win64',
    [string]$Distro = 'Ubuntu-22.04'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
    $windowsPath = $projectRoot.Replace('\', '/')
    $wslRoot = & wsl.exe -d $Distro --exec wslpath -a $windowsPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the WSL project path' }
    $wslRoot = $wslRoot.Trim()
    & wsl.exe -d $Distro --exec python3 "$wslRoot/scripts/build_firmware.py"
    if ($LASTEXITCODE -ne 0) { throw 'Firmware build failed' }
    & $Python scripts/prepare_ips.py --pds-root $PdsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Pango memory IP generation failed' }
    & $Python scripts/check_modelsim.py --pds-root $PdsRoot --modelsim $ModelsimBin
    if ($LASTEXITCODE -ne 0) { throw 'Official IP simulation failed' }
    $env:PANGO_LICENSE_FILE = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name PANGO_LICENSE_FILE).PANGO_LICENSE_FILE
    $buildDirectory = Join-Path $projectRoot 'build\pds'
    New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
    Write-Output 'Running PDS implementation; log: build/pds/console.log'
    & "$PdsRoot\bin\pds_shell.exe" -file "$PSScriptRoot\implement.tcl" -work_dir $buildDirectory -project_name rv32I *> "$buildDirectory\console.log"
    if ($LASTEXITCODE -ne 0) { throw 'PDS implementation failed; see build/pds/console.log' }
    & $Python scripts/audit_build.py
    if ($LASTEXITCODE -ne 0) { throw 'Implementation audit failed' }
    & $Python scripts/export_project.py --pds-root $PdsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Root PDS project validation failed' }
}
finally {
    Pop-Location
}
