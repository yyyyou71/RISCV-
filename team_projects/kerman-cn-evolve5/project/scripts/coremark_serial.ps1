# Protocol engine; the connection exposes Write(string) and ReadExisting().
# Separate from opening a COM port so split packets, resets and failure paths can be tested offline.
function Invoke-CoreMarkSession {
    param(
        [Parameter(Mandatory=$true)][object]$Connection,
        [Parameter(Mandatory=$true)][System.IO.TextWriter]$LogWriter,
        [ValidateRange(1,8192)][int]$Iterations=2048,
        [double]$TimeoutSeconds=300,
        [ValidateRange(0,1000)][int]$PollMilliseconds=20
    )
    if ($TimeoutSeconds -le 0) { throw 'Timeout must be positive.' }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $phase='boot'; $pending=''; $banner=$false; $portCheck=$false
    $resultCount=0; $beginCount=0
    [void]$Connection.Write("r`n")
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $chunk=$Connection.ReadExisting()
        if ($chunk.Length -gt 0) {
            $LogWriter.Write($chunk); $LogWriter.Flush()
            $pending += $chunk
            if ($pending.Length -gt 65536) { throw 'UART line exceeds 64 KiB; verify baud and firmware.' }
            while (($newline=$pending.IndexOf("`n")) -ge 0) {
                $line=$pending.Substring(0,$newline).TrimEnd([char]13)
                $pending=$pending.Substring($newline+1)
                if ($line -eq 'RV32I MACHINE DEMO' -or $line -eq 'RV32I BOARD READY') {
                    throw 'Wrong firmware: load the CoreMark image before using this tool.'
                }
                if ($line -eq 'PORT_CHECK FAIL' -or $line.StartsWith('M_CHECK FAIL') -or $line.StartsWith('DUAL_CHECK FAIL') -or $line.StartsWith('CM_FAIL:') -or $line -eq 'CM_COMMAND_ERROR') {
                    throw "Firmware failure: $line"
                }
                if ($line -eq 'RV32I COREMARK 1.0' -or $line -eq 'RISC-V COREMARK 1.0') {
                    if ($phase -ne 'boot') { throw 'Unexpected CPU restart during benchmark.' }
                    $banner=$true
                }
                if ($line -eq 'PORT_CHECK PASS') { $portCheck=$true }
                if ($phase -eq 'benchmark') {
                    if ($line.StartsWith('CM_BEGIN ')) { $beginCount++ }
                    if ($line.StartsWith('CM_RESULT ')) { $resultCount++ }
                    if ($beginCount -gt 2 -or $resultCount -gt 2) { throw 'Unexpected extra benchmark records.' }
                }
                if ($line -eq 'CM_READY') {
                    if ($phase -eq 'boot') {
                        if (!$banner -or !$portCheck) { throw 'Expected CoreMark boot banner and PORT_CHECK PASS.' }
                        [void]$Connection.Write("b $Iterations`n")
                        $phase='benchmark'
                    } else {
                        if ($beginCount -ne 2 -or $resultCount -ne 2) { throw 'Incomplete benchmark pair at CM_READY.' }
                        return [pscustomobject]@{ Phase='completed'; ResultCount=$resultCount; ElapsedSeconds=$timer.Elapsed.TotalSeconds }
                    }
                }
            }
        } elseif ($PollMilliseconds -gt 0) { Start-Sleep -Milliseconds $PollMilliseconds }
    }
    throw "CoreMark timeout in $phase phase; partial UART log has been preserved."
}
