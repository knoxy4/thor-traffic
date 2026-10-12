# run-tests.ps1 - end-to-end tests for thor.ps1 in a throwaway state dir. Needs no GPU: jobs run with -NoQuiet and the
# board is rendered from demo\fixture.json. Usage: pwsh tests\run-tests.ps1 [-Keep]
param([switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$thor = Join-Path $root 'thor.ps1'
$D = Join-Path ([IO.Path]::GetTempPath()) ("thor-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function T { $o = & pwsh -NoProfile -ExecutionPolicy Bypass -File $thor @args -Dir $D 2>&1 | ForEach-Object { "$_" }; $script:out = $o -join "`n"; return $LASTEXITCODE }
function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red; Write-Host ($script:out -split "`n" | Select-Object -First 15 | Out-String) }
}
function Status { (& pwsh -NoProfile -File $thor status -Json -Dir $D | ConvertFrom-Json) }
function Job([string]$Id) { (& pwsh -NoProfile -File $thor job -JobId $Id -Json -Dir $D | ConvertFrom-Json) }
function Jobs([string]$By) { @(& pwsh -NoProfile -File $thor job -By $By -Json -Dir $D | ConvertFrom-Json) }
function Wait-Job([string]$Id, [string[]]$States, [int]$Sec = 40) {
    $t = [DateTime]::UtcNow.AddSeconds($Sec)
    while ([DateTime]::UtcNow -lt $t) { $j = Job $Id; if ([string]$j.state -in $States) { return $j }; Start-Sleep -Milliseconds 700 }
    return (Job $Id)
}
function LastId { if ($script:out -match 'job -JobId (\S+)') { return $Matches[1] }; return '' }
function Hold-Cmd([int]$Sec) { "/c ping -n $($Sec + 1) 127.0.0.1 >nul" }
try {
    # --- leases and the waitlist
    Check 'take a free lease' ((T take gpu -By alpha -For 'perf capture' -EstMin 30) -eq 0)
    Check 'second take is queued (exit 2)' ((T take gpu -By beta -For 'smoke test' -EstMin 10) -eq 2)
    $s = Status
    Check 'status shows holder and queue' ($s.leases.gpu.lease.by -eq 'alpha' -and @($s.queues.gpu)[0].by -eq 'beta')
    $eta0 = [DateTime]$s.leases.gpu.lease.eta
    # --- re-estimate
    Check 'renew -EstMin re-estimates' ((T renew gpu -By alpha -EstMin 60) -eq 0 -and $out -match 're-estimated')
    $s = Status; $eta1 = [DateTime]$s.leases.gpu.lease.eta; $until1 = [DateTime]$s.leases.gpu.lease.until
    Check 'estimate moved ~30 min later' (($eta1 - $eta0).TotalMinutes -gt 25)
    Check 'expiry covers the estimate' ($until1 -ge $eta1.AddMinutes(4))
    Check "waiter's expected start follows" ([math]::Abs(([DateTime]@($s.queues.gpu)[0].start - $eta1).TotalMinutes) -lt 1)
    [void](T renew gpu -By alpha); $s = Status
    Check 'plain renew keeps the estimate' ([math]::Abs((([DateTime]$s.leases.gpu.lease.eta) - $eta1).TotalMinutes) -lt 1)
    # --- release keeps it for the first in line
    Check 'release' ((T release gpu -By alpha) -eq 0 -and $out -match 'kept for beta')
    Check 'kept for the queue: others wait' ((T take gpu -By gamma -NoQueue) -eq 2)
    Check 'first in line takes it' ((T take gpu -By beta) -eq 0)
    Check 'holder releases' ((T release gpu -By beta) -eq 0)
    # --- dispatcher: immediate start, exit codes, output capture
    Check 'submit on a free lease' ((T submit build -By ci -Exe cmd.exe -ArgList '/c echo hello from a job & exit 7' -For 'exit 7' -EstMin 1 -NoQuiet) -eq 0)
    $j = Wait-Job (LastId) @('done', 'failed')
    Check 'failing job records exit 7' ($j.state -eq 'failed' -and $j.exit -eq 7)
    Check 'job stdout captured' ((Get-Content -Raw $j.out) -match 'hello from a job')
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0' -For 'ok' -EstMin 1 -NoQuiet)
    $j = Wait-Job (LastId) @('done', 'failed')
    Check 'passing job is done, exit 0' ($j.state -eq 'done' -and $j.exit -eq 0)
    Check 'lease released after the job' ((Status).leases.build.state -eq 'none')
    # --- dispatcher: queued behind a holder, starts itself on release
    [void](T take build -By human -EstMin 1)
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0' -For 'queued' -EstMin 1 -NoQuiet)
    $q = Job (LastId)
    Check 'job waits in the queue' ($q.state -eq 'queued' -and @((Status).queues.build)[0].job -eq $q.id)
    [void](T release build -By human)
    [void](T submit editor -By ci -Exe cmd.exe -ArgList '/c exit 0' -For 'trigger a dispatch pass' -EstMin 1 -NoQuiet)
    $j = Wait-Job $q.id @('done', 'failed')
    Check 'queued job started itself and finished' ($j.state -eq 'done')
    # --- a submit that starts a long job returns at once (no inherited pipes)
    $t0 = [DateTime]::UtcNow
    [void](T submit build -By ci -Exe cmd.exe -ArgList (Hold-Cmd 25) -For 'long' -EstMin 1 -NoQuiet)
    Check 'submit returns while the job runs' (([DateTime]::UtcNow - $t0).TotalSeconds -lt 10)
    $long = Job (LastId)
    $j = Wait-Job $long.id @('running') 20
    Check 'long job is running under the lease' ($j.state -eq 'running' -and (Status).leases.build.lease.by -eq $long.runBy)
    # --- cancel
    Check 'cancel a running job' ((T job -JobId $long.id -Cancel -By ci) -eq 0)
    Start-Sleep -Seconds 2
    $j = Job $long.id
    $orphans = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $_.CommandLine -match '-n 26 127\.0\.0\.1' })
    Check 'cancelled, whole tree gone, lease free' ($j.state -eq 'cancelled' -and -not (Get-Process -Id $j.childPid -ErrorAction SilentlyContinue) -and -not $orphans.Count -and (Status).leases.build.state -ne 'live')
    # --- board: one frame from the demo fixture
    $DD = "$D-demo"
    & pwsh -NoProfile -File (Join-Path $root 'demo\seed.ps1') -Dir $DD | Out-Null
    $frame = & pwsh -NoProfile -File $thor watch -Frame -Cols 150 -Rows 50 -Dir $DD -Fixture (Join-Path $root 'demo\fixture.json') | Out-String
    $plain = $frame -replace "\x1b\[[0-9;?]*[A-Za-z]", ''
    Check 'board frame renders' ($plain -match 'THOR TRAFFIC' -and $plain -match 'NEXT 90 MIN')
    Check 'board tags the uncovered run NO LEASE' ($plain -match 'NO LEASE')
    Check 'board shows the queued job as AUTO' ($plain -match 'AUTO: starts itself')
} finally {
    if (-not $Keep) { Start-Sleep -Seconds 1; Remove-Item $D, "$D-demo" -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
