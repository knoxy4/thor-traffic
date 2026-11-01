# quiet-wait-tests.ps1 - a wait for a quiet GPU holds nothing and keeps nothing for itself ("Standing aside" in thor.ps1).
# Runs a copy of thor.ps1 with the GPU reading and the process list stubbed, in a throwaway state dir, so it needs no GPU
# and can move the card from noisy to quiet under a waiter that is already running.
# Usage: pwsh tests\quiet-wait-tests.ps1 [-Shell pwsh|powershell] [-Tool <path to thor.ps1>] [-Keep]
param([string]$Shell = 'pwsh', [string]$Tool = (Join-Path (Split-Path -Parent $PSScriptRoot) 'thor.ps1'), [switch]$Keep)
$ErrorActionPreference = 'Stop'
$Work = Join-Path ([IO.Path]::GetTempPath()) ("thor-quiet-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$D = Join-Path $Work 'state'
New-Item -ItemType Directory -Force $D | Out-Null
$tl = Join-Path $Work 'thor_stub.ps1'
$stub = @'
# ---- test stubs ----
function Get-Gpu([int]$Samples = 3) { $v = ([IO.File]::ReadAllText((Join-Path $Dir 'fake_gpu.txt'))).Trim() -split ','; [pscustomobject]@{ usedMB = [int]$v[0]; totalMB = 12288; util = [int]$v[1] } }
function Get-Procs { $f = Join-Path $Dir 'fake_procs.json'; if (Test-Path $f) { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json; return @($o) }; return @() }
if ($script:BoundKeys -notcontains 'SettleSec') { $SettleSec = 3 }
if ($env:THOR_TEST_PASS) { [void](Dispatch-Pass); exit 0 }

'@
$src = [IO.File]::ReadAllText((Resolve-Path $Tool).Path)
$mark = '# ---- verbs ---'
if ($src.IndexOf($mark) -lt 0) { throw 'no verbs marker in the tool' }
[IO.File]::WriteAllText($tl, $src.Replace($mark, $stub + $mark), (New-Object Text.UTF8Encoding $true))

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
function Noisy { [IO.File]::WriteAllText((Join-Path $D 'fake_gpu.txt'), '9000,90') }
function Calm { [IO.File]::WriteAllText((Join-Path $D 'fake_gpu.txt'), '500,5') }
function Procs($Json) { $f = Join-Path $D 'fake_procs.json'; if ($Json) { [IO.File]::WriteAllText($f, $Json) } elseif (Test-Path $f) { Remove-Item $f -Force } }
function Pass { $env:THOR_TEST_PASS = '1'; try { & $Shell -NoProfile -ExecutionPolicy Bypass -File $tl status -Dir $D *> $null } finally { $env:THOR_TEST_PASS = $null } }
function Until([scriptblock]$Cond, [int]$Sec = 25) { $t = [DateTime]::UtcNow.AddSeconds($Sec); while ([DateTime]::UtcNow -lt $t) { try { if (& $Cond) { return $true } } catch {}; Start-Sleep -Milliseconds 400 }; return $false }
function Job($id) { $p = Join-Path $D "jobs\$id.json"; try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null } }
function Submit { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $tl submit @args -Json -Dir $D 2>&1 | ForEach-Object { "$_" }; $script:last = $o -join "`n"; return ($script:last | ConvertFrom-Json) }
function LogText { $p = Join-Path $D 'lease.log'; if (Test-Path $p) { Get-Content $p -Raw } else { '' } }
function Tidy($id) { if ($id) { TL job -JobId $id -Cancel | Out-Null } }
$ok = '/c exit 0'; $exit7 = '/c exit 7'; $slow = '/c ping -n 7 127.0.0.1 >nul'

try {
    # --- run
    Noisy
    $a = Bg run gpu -By a -Exe cmd.exe -ArgList $exit7 -EstMin 9 -TimeoutMin 2 -SettleSec 6
    Check 'run on a noisy GPU stands aside' (Until { (E gpu a).parked -eq 'quiet' })
    Check 'no lease held while it waits for quiet' (-not (L gpu))
    TL status | Out-Null
    Check 'status says it stands aside' ($last -match 'a .*stands aside')
    TL status -Json | Out-Null
    Check 'status -Json carries parked' (@(($last | ConvertFrom-Json).queues.gpu)[0].parked -eq 'quiet')
    TL watch -Once | Out-Null
    Check 'plain board shows gpu free, not kept' ($last -match 'GPU\s+free' -and $last -notmatch 'kept for a')
    Check 'a plain take walks past it' ((TL take gpu -By b) -eq 0)
    Check 'it keeps its place behind the new holder' ([bool](E gpu a))
    TL release gpu -By b | Out-Null
    Check 'a release keeps nothing for a parked waiter' ($last -notmatch 'kept for')
    Calm
    Check 'it unparks once the GPU is quiet' (Until { $e = E gpu a; $e -and -not $e.parked })
    $rc = TL take gpu -By c
    Check 'while it settles the lease is kept for it' ($rc -eq 2 -and $last -match 'kept for a')
    TL unqueue gpu -By c | Out-Null
    $a.WaitForExit(40000) | Out-Null
    Check 'run took the lease, ran, returned the exit code' ($a.HasExited -and $a.ExitCode -eq 7)
    Check 'run left no lease and no queue place' (-not (L gpu) -and -not (E gpu a))
    Check 'the take is in the log' ((LogText) -match 'take gpu a until')

    # --- a parked waiter gets its place back from a no-show behind it
    Noisy
    $a3 = Bg run gpu -By a3 -Exe cmd.exe -ArgList $ok -TimeoutMin 2 -SettleSec 3
    Check 'a3 parks' (Until { (E gpu a3).parked -eq 'quiet' })
    TL take gpu -By x1 | Out-Null
    $rc = TL take gpu -By w1
    Check 'a no-show queues behind it' ($rc -eq 2 -and [bool](E gpu w1))
    TL release gpu -By x1 | Out-Null
    Check 'the lease is kept for the no-show while a3 stands aside' ($last -match 'kept for w1')
    Calm
    $a3.WaitForExit(30000) | Out-Null
    Check 'quiet: a3 reclaims its place and runs anyway' ($a3.HasExited -and $a3.ExitCode -eq 0 -and (LogText) -match 'take gpu a3 until')
    TL unqueue gpu -By w1 | Out-Null

    # --- hold
    Noisy
    $hc = Join-Path $Work 'hold_child.ps1'
    Set-Content $hc "& '$tl' hold gpu -By h -For 'x' -EstMin 9 -TimeoutMin 2 -SettleSec 3 -Dir '$D'; `$c = `$LASTEXITCODE; Start-Sleep 6; exit `$c"
    $h = Start-Process $Shell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$hc`"" -PassThru -WindowStyle Hidden; $null = $h.Handle; $script:bgs += $h
    Check 'hold on a noisy GPU stands aside' (Until { (E gpu h).parked -eq 'quiet' })
    Check 'no lease held by hold' (-not (L gpu))
    $quietAt = [DateTime]::UtcNow
    Calm
    Check 'hold gets the lease once settled' (Until { (L gpu).by -eq 'h' })
    $lh = L gpu
    $tk = [DateTime]::Parse([string]$lh.taken, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    Check 'the lease clock starts after the wait, not before' ($tk -ge $quietAt.AddSeconds(-1))
    Check 'the lease is tied to the calling process' ([int]$lh.pid -eq $h.Id)
    $h.WaitForExit(20000) | Out-Null
    Check 'hold returned 0' ($h.ExitCode -eq 0)
    Noisy
    $rc = TL hold gpu -By g -TimeoutMin 0.1 -SettleSec 3
    Check 'never quiet: exit 3, no lease, no queue place' ($rc -eq 3 -and (L gpu).by -ne 'g' -and -not (E gpu g))
    $rc = TL hold gpu -By g2 -NoQuiet -HolderPid $PID
    Check 'hold -NoQuiet takes it at once' ($rc -eq 0 -and $last -match 'gpu held: g2')
    TL release gpu -By g2 | Out-Null

    # --- a holder that then waits for quiet gives its lease back
    Noisy
    TL take gpu -By z -EstMin 3 | Out-Null
    $z = Bg run gpu -By z -Exe cmd.exe -ArgList $ok -TimeoutMin 2 -SettleSec 3
    Check 'its own lease is let go while it waits' (Until { -not (L gpu) -and (E gpu z).parked -eq 'quiet' })
    Calm
    $z.WaitForExit(30000) | Out-Null
    Check 'and it still runs when quiet' ($z.ExitCode -eq 0 -and -not (L gpu))

    # --- jobs
    Noisy
    $j1 = Submit gpu -By j -Exe cmd.exe -ArgList $ok -For 'quiet job' -EstMin 5
    Check 'a quiet job on a noisy GPU stands aside' (Until { (E gpu $j1.runBy).parked -eq 'quiet' })
    Check 'it holds no lease' (-not (L gpu))
    Check 'the job says what it waits on' (Until { (Job $j1.id).waiting -match 'quiet' })
    TL job -JobId $j1.id | Out-Null
    Check 'job shows [waits: ...]' ($last -match 'waits:')
    $j2 = Submit gpu -By k -Exe cmd.exe -ArgList $slow -For 'no quiet' -NoQuiet -EstMin 1
    Check 'a -NoQuiet job behind it starts at once' (Until { (Job $j2.id).state -in @('running', 'done') } 15)
    Check 'and holds the lease itself' (Until { (L gpu).by -eq $j2.runBy -or (Job $j2.id).state -eq 'done' } 5)
    Check 'the -NoQuiet job finishes' (Until { (Job $j2.id).state -eq 'done' } 30)
    $j3 = Submit gpu -By m -Exe cmd.exe -ArgList $ok -For 'second quiet job' -EstMin 5
    Pass
    Check 'a second quiet job waits behind the first, no runner' ((Job $j3.id).state -eq 'queued' -and -not (Job $j3.id).runPid)
    Check 'a plain take walks past both' ((TL take gpu -By n) -eq 0)
    TL release gpu -By n | Out-Null
    Calm
    Check 'quiet: the first job runs and finishes' (Until { (Job $j1.id).state -eq 'done' } 40)
    Check 'it held the lease to run' ((LogText) -match "take gpu $([regex]::Escape($j1.runBy)) until")
    Check 'then the second' (Until { Pass; (Job $j3.id).state -eq 'done' } 50)

    # cancel while parked
    Noisy
    $j4 = Submit gpu -By p -Exe cmd.exe -ArgList $ok -For 'to cancel' -EstMin 5
    Check 'job parks (cancel case)' (Until { (E gpu $j4.runBy).parked -eq 'quiet' })
    TL job -JobId $j4.id -Cancel | Out-Null
    Check 'cancelled, no queue place, no lease' ((Job $j4.id).state -eq 'cancelled' -and -not (E gpu $j4.runBy) -and -not (L gpu))
    Check 'it never took the lease' ((LogText) -notmatch "take gpu $([regex]::Escape($j4.runBy)) until")

    # runner killed while parked
    $j5 = Submit gpu -By r -Exe cmd.exe -ArgList $ok -For 'to kill' -EstMin 5
    Check 'job parks (kill case)' (Until { (E gpu $j5.runBy).parked -eq 'quiet' })
    $rp = [int](Job $j5.id).runPid
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$rp" -ErrorAction SilentlyContinue)) { Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $rp -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Check 'a killed runner leaves nothing in the way' ((TL take gpu -By s) -eq 0)
    TL release gpu -By s | Out-Null
    Check 'a killed runner reads as lost' (Until { Pass; (Job $j5.id).state -eq 'lost' } 45)
    Check 'and its place is gone' (-not (E gpu $j5.runBy))

    # timed out on quiet
    $j6 = Submit gpu -By t -Exe cmd.exe -ArgList $ok -For 'times out' -EstMin 1 -TimeoutMin 0.1
    Check 'a job that never gets quiet fails with why, no lease' (Until { (Job $j6.id).state -eq 'failed' -and (Job $j6.id).why -match 'quiet' } 30)
    Check 'no lease and no place left behind' (-not (L gpu) -and -not (E gpu $j6.runBy))

    # --- submit carries quiet's switches
    Calm
    Procs '[{"kind":"editor","cpp":false,"pid":5,"name":"UnrealEditor.exe","cmd":"x","full":"UnrealEditor.exe Other.uproject","started":"2026-01-01T00:00:00Z"}]'
    $s1 = Submit gpu -By sa -Exe cmd.exe -ArgList $ok -For 'strict' -EstMin 1
    Check 'a plain quiet job parks on an open editor' (Until { (E gpu $s1.runBy).parked -eq 'quiet' })
    $s2 = Submit gpu -By sb -Exe cmd.exe -ArgList $ok -For 'allows the editor' -AllowEditor -EstMin 1
    Check 'submit records -AllowEditor on the job' ((Job $s2.id).allowEditor -eq $true)
    Check 'that job goes past the parked one and runs with the editor open' (Until { (Job $s2.id).state -eq 'done' } 25)
    $s3 = Submit gpu -By sc -Exe cmd.exe -ArgList $ok -For 'same as strict' -EstMin 1
    Pass
    Check 'a job with the parked one''s switches waits unstarted' ((Job $s3.id).state -eq 'queued' -and -not (Job $s3.id).runPid)
    Tidy $s1.id; Tidy $s3.id
    Procs '[{"kind":"build","cpp":false,"pid":6,"name":"cargo.exe","cmd":"x","full":"cargo.exe build","started":"2026-01-01T00:00:00Z"}]'
    $s5 = Submit gpu -By se -Exe cmd.exe -ArgList $ok -For 'allows builds' -AllowBuild -EstMin 1
    Check '-AllowBuild runs with cargo going' (Until { (Job $s5.id).state -eq 'done' } 25)
    Procs ''
    Noisy
    $s4 = Submit gpu -By sd -Exe cmd.exe -ArgList $ok -For 'loose gates' -MaxVramGB 10 -MaxUtil 95 -SettleSec 1 -EstMin 1
    Check '-MaxVramGB and -MaxUtil let it run on this card' (Until { (Job $s4.id).state -eq 'done' } 25)
    $js4 = Job $s4.id
    Check 'the job file keeps its gates and settle' ([double]$js4.maxVramGB -eq 10 -and [int]$js4.maxUtil -eq 95 -and [int]$js4.settleSec -eq 1)

    # a job queued by an older version has no quiet fields and keeps the defaults
    $oid = 'old.j1-0101-000000'; $oby = 'old.j1'; $iso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); $late = [DateTime]::UtcNow.AddMinutes(30).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $oj = [ordered]@{ id = $oid; by = 'old'; runBy = $oby; lease = 'gpu'; note = 'old format'; est = 1; exe = (Get-Command cmd.exe).Source; args = $ok; cwd = $Work; noQuiet = $false; timeoutMin = 2
        state = 'queued'; why = ''; submitted = $iso; started = $null; ended = $null; exit = $null; runPid = $null; childPid = $null; log = (Join-Path $D "jobs\$oid.log"); out = (Join-Path $D "jobs\$oid.out.log"); err = (Join-Path $D "jobs\$oid.err.log") }
    $u8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $D "jobs\$oid.json"), ($oj | ConvertTo-Json), $u8)
    $oq = @{ entries = @([ordered]@{ by = $oby; note = 'old format'; est = 1; joined = $iso; nextCheck = $late; until = $late; pid = $null; pidStart = $null; job = $oid }) }
    [IO.File]::WriteAllText((Join-Path $D 'queue\gpu.json'), ($oq | ConvertTo-Json -Depth 5), $u8)
    Pass
    Check 'an old-format job parks on the default gates' (Until { (E gpu $oby).parked -eq 'quiet' })
    Calm
    Check 'and runs once quiet' (Until { (Job $oid).state -eq 'done' } 30)

    # --- other leases: jobs still wait for quiet (it's what keeps a build off an open editor); hold never did
    Noisy
    $b2 = Submit build -By ba -Exe cmd.exe -ArgList $ok -For 'build, no switch' -EstMin 1
    Check 'a build job waits for quiet, standing aside' (Until { (E build $b2.runBy).parked -eq 'quiet' } 15)
    Check 'holding no build lease' (-not (L build))
    Tidy $b2.id
    $b3 = Submit build -By bb -Exe cmd.exe -ArgList $ok -For 'build, -NoQuiet' -NoQuiet -EstMin 1
    Check 'with -NoQuiet it goes at once' (Until { (Job $b3.id).state -eq 'done' } 15)
    $rc = TL hold build -By bc -HolderPid $PID
    Check 'hold on the build lease does not wait for quiet' ($rc -eq 0)
    TL release build -By bc | Out-Null

    # --- the colour board
    $a2 = Bg run gpu -By a2 -Exe cmd.exe -ArgList $ok -TimeoutMin 1 -SettleSec 3
    [void](Until { (E gpu a2).parked -eq 'quiet' })
    $frame = (& $Shell -NoProfile -ExecutionPolicy Bypass -File $tl watch -Frame -Cols 150 -Rows 50 -Dir $D 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $plain = $frame -replace "\x1b\[[0-9;?]*[A-Za-z]", ''
    $script:last = $plain
    Check 'colour board: gpu FREE, not KEPT' ($plain -match 'GPU\s+.*FREE' -and $plain -notmatch 'GPU\s+.*KEPT')
    Check 'colour board: the waiter says it stands aside' ($plain -match 'a2 .*aside')
    Stop-Process -Id $a2.Id -Force -ErrorAction SilentlyContinue
} finally {
    foreach ($b in $script:bgs) { Stop-Process -Id $b.Id -Force -ErrorAction SilentlyContinue }
    $stubName = [regex]::Escape($tl)
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' or Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match $stubName })) { Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $Keep) { Start-Sleep -Seconds 1; Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ""
Write-Host "quiet wait: $($script:pass) passed, $($script:fail) failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
