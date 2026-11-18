# run-tests.ps1 - end-to-end tests for thor.ps1 in a throwaway state dir. Needs no GPU: jobs run with -NoQuiet, the board is
# rendered from demo\fixture.json, and quiet-wait-tests.ps1 stubs the GPU. Usage: pwsh tests\run-tests.ps1 [-Shell pwsh|powershell] [-Keep]
param([string]$Shell = 'pwsh', [switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$thor = Join-Path $root 'thor.ps1'
$D = Join-Path ([IO.Path]::GetTempPath()) ("thor-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function T { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $thor @args -Dir $D 2>&1 | ForEach-Object { "$_" }; $script:out = $o -join "`n"; return $LASTEXITCODE }
function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red; Write-Host ($script:out -split "`n" | Select-Object -First 15 | Out-String) }
}
function Status { (& $Shell -NoProfile -File $thor status -Json -Dir $D | ConvertFrom-Json) }
function Job([string]$Id) { (& $Shell -NoProfile -File $thor job -JobId $Id -Json -Dir $D | ConvertFrom-Json) }
function Jobs([string]$By) { @(& $Shell -NoProfile -File $thor job -By $By -Json -Dir $D | ConvertFrom-Json) }
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
    Check 'cancelled: state' ($j.state -eq 'cancelled')
    Check 'cancelled: its command is gone' (-not (Get-Process -Id $j.childPid -ErrorAction SilentlyContinue))
    Check 'cancelled: its whole tree is gone' (-not $orphans.Count)
    $st = (Status).leases.build
    $script:out = "build lease: $($st.state), by $($st.lease.by)"
    Check 'cancelled: the lease is free' ($st.state -ne 'live')
    # --- a waiter whose job already ended leaves the queue (left in place it blocks everyone behind it with the lease free)
    [void](T take gpu -By holder -EstMin 1)
    [void](T submit gpu -By ci -Exe cmd.exe -ArgList '/c exit 0' -For 'ends in the queue' -EstMin 1)
    $dead = Job (LastId)
    Check 'a take behind the queued job waits (exit 2)' ($dead.state -eq 'queued' -and (T take gpu -By next -EstMin 1) -eq 2)
    # The job ends with its entry still queued, as when whatever ended it died before the dequeue.
    $jf = Join-Path $D "jobs\$($dead.id).json"
    [IO.File]::WriteAllText($jf, ([IO.File]::ReadAllText($jf) -replace '"state":\s*"queued"', '"state": "expired"'))
    Check 'ended job: release keeps the lease for the waiter behind it' ((T release gpu -By holder) -eq 0 -and $out -match 'kept for next')
    Check 'ended job: the waiter behind it takes the lease' ((T take gpu -By next -EstMin 1) -eq 0)
    $script:out = Get-Content -Raw (Join-Path $D 'lease.log')
    Check 'ended job: its entry is dequeued and logged' ($out -match "dequeue gpu $([regex]::Escape($dead.runBy)) \(job expired\)" -and -not @((Status).queues.gpu | Where-Object { $_.job }).Count)
    Check 'ended job: it never started' ((Job $dead.id).state -eq 'expired')
    [void](T release gpu -By next)
    # --- stats: what ran against what was estimated, and the estimate check on submit
    [void](T submit build -By st -Exe cmd.exe -ArgList '/c exit 0' -For 'stats probe 1' -EstMin 1 -NoQuiet)
    $sp = Wait-Job (LastId) @('done', 'failed')
    Check 'stats: a job that ran records when it took the lease' ($sp.state -eq 'done' -and [bool]$sp.took)
    foreach ($i in 1..3) {
        $t0 = [DateTime]::UtcNow.AddHours(-$i); $f = 'yyyy-MM-ddTHH:mm:ssZ'
        $fj = [ordered]@{ id = "st.j9$i-old"; by = 'st'; runBy = "st.j9$i"; lease = 'build'; note = "stats probe 9$i"; est = 1; exe = [string]$sp.exe; args = '/c exit 0'
            state = 'done'; exit = 0; submitted = $t0.ToString($f); started = $t0.ToString($f); took = $t0.ToString($f); ended = $t0.AddMinutes(30).ToString($f) }
        [IO.File]::WriteAllText((Join-Path $D "jobs\$($fj.id).json"), ($fj | ConvertTo-Json))
    }
    $rc = T submit build -By st -Exe cmd.exe -ArgList '/c exit 0' -For 'stats probe 2' -EstMin 1 -NoQuiet
    Check 'submit: an estimate far under what jobs like it took gets an estimate check' ($rc -eq 0 -and $out -match 'estimate check: the last 4 jobs like this ran a median of 30 min and you said 1\.')
    [void](Wait-Job (LastId) @('done', 'failed'))
    [void](T submit build -By st -Exe cmd.exe -ArgList '/c exit 0' -For 'stats probe 3' -EstMin 30 -NoQuiet)
    Check 'submit: a true estimate gets none' ($out -notmatch 'estimate check' -and $out -match 'job -JobId')
    [void](Wait-Job (LastId) @('done', 'failed'))
    $sj = & $Shell -NoProfile -File $thor stats -By st -Json -Dir $D | ConvertFrom-Json
    $script:out = $sj | ConvertTo-Json -Depth 4
    $sk = @($sj.kinds | Where-Object { $_.what -eq 'cmd.exe stats probe #' })
    Check 'stats -Json: one row for the kind, with its medians' ($sj.ran -eq 6 -and $sk.Count -eq 1 -and $sk[0].n -eq 6 -and $sk[0].lease -eq 'build' -and $sk[0].actual -ge 15 -and $sk[0].late -eq 3)
    Check 'stats: the table lists it' ((T stats -By st) -eq 0 -and $out -match '6 ran' -and $out -match 'cmd\.exe stats probe #')
    # --- board: one frame from the demo fixture
    $DD = "$D-demo"
    & $Shell -NoProfile -File (Join-Path $root 'demo\seed.ps1') -Dir $DD | Out-Null
    $frame = & $Shell -NoProfile -File $thor watch -Frame -Cols 150 -Rows 50 -Dir $DD -Fixture (Join-Path $root 'demo\fixture.json') | Out-String
    $plain = $frame -replace "\x1b\[[0-9;?]*[A-Za-z]", ''
    Check 'board frame renders' ($plain -match 'THOR TRAFFIC' -and $plain -match 'NEXT 90 MIN')
    Check 'board tags the uncovered run NO LEASE' ($plain -match 'NO LEASE')
    Check 'board shows the queued job as AUTO' ($plain -match 'AUTO: starts itself')
    # --- the profile table: every kind rule classifies as it always did, and quiet names each noisy kind its own way
    $kf = Join-Path $PSScriptRoot 'kinds-fixture.json'
    $ks = & $Shell -NoProfile -File $thor status -Json -Dir $DD -Fixture $kf | ConvertFrom-Json
    $got = (@($ks.procs | Sort-Object pid | ForEach-Object { "$($_.pid)=$($_.kind)$(if ($_.cpp) { '+cpp' })" }) -join ' ')
    $want = '101=commandlet 102=commandlet 103=game 104=editor 105=packaged 106=llm 107=llm 109=imagegen 111=build+cpp 112=build 113=build 114=build+cpp 116=game 117=imagegen 118=build+cpp 119=build 120=llm 121=editor'
    $script:out = $got
    Check 'kinds: each rule gives its kind, first match wins' ($got -eq $want)
    $rs = @($ks.reasons) -join "`n"; $script:out = $rs
    Check 'kinds: quiet names each noisy kind' ($rs -match 'local LLM loaded: llama-server\.exe pid 106' -and $rs -match 'image generation: python\.exe pid 109' -and
        $rs -match '-game run: pid 103 ' -and $rs -match 'packaged game: Outpost-Win64-Shipping\.exe pid 105' -and $rs -match 'commandlet: pid 101 ' -and
        $rs -match 'editor open: pid 104 .*\(-AllowEditor to ignore\)' -and $rs -match 'build work: cargo\.exe pid 113 \(-AllowBuild to ignore\)')
    $qo = (& $Shell -NoProfile -File $thor quiet -AllowEditor -AllowBuild -Dir $DD -Fixture $kf 2>&1 | ForEach-Object { "$_" }) -join "`n"; $script:out = $qo
    Check 'kinds: -AllowEditor and -AllowBuild drop only their kinds' ($LASTEXITCODE -eq 3 -and $qo -notmatch 'editor open' -and $qo -notmatch 'build work' -and $qo -match 'commandlet: pid 101' -and $qo -match 'local LLM loaded')
    Check 'status -Json lists the leases in table order' (@($ks.leases.PSObject.Properties.Name) -join ',' -eq 'editor,gpu,build' -and @($ks.queues.PSObject.Properties.Name) -join ',' -eq 'editor,gpu,build')
    # --- waiting for a quiet GPU holds nothing, and the overrun cap and alarm (their own scripts: they stub the GPU in a copy of thor.ps1)
    foreach ($suite in @('quiet-wait', 'cap')) {
        $qp = 0; $qf = 0
        & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "$suite-tests.ps1") -Shell $Shell | ForEach-Object { Write-Host $_; if ($_ -like 'PASS *') { $qp++ } elseif ($_ -like 'FAIL *') { $qf++ } }
        $qx = $LASTEXITCODE
        $pass += $qp; $fail += $qf
        if ($qx -and -not $qf) { $script:out = "$suite-tests.ps1 stopped before its end"; Check "$suite suite ran to its end" $false }
    }
} finally {
    if (-not $Keep) { Start-Sleep -Seconds 1; Remove-Item $D, "$D-demo" -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
