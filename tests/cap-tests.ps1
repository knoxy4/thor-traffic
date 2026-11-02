# cap-tests.ps1 - the overrun cap, the lane breaker, the queue's math past an estimate and the over-cap alarm (thor.ps1 header).
# Real runners and real process trees in a throwaway state dir, on their own mutexes. Only these differ from the tool: the pad is 0.1 min instead of 5, so a cap
# falls in seconds; the GPU reading and the process table are stubbed, so it needs no GPU and starts nothing named like Unreal; and Cop-Pass is a no-op, because
# scratch leases cover nothing real and it would otherwise stop real runs. It takes no real lease. Most of it runs a copy with the lane breaker on, so that code stays
# tested; one section runs the copy as shipped, with it off.
# Usage: pwsh tests\cap-tests.ps1 [-Shell pwsh|powershell] [-Tool <path to thor.ps1>] [-Keep]
param([string]$Shell = 'pwsh', [string]$Tool = (Join-Path (Split-Path -Parent $PSScriptRoot) 'thor.ps1'), [switch]$Keep)
$ErrorActionPreference = 'Stop'
$Pad = 0.1
$Work = Join-Path ([IO.Path]::GetTempPath()) ("thor-cap-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$D = Join-Path $Work 'state'
$scr = Join-Path $Work 'scratch'
New-Item -ItemType Directory -Force $D, (Join-Path $scr 'cap'), (Join-Path $scr 'al'), (Join-Path $scr 'off') | Out-Null
$env:THOR_SCRATCH = $scr
$tlOn = Join-Path $Work 'thor_stub_on.ps1'; $tlOff = Join-Path $Work 'thor_stub_off.ps1'
$tl = $tlOn
$stub = @'
# ---- test stubs ----
function Get-Gpu([int]$Samples = 3) { $v = ([IO.File]::ReadAllText((Join-Path $Dir 'fake_gpu.txt'))).Trim() -split ','; [pscustomobject]@{ usedMB = [int]$v[0]; totalMB = 12288; util = [int]$v[1] } }
function Get-Procs { $script:ParentOf = @{}; $script:Info = @{}; $f = Join-Path $Dir 'fake_procs.json'; if (Test-Path $f) { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json; foreach ($p in @($o)) { $script:Info[[int]$p.pid] = @{ parent = [int]$p.parent; started = [DateTime]::MinValue } }; return @(@($o) | Where-Object { $_.kind } | ForEach-Object { $_.pid = [int]$_.pid; $_ }) }; return @() }
function Cop-Pass($Procs, $Leases) { return @{ killed = @(); spared = @(); struck = @() } }
if ($script:BoundKeys -notcontains 'SettleSec') { $SettleSec = 3 }
if ($env:THOR_TEST_PASS) { [void](Dispatch-Pass); exit 0 }
if ($env:THOR_TEST_ALARM) { [void](Alarm-Pass (Get-Leases)); exit 0 }
if ($env:THOR_TEST_BOARD) { $script:CopOn = $true; $script:CopKills = 0; [void](Board-Model); exit 0 }
if ($env:THOR_TEST_READS) {
    $script:GL = 0; $script:OrigGL = ${function:Get-Leases}
    function script:Get-Leases { $script:GL++; & $script:OrigGL }
    $script:CopOn = $true; $script:CopKills = 0; [void](Board-Model); "reads=$($script:GL)"; exit 0
}

'@
$src = [IO.File]::ReadAllText((Resolve-Path $Tool).Path)
$mark = '# ---- verbs ---'
if ($src.IndexOf($mark) -lt 0) { throw 'no verbs marker in the tool' }
$mx = 'Global\T' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '_'
$shipped = $src.Replace($mark, $stub + $mark).Replace('$CapPadMin = 5', "`$CapPadMin = $Pad").Replace('Global\ThorTraffic_', $mx)
[IO.File]::WriteAllText($tlOff, $shipped, (New-Object Text.UTF8Encoding $true))
[IO.File]::WriteAllText($tlOn, $shipped.Replace('$LaneBreakOn = $false', '$LaneBreakOn = $true'), (New-Object Text.UTF8Encoding $true))
[IO.File]::WriteAllText((Join-Path $D 'fake_gpu.txt'), '500,5')

$script:pass = 0; $script:fail = 0; $script:last = ''; $script:bgs = @()
function Check($Name, $Cond) {
    if ($Cond) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name  :: $($script:last)" -ForegroundColor Red }
}
function TL { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $tl @args -Dir $D 2>&1 | ForEach-Object { "$_" }; $script:last = $o -join "`n"; return $LASTEXITCODE }
function Bg {
    $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tl`"") + @($args | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } }) + @('-Dir', "`"$D`"")
    $p = Start-Process $Shell -ArgumentList $al -PassThru -WindowStyle Hidden; $null = $p.Handle; $script:bgs += $p; return $p
}
function Q($l) { $p = Join-Path $D "queue\$l.json"; if (-not (Test-Path $p)) { return @() }; try { $o = Get-Content $p -Raw | ConvertFrom-Json; return @($o.entries) } catch { return @() } }
function E($l, $who) { return @(Q $l | Where-Object { $_.by -eq $who }) | Select-Object -First 1 }
function L($l) { $p = Join-Path $D "leases\$l.json"; if (-not (Test-Path $p)) { return $null }; try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null } }
function Job($id) { $p = Join-Path $D "jobs\$id.json"; try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null } }
function Submit { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $tl submit @args -NoQuiet -Json -Dir $D 2>&1 | ForEach-Object { "$_" }; $script:last = $o -join "`n"; return ($script:last | ConvertFrom-Json) }
function LogText { $p = Join-Path $D 'lease.log'; if (Test-Path $p) { Get-Content $p -Raw } else { '' } }
function Said([string]$Pattern) { return @([regex]::Matches((LogText), $Pattern)).Count }
function Pass { $env:THOR_TEST_PASS = '1'; try { & $Shell -NoProfile -ExecutionPolicy Bypass -File $tl status -Dir $D *> $null } finally { $env:THOR_TEST_PASS = $null } }
function Until([scriptblock]$Cond, [int]$Sec = 25) { $t = [DateTime]::UtcNow.AddSeconds($Sec); while ([DateTime]::UtcNow -lt $t) { try { if (& $Cond) { return $true } } catch {}; Start-Sleep -Milliseconds 400 }; return $false }
function U($v) { if ($v -is [DateTime]) { return $v.ToUniversalTime() }; $st = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal; return [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, $st) }
function Iso([DateTime]$T) { $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function CapOf($x) { return (U $x.eta).AddMinutes([double]$x.est + $Pad) }
function PastCap([string]$n = 'gpu') { $x = L $n; if (-not $x) { throw "PastCap: nobody holds $n, so the scenario went wrong" }; $w = ((CapOf $x) - [DateTime]::UtcNow).TotalSeconds + 1; if ($w -gt 30) { throw "PastCap would sleep $([int]$w) s on $($x.by)'s lease, so the scenario went wrong" }; if ($w -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling($w)) } }
function Cop { TL cop -Once -ReapAfterMin 0 @args | Out-Null }
function Alive([int]$P) { return [bool](Get-Process -Id $P -ErrorAction SilentlyContinue) }
function Kid([int]$P) { return @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$P" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'conhost.exe' } | ForEach-Object { [int]$_.ProcessId }) | Select-Object -First 1 }
function Runs($id) { $j = Job $id; return ($j.state -eq 'running' -and $j.childPid -and (Kid ([int]$j.childPid))) }
function Tidy($id) { if ($id) { TL job -JobId $id -Cancel | Out-Null } }
function Free([string]$n = 'gpu') { [void](Until { -not (L $n) } 15) }
function Table($Rows) { $f = Join-Path $D 'fake_procs.json'; if ($Rows) { [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($Rows) -Depth 3)) } elseif (Test-Path $f) { Remove-Item $f -Force } }
function Row([string]$Kind, [int]$P, [int]$Parent) { return @{ kind = $Kind; cpp = $false; pid = $P; parent = $Parent; name = 'x'; cmd = 'x'; full = 'x'; started = '2026-01-01T00:00:00Z' } }
function SetLease($n, [hashtable]$F) { $p = Join-Path $D "leases\$n.json"; $o = Get-Content $p -Raw | ConvertFrom-Json; foreach ($k in $F.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $F[$k] -Force }; [IO.File]::WriteAllText($p, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) }
function SetJob($id, [string]$State) { $p = Join-Path $D "jobs\$id.json"; $o = Get-Content $p -Raw | ConvertFrom-Json; $o.state = $State; [IO.File]::WriteAllText($p, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) }
function Note([string]$Who) { $f = Join-Path $scr "$Who\THOR_COP.txt"; if (Test-Path $f) { return [IO.File]::ReadAllText($f) }; return '' }
$ok = '/c exit 0'; $tree = '/c ping -n 120 127.0.0.1 >nul'; $slow = '/c ping -n 13 127.0.0.1 >nul'
$holder = Join-Path $Work 'holder.ps1'
Set-Content $holder @'
param([string]$Tl, [string]$Dir, [string]$By, [string]$PidFile)
& $Tl hold gpu -By $By -NoQuiet -EstMin 0.01 -Dir $Dir
[IO.File]::WriteAllText($PidFile, "$PID")
Start-Sleep 120
'@

try {
    # --- the cap: stopped, the lane cancelled, the next lane runs
    $rc = TL submit gpu -By cap.a -Exe cmd.exe -ArgList $tree -For 'sleeps past its cap' -NoQuiet -EstMin 0.01
    Check 'submit prints when the cap falls' ($rc -eq 0 -and $last -match 'its cap falls about \d\d:\d\d, [\d.]+ min after it starts')
    $aId = ([regex]::Match($last, 'job (cap\.a\.j1-[^\s:]+)')).Groups[1].Value
    Check 'it runs' (Until { Runs $aId } 20)
    $aChild = [int](Job $aId).childPid; $aKid = Kid $aChild
    Check 'the dispatch line gives the cap' ((LogText) -match 'dispatch gpu cap\.a\.j1 job \S+ cap ~\d{4}-\d\d-\d\dT\S+Z for: sleeps')
    $b = Submit gpu -By cap.b -Exe cmd.exe -ArgList $ok -For 'sibling' -EstMin 0.01
    $b2 = Submit gpu -By cap.a -Exe cmd.exe -ArgList $ok -For 'second of its own name' -EstMin 0.01
    $rc = TL submit gpu -By cap.c -Exe cmd.exe -ArgList $ok -For 'queued, says when' -NoQuiet -EstMin 0.01
    Check 'a queued submit prints the cap too' ($rc -eq 0 -and $last -match 'queued: gpu' -and $last -match 'its cap falls about')
    $cId = ([regex]::Match($last, 'job (cap\.c\.j1-[^\s:]+)')).Groups[1].Value
    $z = Submit gpu -By cap2 -Exe cmd.exe -ArgList $ok -For 'next lane' -EstMin 0.01
    TL take gpu -By cap.plain | Out-Null
    TL take editor -By someone | Out-Null
    $ed = Submit editor -By cap.ed -Exe cmd.exe -ArgList $ok -For 'same root, other lease' -EstMin 0.01
    PastCap
    Check 'past its cap, not yet stopped: only the cop does that' ((Job $aId).state -eq 'running')
    Cop
    $ja = Job $aId
    Check 'stopped at the cap: state overrun' ($ja.state -eq 'overrun' -and $ja.ended)
    Check 'its why says what happened' ($ja.why -match 'overrun cap' -and $ja.why -match 'waiting')
    Check 'job-overrun in lease.log' ((LogText) -match 'job-overrun gpu cap\.a\.j1 job \S+ \(held \d+ min on an estimate of 0\.01 min, past its cap')
    Check 'its whole tree is dead' (Until { -not (Alive $aChild) -and -not (Alive $aKid) } 8)
    Check 'the sibling is cancelled' ((Job $b.id).state -eq 'cancelled' -and (Job $b2.id).state -eq 'cancelled' -and (Job $cId).state -eq 'cancelled')
    Check 'the why names the job that went over' ((Job $b.id).why -match 'lane breaker: cap\.a\.j1 ')
    Check 'job-cancel lines say so' ((LogText) -match 'job-cancel gpu cap\.b\.j1 job \S+ \(was queued; lane breaker: cap\.a\.j1 ')
    Check 'they left the queue' (-not (E gpu $b.runBy) -and -not (E gpu $b2.runBy))
    Check 'a plain waiter of the same root stays' ([bool](E gpu cap.plain))
    Check 'a same-root job on another lease stays' ((Job $ed.id).state -eq 'queued' -and [bool](E editor $ed.runBy))
    Check 'the next lane is not cancelled' ((Job $z.id).state -ne 'cancelled')
    Check 'the runner left no job-failed line over it' ((LogText) -notmatch 'job-failed gpu cap\.a\.j1')
    Check 'and the next lane is dispatched' (Until { (Job $z.id).state -eq 'done' } 15)
    Check 'the holder is told in THOR_COP.txt' ((Note 'cap') -match "stopped your job $([regex]::Escape($aId))")
    Check 'and told about the jobs it lost' ((Note 'cap') -match 'cancelled your queued gpu jobs')
    Check 'the plain waiter gets the lease' (Until { (TL take gpu -By cap.plain) -eq 0 } 15)
    TL release gpu -By cap.plain | Out-Null
    Tidy $ed.id; TL release editor -By someone | Out-Null; Free editor

    # --- nobody queued: left alone, until someone does queue
    $c1 = Submit gpu -By lone -Exe cmd.exe -ArgList $tree -For 'nobody behind it' -EstMin 0.01
    Check 'lone job runs' (Until { Runs $c1.id } 20)
    PastCap
    Cop
    Check 'nobody queued: left alone' ((Job $c1.id).state -eq 'running' -and (LogText) -notmatch 'job-overrun gpu lone')
    TL take gpu -By late | Out-Null
    Cop
    Check 'someone queues: it goes on the next pass' ((Job $c1.id).state -eq 'overrun')
    TL unqueue gpu -By late | Out-Null; Free

    # --- -CopDryRun, -CopMatch and the board's cop
    $d1 = Submit gpu -By dry -Exe cmd.exe -ArgList $tree -For 'dry run' -EstMin 0.01
    Check 'dry job runs' (Until { Runs $d1.id } 20)
    $d2 = Submit gpu -By dry -Exe cmd.exe -ArgList $ok -For 'dry sibling' -EstMin 0.01
    PastCap
    TL cop -Once -ReapAfterMin 0 -CopDryRun | Out-Null
    Check '-CopDryRun says what it would stop and cancel' ($last -match 'would stop job dry\.j1' -and $last -match 'and cancel dry\.j2')
    Check '-CopDryRun stops nothing' ((Job $d1.id).state -eq 'running' -and (Alive ([int](Job $d1.id).childPid)))
    Check '-CopDryRun cancels nothing' ((Job $d2.id).state -ne 'cancelled' -and [bool](E gpu $d2.runBy))
    Check '-CopDryRun logs nothing' ((LogText) -notmatch 'job-overrun gpu dry' -and (LogText) -notmatch 'job-cancel gpu dry')
    TL cop -Once -CopMatch 'no-such-command' -ReapAfterMin 0 | Out-Null
    Check '-CopMatch that misses leaves it' ((Job $d1.id).state -eq 'running')
    $env:THOR_TEST_BOARD = '1'; try { TL status -ReapAfterMin 0 | Out-Null } finally { $env:THOR_TEST_BOARD = $null }
    Check 'the watch board''s cop stops it too' ((Job $d1.id).state -eq 'overrun' -and (Job $d2.id).state -eq 'cancelled')
    Free

    # --- renew moves the cap
    $r1 = Submit gpu -By ren -Exe cmd.exe -ArgList $tree -For 'renews' -EstMin 0.01
    Check 'renew job runs' (Until { Runs $r1.id } 20)
    TL take gpu -By rw | Out-Null
    $l0 = L gpu; $cap0 = CapOf $l0
    TL renew gpu -By $r1.runBy -EstMin 1 | Out-Null
    $l1 = L gpu
    Check 'renew -EstMin moves the cap out' ((CapOf $l1) -gt $cap0.AddSeconds(60))
    Check 'to 2 x est + pad from the renew' ([Math]::Abs(((CapOf $l1) - [DateTime]::UtcNow).TotalMinutes - (2 + $Pad)) -lt 0.2)
    Check 'the lease stays tied to its runner and child' ($l1.pid -eq $l0.pid -and $l1.childPid -eq $l0.childPid -and "$($l1.taken)" -eq "$($l0.taken)")
    $w = ($cap0 - [DateTime]::UtcNow).TotalSeconds + 1; if ($w -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling($w)) }
    Cop
    Check 'past the old cap, inside the new: not stopped' ((Job $r1.id).state -eq 'running')
    TL renew gpu -By $r1.runBy | Out-Null
    Check 'a plain renew inside the estimate leaves the cap' ([Math]::Abs(((CapOf (L gpu)) - (CapOf $l1)).TotalSeconds) -lt 2)
    # Read from the take, a short late renew would put the cap in the past and stop the job right after it said "0.2 more".
    $lateAt = (U $l0.taken).AddMinutes(2 * 0.2 + $Pad + 0.05)
    $w = ($lateAt - [DateTime]::UtcNow).TotalSeconds; if ($w -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling($w)) }
    TL renew gpu -By $r1.runBy -EstMin 0.2 | Out-Null
    $l2 = L gpu
    Check 'a late renew: the cap is still ahead of it' ((CapOf $l2) -gt [DateTime]::UtcNow.AddSeconds(15))
    Cop
    Check 'a late renew is not stopped at once' ((Job $r1.id).state -eq 'running')
    $w = ((CapOf $l2) - [DateTime]::UtcNow).TotalSeconds + 1; if ($w -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling($w)) }
    Cop
    Check 'and goes once the renewed cap passes' ((Job $r1.id).state -eq 'overrun')
    TL unqueue gpu -By rw | Out-Null; Free

    # --- ends past its cap on its own: no cop, the runner breaks the lane
    $e1 = Submit gpu -By own -Exe cmd.exe -ArgList $slow -For 'ends late by itself' -EstMin 0.01
    Check 'own job runs' (Until { (Job $e1.id).state -eq 'running' } 20)
    $e2 = Submit gpu -By own -Exe cmd.exe -ArgList $ok -For 'its sibling' -EstMin 0.01
    $e3 = Submit gpu -By other-lane -Exe cmd.exe -ArgList $ok -For 'someone else' -EstMin 0.01
    Check 'it ends done with its own exit code' (Until { (Job $e1.id).state -eq 'done' -and (Job $e1.id).exit -eq 0 } 30)
    Check 'its sibling is cancelled, naming it' ((Job $e2.id).state -eq 'cancelled' -and (Job $e2.id).why -match "lane breaker: $([regex]::Escape($e1.runBy)) ")
    Check 'the other lane stays' ((Job $e3.id).state -in @('queued', 'starting', 'running', 'done'))
    Check 'and runs next' (Until { Pass; (Job $e3.id).state -eq 'done' } 25)

    # inside its cap: nothing happens to the lane
    $f1 = Submit gpu -By ontime -Exe cmd.exe -ArgList $ok -For 'on time' -EstMin 1
    $f2 = Submit gpu -By ontime -Exe cmd.exe -ArgList $ok -For 'its sibling' -EstMin 1
    Check 'on time: done' (Until { (Job $f1.id).state -eq 'done' } 20)
    Check 'on time: its sibling runs' (Until { Pass; (Job $f2.id).state -eq 'done' } 25)
    Free

    # --- a job parked for quiet is in the lane's queue too
    [IO.File]::WriteAllText((Join-Path $D 'fake_gpu.txt'), '9000,90')
    $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $tl submit gpu -By parked -Exe cmd.exe -ArgList $ok -For 'never quiet' -Quiet -EstMin 0.01 -Json -Dir $D 2>&1 | ForEach-Object { "$_" }
    $q1 = ($o -join "`n") | ConvertFrom-Json
    Check 'it parks' (Until { (E gpu $q1.runBy).parked -eq 'quiet' } 30)
    $rp = [int](Job $q1.id).runPid
    $q2 = Submit gpu -By parked -Exe cmd.exe -ArgList $tree -For 'walks past it' -EstMin 0.01
    Check 'one walks past it and runs' (Until { Runs $q2.id } 20)
    PastCap
    Cop
    Check 'a parked job counts as waiting: it goes' ((Job $q2.id).state -eq 'overrun')
    Check 'the parked sibling is cancelled' ((Job $q1.id).state -eq 'cancelled' -and -not (E gpu $q1.runBy))
    Check 'and its runner exits by itself' (Until { -not (Alive $rp) } 15)
    Check 'and took no lease' ((LogText) -notmatch "take gpu $([regex]::Escape($q1.runBy)) until")
    [IO.File]::WriteAllText((Join-Path $D 'fake_gpu.txt'), '500,5')
    Free

    # --- a commandlet or an editor in the tree: never stopped, said once. Its process table is fake, its tree is real.
    $w1 = Submit gpu -By writer -Exe cmd.exe -ArgList $tree -For 'commandlet deep in its tree' -EstMin 0.01
    Check 'commandlet job runs' (Until { Runs $w1.id } 20)
    $wc = [int](Job $w1.id).childPid; $wk = Kid $wc
    $w2 = Submit gpu -By writer -Exe cmd.exe -ArgList $ok -For 'its sibling' -EstMin 0.01
    $w3 = Submit gpu -By writer2 -Exe cmd.exe -ArgList $ok -For 'someone else' -EstMin 0.01
    Table @((Row 'commandlet' $wk $wc), (Row '' $wc 0))
    PastCap
    TL cop -Once -ReapAfterMin 0 -CopDryRun | Out-Null
    Check '-CopDryRun says it would only log' ($last -match 'would log over-cap for job writer\.j1' -and (Said 'over-cap gpu writer') -eq 0)
    Cop
    Check 'a commandlet in the tree: not stopped' ((Job $w1.id).state -eq 'running' -and (Alive $wk))
    Check 'over-cap in lease.log, naming it' ((LogText) -match "over-cap gpu writer\.j1 job \S+ \(commandlet pid $wk in its tree, not stopped")
    Check 'no job-overrun' ((LogText) -notmatch 'job-overrun gpu writer')
    Check 'its lane is left in the queue while it runs' ((Job $w2.id).state -eq 'queued')
    Cop
    Check 'over-cap is said once' ((Said 'over-cap gpu writer\.j1') -eq 1)
    Table $null
    Stop-Process -Id $wk -Force
    Check 'when it ends past its cap on its own, the lane breaks' (Until { (Job $w2.id).state -eq 'cancelled' } 15)
    Check 'and the job keeps its own ending' (Until { (Job $w1.id).state -in @('done', 'failed') } 10)
    Check 'the other lane runs' (Until { Pass; (Job $w3.id).state -eq 'done' } 25)
    Free

    $y1 = Submit gpu -By edit -Exe cmd.exe -ArgList $tree -For 'the command is an editor' -EstMin 0.01
    Check 'editor job runs' (Until { Runs $y1.id } 20)
    Table @(, (Row 'editor' ([int](Job $y1.id).childPid) 0))
    TL take gpu -By yw -EstMin 0.01 | Out-Null
    PastCap
    Cop
    Check 'an editor in the tree: not stopped' ((Job $y1.id).state -eq 'running' -and (LogText) -match 'over-cap gpu edit\.j1 job \S+ \(editor pid')
    Table $null
    TL unqueue gpu -By yw | Out-Null; Tidy $y1.id; Free

    $g1 = Submit gpu -By game -Exe cmd.exe -ArgList $tree -For 'a -game run in its tree' -EstMin 0.01
    Check 'game job runs' (Until { Runs $g1.id } 20)
    $gc = [int](Job $g1.id).childPid; $gk = Kid $gc
    Table @((Row 'game' $gk $gc), (Row '' $gc 0))
    TL take gpu -By gw -EstMin 0.01 | Out-Null
    PastCap
    Cop
    Check 'a -game run in the tree: stopped' ((Job $g1.id).state -eq 'overrun')
    Check 'and it is dead' (Until { -not (Alive $gk) } 8)
    Table $null
    TL unqueue gpu -By gw | Out-Null; Free

    # --- the alarm: a plain take past its cap, someone waiting
    TL take gpu -By al.plain -EstMin 0.01 -Minutes 60 -For 'plain holder' | Out-Null
    TL take gpu -By w1 | Out-Null
    PastCap
    Check 'before the cop, nothing is said' ((Said 'over-cap gpu al') -eq 0)
    TL cop -Once -ReapAfterMin 0 -CopDryRun | Out-Null
    Check 'alarm: -CopDryRun says what it would log' ($last -match "would log over-cap for al\.plain's gpu lease")
    Check 'alarm: -CopDryRun logs nothing, marks nothing, notes nothing' ((Said 'over-cap gpu al') -eq 0 -and -not (L gpu).overCap -and -not (Note 'al'))
    TL cop -Once -ReapAfterMin 0 | Out-Null
    Check 'the cop run says it' ($last -match "over its cap, not stopped: al\.plain's gpu lease")
    Check 'over-cap in lease.log, naming the holder' ((LogText) -match 'over-cap gpu al\.plain \(not stopped: held \d+ min on an estimate of 0\.01 min, past its cap \d\d:\d\d, 1 waiting\)')
    Check 'a plain take is not touched' ((L gpu).by -eq 'al.plain')
    Check 'and marked on its file' ([bool](L gpu).overCap)
    Check 'the holder is told, under its -By root' ((Note 'al') -match 'your gpu lease is past its overrun cap' -and (Note 'al') -match 'Nothing was stopped' -and (Note 'al') -match 'renew gpu -By al\.plain -EstMin')
    Cop
    Check 'said once' ((Said 'over-cap gpu al\.plain') -eq 1)
    # A renew moves the cap and clears the mark, so a new cap can be said again.
    TL renew gpu -By al.plain -EstMin 0.01 | Out-Null
    Check 'a renew clears the mark' (-not (L gpu).overCap)
    Cop
    Check 'inside the new cap: nothing more' ((Said 'over-cap gpu al\.plain') -eq 1)
    PastCap
    Cop
    Check 'past the new cap: said again' ((Said 'over-cap gpu al\.plain') -eq 2)
    TL unqueue gpu -By w1 | Out-Null; TL release gpu -By al.plain | Out-Null

    # No -ScratchDir is the default here: no note, and no error either.
    TL take gpu -By al.noscr -EstMin 0.01 -Minutes 60 | Out-Null
    TL take gpu -By w2 | Out-Null
    PastCap
    $env:THOR_SCRATCH = $null
    try { TL cop -Once -ReapAfterMin 0 | Out-Null } finally { $env:THOR_SCRATCH = $scr }
    Check 'no -ScratchDir: said, and no error' ((Said 'over-cap gpu al\.noscr') -eq 1 -and $last -notmatch 'pass failed')
    TL unqueue gpu -By w2 | Out-Null; TL release gpu -By al.noscr | Out-Null

    # Inside its cap, or nobody waiting: quiet.
    TL take gpu -By al.long -EstMin 30 -Minutes 60 | Out-Null
    TL take gpu -By w3 | Out-Null
    Cop
    Check 'inside its cap: nothing' ((Said 'over-cap gpu al\.long') -eq 0)
    TL unqueue gpu -By w3 | Out-Null; TL release gpu -By al.long | Out-Null
    TL take editor -By al.lone -EstMin 0.01 -Minutes 60 | Out-Null
    PastCap editor
    Cop
    Check 'nobody waiting: nothing' ((Said 'over-cap editor al\.lone') -eq 0)
    TL take editor -By w4 | Out-Null
    Cop
    Check 'someone queues: said on the next pass, on the editor lease too' ((Said 'over-cap editor al\.lone \(not stopped') -eq 1)
    TL unqueue editor -By w4 | Out-Null; TL release editor -By al.lone | Out-Null

    # -CopMatch: a job's command, else the holder's name and -For.
    TL take build -By al.miss -EstMin 0.01 -Minutes 60 -For 'thing one' | Out-Null
    TL take build -By w5 | Out-Null
    PastCap build
    Cop -CopMatch 'no-such-text'
    Check 'alarm: -CopMatch that misses: nothing' ((Said 'over-cap build al\.miss') -eq 0)
    Cop -CopMatch 'thing one'
    Check 'alarm: -CopMatch on the -For text: said' ((Said 'over-cap build al\.miss') -eq 1)
    TL unqueue build -By w5 | Out-Null; TL release build -By al.miss | Out-Null

    # run: a real command under it, never stopped.
    $rn = Bg run -Lease gpu -By al.run -NoQuiet -EstMin 0.01 -Exe cmd.exe -ArgList $tree
    Check 'run holds the lease and started its command' (Until { (L gpu).by -eq 'al.run' -and (L gpu).childPid } 25)
    TL take gpu -By w6 | Out-Null
    PastCap
    $rc0 = [int](L gpu).childPid
    Cop
    Check 'run past its cap: said' ((Said 'over-cap gpu al\.run \(not stopped') -eq 1)
    Check 'run is not stopped' ((Alive $rn.Id) -and (Alive $rc0) -and (L gpu).by -eq 'al.run')
    Check 'its child stays tied to the lease' ([int](L gpu).childPid -eq $rc0)
    & taskkill.exe /T /F /PID $rc0 2>&1 | Out-Null
    Check 'when its command ends, run lets go' (Until { -not (L gpu) -or (L gpu).by -ne 'al.run' } 15)
    TL unqueue gpu -By w6 | Out-Null; TL release gpu -By w6 | Out-Null

    # hold: its caller's script must live.
    $hf = Join-Path $Work 'hold.pid'
    $hp = Start-Process $Shell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$holder`"", '-Tl', "`"$tl`"", '-Dir', "`"$D`"", '-By', 'al.hold', '-PidFile', "`"$hf`"" -PassThru -WindowStyle Hidden
    $null = $hp.Handle; $script:bgs += $hp
    Check 'hold holds the lease' (Until { (L gpu).by -eq 'al.hold' -and (Test-Path $hf) } 25)
    TL take gpu -By w7 | Out-Null
    PastCap
    Cop
    Check 'hold past its cap: said' ((Said 'over-cap gpu al\.hold \(not stopped') -eq 1)
    Check 'the holding script is not stopped' ((Alive $hp.Id) -and (L gpu).by -eq 'al.hold')
    Stop-Process -Id $hp.Id -Force -ErrorAction SilentlyContinue
    [void](Until { -not (Alive $hp.Id) } 10)
    TL unqueue gpu -By w7 | Out-Null
    TL release gpu -By al.hold -Force | Out-Null

    # Jobs on the editor and build leases: said with the job's id, never stopped.
    $ee = Submit editor -By al.ed -Exe cmd.exe -ArgList $tree -For 'editor lease job' -EstMin 0.01
    $bb = Submit build -By al.bd -Exe cmd.exe -ArgList $tree -For 'build lease job' -EstMin 0.01
    Check 'editor and build jobs run' (Until { (Runs $ee.id) -and (Runs $bb.id) } 25)
    TL take editor -By w8 | Out-Null; TL take build -By w9 | Out-Null
    PastCap editor; PastCap build
    Cop
    Check 'the editor job is said, with its id' ((LogText) -match "over-cap editor al\.ed\.j1 job $([regex]::Escape($ee.id)) \(not stopped")
    Check 'the build job is said, with its id' ((LogText) -match "over-cap build al\.bd\.j1 job $([regex]::Escape($bb.id)) \(not stopped")
    Check 'neither is stopped' ((Job $ee.id).state -eq 'running' -and (Job $bb.id).state -eq 'running' -and (Alive ([int](Job $ee.id).childPid)) -and (Alive ([int](Job $bb.id).childPid)))
    Check 'no job-overrun off the gpu lease' ((Said 'job-overrun (editor|build)') -eq 0)
    Check 'and their dispatch lines carry no cap' ((LogText) -notmatch 'dispatch (editor|build) \S+ job \S+ cap')
    # A job being stopped is not over its cap any more: its lease can outlive the stop by a moment.
    SetJob $ee.id 'cancelled'
    TL renew editor -By $ee.runBy -EstMin 0.01 | Out-Null
    PastCap editor
    $was = Said 'over-cap editor al\.ed'
    Cop
    Check 'a job being stopped raises nothing' ((Said 'over-cap editor al\.ed') -eq $was)
    SetJob $ee.id 'running'
    TL unqueue editor -By w8 | Out-Null; TL unqueue build -By w9 | Out-Null
    $ec = [int](Job $ee.id).childPid
    TL job -JobId $ee.id -Cancel | Out-Null
    Check 'job -Cancel: cancelled, tree dead, lease gone' ((Job $ee.id).state -eq 'cancelled' -and -not (Alive $ec) -and (Until { -not (L editor) } 8))
    Tidy $bb.id; Free build

    # An editor-lease job that ends late doesn't break a lane.
    $s1 = Submit editor -By edl -Exe cmd.exe -ArgList $slow -For 'late, on the editor lease' -EstMin 0.01
    Check 'editor job runs' (Until { (Job $s1.id).state -eq 'running' } 20)
    $s2 = Submit editor -By edl -Exe cmd.exe -ArgList $ok -For 'its sibling' -EstMin 0.01
    Check 'no breaker off the gpu lease' ((Until { Pass; (Job $s2.id).state -eq 'done' } 40) -and (Job $s1.id).state -eq 'done')
    Free editor

    # A gpu job is the cap's own, stopped or said by it, not by the alarm.
    $g2 = Submit gpu -By al.gj -Exe cmd.exe -ArgList $tree -For 'gpu job' -EstMin 0.01
    Check 'gpu job runs' (Until { Runs $g2.id } 25)
    TL take gpu -By w10 | Out-Null
    PastCap
    $env:THOR_TEST_ALARM = '1'; try { TL status | Out-Null } finally { $env:THOR_TEST_ALARM = $null }
    Check 'the alarm leaves a running gpu job to the cap' ((Said 'over-cap gpu al\.gj') -eq 0)
    SetJob $g2.id 'overrun'
    $env:THOR_TEST_ALARM = '1'; try { TL status | Out-Null } finally { $env:THOR_TEST_ALARM = $null }
    Check 'and raises nothing on one the cap just stopped' ((Said 'over-cap gpu al\.gj') -eq 0)
    SetJob $g2.id 'running'
    Cop
    Check 'the cap stops it' ((Job $g2.id).state -eq 'overrun' -and (Said 'job-overrun gpu al\.gj') -eq 1)
    Check 'with no alarm beside it' ((Said 'over-cap gpu al\.gj') -eq 0)
    TL unqueue gpu -By w10 | Out-Null; Free

    # The watch board's cop runs the alarm too, and re-reads the leases only when a pass changed them.
    TL take gpu -By al.board -EstMin 0.01 -Minutes 60 | Out-Null
    TL take gpu -By w11 | Out-Null
    PastCap
    $env:THOR_TEST_BOARD = '1'; try { TL status -ReapAfterMin 0 | Out-Null } finally { $env:THOR_TEST_BOARD = $null }
    Check 'the watch board''s cop says it too' ((Said 'over-cap gpu al\.board \(not stopped') -eq 1)
    TL unqueue gpu -By w11 | Out-Null; TL release gpu -By al.board | Out-Null
    $env:THOR_TEST_READS = '1'; try { TL status -ReapAfterMin 10 | Out-Null } finally { $env:THOR_TEST_READS = $null }
    Check 'nothing to do: the board reads the leases once' ($last -match 'reads=1\b')

    # --- as shipped the lane breaker is off: a stopped job loses only itself, and its lane's queued jobs each take their turn
    $tl = $tlOff
    $rc = TL submit gpu -By off.a -Exe cmd.exe -ArgList $tree -For 'sleeps past its cap' -NoQuiet -EstMin 0.01
    Check 'breaker off: submit promises no cancelling' ($rc -eq 0 -and $last -match 'the cop stops it;' -and $last -notmatch 'cancels its lane')
    $oaId = ([regex]::Match($last, 'job (off\.a\.j1-[^\s:]+)')).Groups[1].Value
    Check 'breaker off: it runs' (Until { Runs $oaId } 20)
    $oSib = Submit gpu -By off.a -Exe cmd.exe -ArgList $ok -For 'sibling' -EstMin 0.01
    PastCap
    TL cop -Once -ReapAfterMin 0 -CopDryRun | Out-Null
    Check 'breaker off: -CopDryRun would cancel nobody' ($last -match 'would stop job off\.a\.j1' -and $last -notmatch 'and cancel')
    Cop
    Check 'breaker off: the job is stopped at its cap' ((Job $oaId).state -eq 'overrun')
    Check 'breaker off: its sibling stays' ((Job $oSib.id).state -ne 'cancelled')
    Check 'and takes its turn' (Until { Pass; (Job $oSib.id).state -eq 'done' } 25)
    Check 'breaker off: no job-cancel lines' ((Said 'job-cancel gpu off') -eq 0)
    Check 'breaker off: the note says it stopped, and nothing about lost jobs' ((Note 'off') -match "stopped your job $([regex]::Escape($oaId))" -and (Note 'off') -notmatch 'cancelled your queued')
    Free
    $ob = Submit gpu -By off.b -Exe cmd.exe -ArgList $slow -For 'ends late by itself' -EstMin 0.01
    Check 'breaker off: late job runs' (Until { (Job $ob.id).state -eq 'running' } 20)
    $obs = Submit gpu -By off.b -Exe cmd.exe -ArgList $ok -For 'its sibling' -EstMin 0.01
    Check 'breaker off: it ends past its cap on its own' (Until { (Job $ob.id).state -eq 'done' } 30)
    Check 'and its sibling still runs' (Until { Pass; (Job $obs.id).state -eq 'done' } 25)
    Check 'breaker off: still no job-cancel lines' ((Said 'job-cancel gpu off') -eq 0)
    Free
    $tl = $tlOn

    # --- what the cap leaves alone
    TL take gpu -By fake.j1 -EstMin 0.01 -Minutes 60 | Out-Null
    TL take gpu -By w12 | Out-Null
    PastCap
    Cop
    Check 'a plain take whose name only looks like a job is not touched' ((L gpu).by -eq 'fake.j1')
    TL unqueue gpu -By w12 | Out-Null; TL release gpu -By fake.j1 | Out-Null

    # --- the queue's math past an estimate
    TL take gpu -By mh -EstMin 60 -Minutes 600 | Out-Null
    TL take gpu -By mw | Out-Null
    function Start-In { TL status -Json | Out-Null; $js = $last | ConvertFrom-Json; return ((U (@($js.queues.gpu)[0]).start) - [DateTime]::UtcNow).TotalMinutes }
    function Check-In { TL take gpu -By mw | Out-Null; return ((U (E gpu mw).nextCheck) - [DateTime]::UtcNow).TotalMinutes }
    $now0 = [DateTime]::UtcNow
    Check 'inside its estimate: the estimate' ([Math]::Abs((Start-In) - 60) -lt 0.5)
    # cap = eta + est + pad: 10 min past a 60-minute estimate leaves 50.1 to the cap, so half of that.
    SetLease gpu @{ eta = Iso $now0.AddMinutes(-10) }
    Check 'past its estimate: half the time left to its cap' ([Math]::Abs((Start-In) - 25.05) -lt 0.5)
    Check 'the check-back stays at 10 min' ([Math]::Abs((Check-In) - 10) -lt 0.5)
    # 55 min past: 5.1 to the cap, half is 2.55, so the floor.
    SetLease gpu @{ eta = Iso $now0.AddMinutes(-55) }
    Check 'close to the cap: the floor of 5' ([Math]::Abs((Start-In) - 5) -lt 0.5)
    Check 'the check-back follows it' ([Math]::Abs((Check-In) - 5) -lt 0.5)
    SetLease gpu @{ eta = Iso $now0.AddMinutes(-100) }
    Check 'past the cap: the floor of 5' ([Math]::Abs((Start-In) - 5) -lt 0.5)
    SetLease gpu @{ eta = Iso $now0.AddMinutes(-10); until = Iso $now0.AddMinutes(3) }
    Check 'never past its expiry' ([Math]::Abs((Start-In) - 3) -lt 0.5)
    SetLease gpu @{ until = Iso $now0.AddMinutes(300) }
    TL watch -Once | Out-Null
    Check 'the plain board still draws' ($last -match 'GPU\s+mh')
    TL unqueue gpu -By mw | Out-Null; TL release gpu -By mh | Out-Null

    # --- a lease with no eta has no cap
    TL take gpu -By noeta -EstMin 0.01 -Minutes 60 | Out-Null
    $p = Join-Path $D 'leases\gpu.json'; $o = Get-Content $p -Raw | ConvertFrom-Json; $o.PSObject.Properties.Remove('eta'); [IO.File]::WriteAllText($p, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    TL take gpu -By noeta2 | Out-Null
    $rc = TL status
    Check 'a lease with no eta plans from its expiry and breaks nothing' ($rc -eq 0)
    Cop
    Check 'and the cop leaves it and says nothing' ((L gpu).by -eq 'noeta' -and (Said 'over-cap gpu noeta') -eq 0)
    TL unqueue gpu -By noeta2 | Out-Null; TL release gpu -By noeta | Out-Null
} catch {
    $script:fail++; Write-Host "FAIL the suite stopped: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    # Nothing this test started outlives it.
    foreach ($b in $script:bgs) { Stop-Process -Id $b.Id -Force -ErrorAction SilentlyContinue }
    foreach ($f in @(Get-ChildItem (Join-Path $D 'jobs') -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json; if ($j.childPid -and (Get-Process -Id ([int]$j.childPid) -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'cmd' })) { & taskkill.exe /T /F /PID ([int]$j.childPid) 2>&1 | Out-Null } } catch {}
    }
    $stubName = [regex]::Escape($Work)
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' or Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match $stubName })) { Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue }
    $env:THOR_SCRATCH = $null
    if (-not $Keep) { Start-Sleep -Seconds 1; Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ""
Write-Host "cap: $($script:pass) passed, $($script:fail) failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
