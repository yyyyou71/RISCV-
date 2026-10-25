param(
    [string]$Port,
    [switch]$ListPorts,
    [string]$Variant='speed',
    [ValidateRange(1,8192)][int]$Iterations=2048,
    [ValidateRange(10,3600)][int]$TimeoutSeconds=300,
    [string]$Python='C:\Users\LZM\AppData\Local\Programs\Python\Python312\python.exe',
    [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if($ListPorts) { [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object; exit 0 }
if(!$Port) { throw 'Specify -Port COMx or use -ListPorts.' }
. (Join-Path $PSScriptRoot 'coremark_serial.ps1')
$project=Split-Path $PSScriptRoot -Parent
$release=Get-Content -Raw -LiteralPath (Join-Path $project 'release.json') | ConvertFrom-Json
if($release.stage -ne 'EVOLVE5' -or !$release.variants.$Variant) { throw 'Unpublished EVOLVE5 configuration.' }
$impl=Get-Content -Raw -LiteralPath (Join-Path $project $release.variants.$Variant.pds_report) | ConvertFrom-Json
if($impl.status -ne 'passed') { throw 'This implementation has not passed PDS sign-off.' }
$digest=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $project $impl.bitstream)).Hash.ToLower()
if($digest -ne $impl.bitstream_sha256) { throw 'Bitstream differs from its PDS evidence.' }
if(!$OutputDirectory) { $OutputDirectory=Join-Path $project 'board_runs' }
$name=$Variant+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
$folder=Join-Path $OutputDirectory $name
[void](New-Item -ItemType Directory -Path $folder)
$logPath=Join-Path $folder 'uart.txt'
$writer=[System.IO.StreamWriter]::new($logPath,$false,[System.Text.UTF8Encoding]::new($false))
$serial=[System.IO.Ports.SerialPort]::new($Port,115200,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$serial.Handshake=[System.IO.Ports.Handshake]::None
$serial.DtrEnable=$false; $serial.RtsEnable=$false; $serial.ReadBufferSize=65536; $serial.WriteTimeout=3000
$serial.Encoding=[System.Text.Encoding]::ASCII
$state=@{status='running';variant=$Variant;port=$Port;iterations=$Iterations;expected_bitstream_sha256=$digest;started_utc=[DateTime]::UtcNow.ToString('o')}
try {
    $serial.Open(); $serial.DiscardInBuffer()
    Write-Host "Running both seed sets: $Variant, $Iterations iterations each. Wait for both results and CM_READY."
    $session=Invoke-CoreMarkSession -Connection $serial -LogWriter $writer -Iterations $Iterations -TimeoutSeconds $TimeoutSeconds
    $writer.Close(); $serial.Close()
    & $Python -X utf8 (Join-Path $PSScriptRoot 'verify_dual_log.py') $logPath --origin board --config $Variant --iterations $Iterations --output (Join-Path $folder 'validation.json')
    if($LASTEXITCODE -ne 0) { throw 'UART received but acceptance failed; inspect the saved logs.' }
    $state.status='passed'; $state.elapsed_seconds=$session.ElapsedSeconds
    Write-Host "EVOLVE5_BOARD_PASS: $folder"
} catch { $state.status='failed'; $state.error=$_.Exception.Message; throw }
finally {
    $writer.Dispose(); $serial.Dispose(); $state.completed_utc=[DateTime]::UtcNow.ToString('o')
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'session.json') -Encoding UTF8
}
