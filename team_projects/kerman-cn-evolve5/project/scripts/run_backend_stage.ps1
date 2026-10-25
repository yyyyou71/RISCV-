param([string]$Python='C:\Users\LZM\AppData\Local\Programs\Python\Python312\python.exe')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'run_board_stage.ps1') -Python $Python
