# launch-game-under-lease.ps1 - the "hold" pattern: a launcher script that starts its own processes takes the gpu lease
# tied to itself, so the cop covers the game (and its children) and the lease ends when this script ends, even if it crashes.
param(
    [string]$Thor = (Join-Path $PSScriptRoot '..\thor.ps1'),
    [string]$Editor = 'C:\Program Files\Epic Games\UE_5.6\Engine\Binaries\Win64\UnrealEditor.exe',
    [Parameter(Mandatory)][string]$Project,
    [string]$By = 'agent1',
    [int]$EstMin = 15
)
$ErrorActionPreference = 'Stop'
# In-process (&): waits in the queue, then for a quiet GPU, then holds the lease tied to this PowerShell process.
& $Thor hold gpu -By $By -For 'fps capture' -EstMin $EstMin -TimeoutMin 60
if ($LASTEXITCODE) { throw "no gpu lease (exit $LASTEXITCODE)" }
try {
    $log = Join-Path $env:TEMP "$By-fps.log"
    $p = Start-Process $Editor -ArgumentList "`"$Project`" -game -windowed -ResX=2560 -ResY=1440 -abslog=`"$log`" -ExecCmds=`"stat fps`"" -PassThru
    $p.WaitForExit()
    Write-Host "game exited $($p.ExitCode); log: $log"
} finally {
    & $Thor release gpu -By $By | Out-Null
}
