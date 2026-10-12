# install-cop.ps1 - keep the Thor cop (and the dispatcher) running whether or not a board window is open.
# Registers a logon task "ThorTraffic cop" that runs `thor.ps1 cop -CopWait` with no window (conhost --headless), and
# re-checks every 5 minutes so a cop that died comes back. -CopWait: while a board window's cop holds the cop mutex, the
# task's cop waits and takes over when that window closes. The cop pass also runs the dispatcher, so queued jobs start
# even when nobody is watching.
# Usage: .\install-cop.ps1 [-Check] [-Uninstall] [-StartNow] [-Dir <state dir>]
param([switch]$Check, [switch]$Uninstall, [switch]$StartNow, [string]$TaskName = 'ThorTraffic cop', [string]$Dir = '')
$ErrorActionPreference = 'Stop'
$tl = Join-Path $PSScriptRoot 'thor.ps1'
if (-not (Test-Path $tl)) { throw "missing $tl" }
function Cop-Procs {
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' or Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'thor\.ps1"?\s+(cop|watch)(\s|$)' })
}
function Cop-Held {
    $m = New-Object Threading.Mutex($false, 'Global\ThorTraffic_cop')
    try { $free = $m.WaitOne(0) } catch { $free = $true }   # abandoned (its cop was killed) = free, and ours after the exception
    if ($free) { try { $m.ReleaseMutex() } catch {} }
    $m.Dispose(); return -not $free
}
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($Check) {
    $on = Cop-Held
    $state = if ($task) { "installed ($($task.State))" } else { 'not installed' }
    Write-Host "thor cop task: $state; a cop is $(if ($on) { 'running' } else { 'NOT running' })" -ForegroundColor $(if ($task -and $on) { 'Green' } else { 'Yellow' })
    foreach ($p in Cop-Procs) { Write-Host "  pid $($p.ProcessId): $($p.CommandLine)" }
    if ($task -and $on) { exit 0 } else { exit 2 }
}
if ($Uninstall) {
    if ($task) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
    foreach ($p in Cop-Procs) { if ($p.CommandLine -match '\scop(\s|$)') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
    Write-Host 'thor cop task: removed' -ForegroundColor Green; exit 0
}

$pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pw) { $pw = (Get-Command powershell).Source }
$psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tl`" cop -CopWait"
if ($Dir) { $psArgs += " -Dir `"$Dir`"" }
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
# conhost --headless gives the console app no window at all (a plain hidden start still opens one in Windows Terminal).
$action = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$pw`" $psArgs" -WorkingDirectory $PSScriptRoot
$user = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$desc = 'Thor Traffic Control: GPU cop + job dispatcher. Uninstall: install-cop.ps1 -Uninstall'
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $desc -Force | Out-Null
Write-Host "thor cop task: installed '$TaskName' (at logon of $user, re-checked every 5 min)" -ForegroundColor Green
if ($StartNow) { Start-ScheduledTask -TaskName $TaskName; Write-Host 'thor cop task: started' -ForegroundColor Green }
exit 0
