$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\scripts\coremark_serial.ps1')
function New-FakeConnection([string[]]$Chunks) {
    $fake=[pscustomobject]@{Chunks=$Chunks; Index=0; Writes=[Collections.Generic.List[string]]::new()}
    $fake | Add-Member ScriptMethod Write { param([string]$text) [void]$this.Writes.Add($text) }
    $fake | Add-Member ScriptMethod ReadExisting {
        if ($this.Index -lt $this.Chunks.Length) { $v=$this.Chunks[$this.Index]; $this.Index++; return $v }
        return ''
    }
    return $fake
}
function Assert-True($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
# Synthetic protocol records only; deliberately not sufficient to become a score.
$boot="RISC-V COREMARK 1.0`r`nDUAL_CHECK PASS iterations=1024 cycles=18503 instret=34818 pairs=16377`nPORT_CHECK PASS`nCM_READY`n"
$pair="CM_BEGIN mode=performance`nCM_RESULT mode=performance`nCM_BEGIN mode=validation`nCM_RESULT mode=validation`nCM_READY`n"
$text=$boot+$pair
$chunks=[Collections.Generic.List[string]]::new()
for($i=0;$i -lt $text.Length;$i+=7) { $chunks.Add($text.Substring($i,[Math]::Min(7,$text.Length-$i))) }
$fake=New-FakeConnection $chunks.ToArray(); $log=[IO.StringWriter]::new()
$result=Invoke-CoreMarkSession $fake $log -PollMilliseconds 0 -TimeoutSeconds 1
Assert-True ($result.ResultCount -eq 2) 'Split-frame reception failed'
Assert-True ($log.ToString() -eq $text) 'Raw UART log changed'
Assert-True ($fake.Writes.Count -eq 2 -and $fake.Writes[0] -eq "r`n" -and $fake.Writes[1] -eq "b 2048`n") 'Command ordering/newline mismatch'
$cases=@(
    @{name='wrong image'; text="RV32I MACHINE DEMO`n"; error='Wrong firmware'},
    @{name='missing boot'; text="CM_READY`n"; error='Expected CoreMark boot'},
    @{name='port failure'; text="PORT_CHECK FAIL`n"; error='Firmware failure'},
    @{name='dual failure'; text="DUAL_CHECK FAIL`n"; error='Firmware failure'},
    @{name='multiply failure'; text="M_CHECK FAIL`n"; error='Firmware failure'},
    @{name='partial pair'; text=$boot+"CM_BEGIN mode=performance`nCM_RESULT mode=performance`nCM_READY`n"; error='Incomplete benchmark pair'},
    @{name='unexpected reset'; text=$boot+"RV32I COREMARK 1.0`n"; error='Unexpected CPU restart'},
    @{name='unexpected new reset'; text=$boot+"RISC-V COREMARK 1.0`n"; error='Unexpected CPU restart'},
    @{name='CRC failure'; text=$boot+"CM_FAIL: CRC/data mismatch`n"; error='Firmware failure'},
    @{name='timeout'; text=$boot; error='CoreMark timeout'}
)
foreach($case in $cases) {
    $fake=New-FakeConnection @($case.text); $log=[IO.StringWriter]::new(); $caught=$false
    try { $null=Invoke-CoreMarkSession $fake $log -PollMilliseconds 0 -TimeoutSeconds 0.05 }
    catch { $caught=$_.Exception.Message.Contains($case.error) }
    Assert-True $caught ('Expected rejection: '+$case.name)
    Assert-True ($log.ToString() -eq $case.text) ('Partial log was lost: '+$case.name)
}
Write-Output 'COREMARK_SERIAL_PROTOCOL_TESTS_PASS cases=11 physical_serial_port_tested=false'
