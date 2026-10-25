param(
    [string]$Python='C:\Users\LZM\AppData\Local\Programs\Python\Python312\python.exe',
    [switch]$Implement
)
$ErrorActionPreference='Stop'
function Invoke-BoardStage([string]$Name,[string[]]$Arguments=@()) {
    & $Python -X utf8 (Join-Path $PSScriptRoot $Name) @Arguments
    if($LASTEXITCODE -ne 0) { throw "CACHE3 stage failed: $Name" }
}
Invoke-BoardStage 'burst_unit_regress.py'
Invoke-BoardStage 'monitor_regress.py'
Invoke-BoardStage 'backend_regress.py'
Invoke-BoardStage 'machine_regress.py'
Invoke-BoardStage 'machine_regress.py' @('--bp-enable','0')
Invoke-BoardStage 'machine_regress.py' @('--cache-enable','0')
Invoke-BoardStage 'soc_regress.py'
Invoke-BoardStage 'machine_demo_regress.py'
Invoke-BoardStage 'coremark_regress.py'
Invoke-BoardStage 'coremark_regress.py' @('--burst-fill','0')
Invoke-BoardStage 'coremark_regress.py' @('--cache-enable','0')
foreach($test in @('test_coremark_parser.py','test_platform_identity.py')) {
    & $Python -X utf8 (Join-Path $PSScriptRoot ('../tests/'+$test))
    if($LASTEXITCODE -ne 0) { throw "Host test failed: $test" }
}
if($Implement) {
    foreach($variant in @('burst','word','uncached','selftest')) { Invoke-BoardStage 'cache_board_pds.py' @('--variant',$variant) }
    & $Python -X utf8 (Join-Path $PSScriptRoot '../tests/test_board_report.py')
    if($LASTEXITCODE -ne 0) { throw 'Board report acceptance tests failed.' }
}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../tests/test_coremark_serial.ps1')
if($LASTEXITCODE -ne 0) { throw 'Serial protocol tests failed.' }
Write-Output 'CACHE3_STAGE_PASS (physical board validation remains pending)'
