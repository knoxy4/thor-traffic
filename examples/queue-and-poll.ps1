# queue-and-poll.ps1 - the "submit" pattern for agents whose tool calls are short-lived: queue the launch, go do something
# else, read the result later. Thor starts the job itself when the lease frees.
param([string]$Thor = (Join-Path $PSScriptRoot '..\thor.ps1'), [string]$By = 'agent1')
$ErrorActionPreference = 'Stop'
$out = & pwsh -NoProfile -File $Thor submit gpu -By $By -Exe 'cmd.exe' -ArgList '/c echo rendering & ping -n 4 127.0.0.1 >nul' -For 'demo render' -EstMin 1 -NoQuiet -Json | Out-String
$job = $out | ConvertFrom-Json
Write-Host "queued $($job.id) ($($job.state))"
# ...later (a later tool call, a later turn):
do { Start-Sleep 2; $j = & pwsh -NoProfile -File $Thor job -JobId $job.id -Json | ConvertFrom-Json } while ($j.state -in 'queued', 'starting', 'running')
Write-Host "$($j.id): $($j.state), exit $($j.exit)"
Get-Content $j.out
