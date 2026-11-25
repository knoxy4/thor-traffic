# fix-tests.ps1 - regression tests for the bug-hunt fixes (bug_hunts\thor-traffic_2026-11-23.md), each in a throwaway state dir.
# Needs no GPU and runs no cop. Usage: pwsh tests\fix-tests.ps1 [-Shell pwsh|powershell]
param([string]$Shell = 'pwsh')
$ErrorActionPreference = 'Stop'
$env:THOR_PROFILE = 'builtin'
$root = Split-Path -Parent $PSScriptRoot
$thor = Join-Path $root 'thor.ps1'
$mcp = Join-Path $root 'mcp\thor-mcp.ps1'
$base = Join-Path ([IO.Path]::GetTempPath()) ("thor-fix-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($base)
$pass = 0; $fail = 0; $D = ''; $sleepers = @()
function New-Dir([string]$Name) { $p = Join-Path $base $Name; [void][IO.Directory]::CreateDirectory($p); return $p }
function T { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $thor @args -Dir $script:D 2>&1 | ForEach-Object { "$_" }; $script:out = $o -join "`n"; return $LASTEXITCODE }
function TD([string]$Dir) { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $thor @args -Dir $Dir 2>&1 | ForEach-Object { "$_" }; $script:out = $o -join "`n"; return $LASTEXITCODE }
function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red; Write-Host ($script:out -split "`n" | Select-Object -First 15 | Out-String) }
}
function Status { (& $Shell -NoProfile -File $thor status -Json -Dir $script:D | ConvertFrom-Json) }
function Job([string]$Id, [string]$Dir = $script:D) { (& $Shell -NoProfile -File $thor job -JobId $Id -Json -Dir $Dir | ConvertFrom-Json) }
function Wait-Job([string]$Id, [string[]]$States, [int]$Sec = 40, [string]$Dir = $script:D) {
    $t = [DateTime]::UtcNow.AddSeconds($Sec)
    while ([DateTime]::UtcNow -lt $t) { $j = Job $Id $Dir; if ([string]$j.state -in $States) { return $j }; Start-Sleep -Milliseconds 700 }
    return (Job $Id $Dir)
}
function LastId { if ($script:out -match 'job -JobId (\S+)') { return $Matches[1] }; return '' }
function Iso([DateTime]$T) { $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Stamp([int]$P) { [string](Get-Process -Id $P).StartTime.ToUniversalTime().Ticks }
function Put([string]$Path, $Obj) { [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
function Sleeper { $p = Start-Process ping -ArgumentList '-n 120 127.0.0.1' -WindowStyle Hidden -PassThru; $script:sleepers += $p; return $p }
function Mcp([string]$Dir, [object[]]$Calls) {
    $lines = @('{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}')
    $i = 1; foreach ($c in $Calls) { $lines += (@{ jsonrpc = '2.0'; id = $i; method = 'tools/call'; params = $c } | ConvertTo-Json -Depth 6 -Compress); $i++ }
    $r = ($lines -join "`n") | pwsh -NoProfile -File $mcp -Dir $Dir   # the MCP server is PowerShell 7 only (its header)
    return @($r | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.id -ge 1 } | Sort-Object id)
}
try {
    # F1: a waiter's own look keeps the priority its job gave it
    $script:D = New-Dir 'prio'
    [void](T take gpu -By h -EstMin 30)
    $now = [DateTime]::UtcNow
    Put (Join-Path $D 'queue\gpu.json') @{ entries = @(
        @{ by = 'b.j1'; note = ''; est = 10; joined = $now.AddMinutes(-10).ToString('o'); nextCheck = Iso $now.AddMinutes(60); until = Iso $now.AddMinutes(60); prio = 0 },
        @{ by = 'a.j1'; note = ''; est = 10; joined = $now.AddMinutes(-5).ToString('o'); nextCheck = Iso $now.AddMinutes(60); until = Iso $now.AddMinutes(60); prio = 5 }) }
    [void](T take gpu -By a.j1 -EstMin 10)
    $q = @((Status).queues.gpu)
    Check 'F1 a refresh keeps -Priority first' ($q[0].by -eq 'a.j1' -and [int]$q[0].prio -eq 5)
    Check 'F1 its place says #1' ($out -match '#1 of 2')

    # F2: a no-show is dequeued once, not on every look
    $script:D = New-Dir 'dequeue'
    [void](T take build -By h2 -EstMin 30)
    Put (Join-Path $D 'queue\build.json') @{ entries = @(@{ by = 'w'; est = 5; joined = $now.AddMinutes(-30).ToString('o'); nextCheck = Iso $now.AddMinutes(-20); until = Iso $now.AddMinutes(-15) }) }
    1..3 | ForEach-Object { [void](T take build -By z -NoQueue) }
    $n = @(Get-Content -LiteralPath (Join-Path $D 'lease.log') | Where-Object { $_ -match 'dequeue build w' }).Count
    $script:out = "dequeue lines: $n"
    Check 'F2 one dequeue line for one no-show' ($n -eq 1)

    # F3: the holder's plain take keeps its pid tie
    $script:D = New-Dir 'tie'
    [void](T take editor -By p -HolderPid $PID)
    [void](T take editor -By p)
    $l = (Status).leases.editor.lease
    Check 'F3 take again keeps the pid tie' ([int]$l.pid -eq $PID -and $l.pidStart)

    # F7: a run's lease past its expiry stays live while its command runs
    $script:D = New-Dir 'lapse'
    [void](T status)
    $hp = Sleeper; $ch = Sleeper
    Put (Join-Path $D 'leases\gpu.json') ([ordered]@{ lease = 'gpu'; by = 'r'; note = ''; taken = Iso $now.AddMinutes(-800); until = Iso $now.AddMinutes(-1); est = 600; eta = Iso $now.AddMinutes(-200)
            pid = $hp.Id; pidStart = (Stamp $hp.Id); childPid = $ch.Id; childPidStart = (Stamp $ch.Id) })
    Check 'F7 a tied lease keeps going past the expiry while its process runs' ((Status).leases.gpu.state -eq 'live')
    Check 'F7 a second take is queued, not handed the lease' ((T take gpu -By other -NoQueue) -eq 2)
    Check 'F7 waiters are not told "in 0 min"' ($out -notmatch 'in 0 min' -and $out -match 'still running')
    Stop-Process -Id $hp.Id -Force; Start-Sleep -Milliseconds 300
    Check 'F7 once its process ends the lease lapses' ((Status).leases.gpu.state -eq 'expired')

    # R3-2: [ ] in -Dir is a folder name, not a wildcard
    $script:D = New-Dir 'br[1]'
    Check 'R3-2 take in a bracketed -Dir' ((T take build -By alice) -eq 0)
    Check 'R3-2 a second take there is queued' ((T take build -By bob -NoQueue) -eq 2)

    # S2 and N5: a trailing backslash and a relative -Dir still reach the runner
    $sd = New-Dir 'slash'
    [void](TD ($sd + '\') submit build -By ci -Exe cmd.exe -ArgList '/c exit 0' -EstMin 1 -NoQuiet)
    $j = Wait-Job (LastId) @('done', 'failed', 'lost') 40 $sd
    Check 'S2 -Dir with a trailing backslash: the job runs' ($j.state -eq 'done')
    $rel = New-Dir 'rel'; $wd = New-Dir 'work'
    Push-Location $rel
    try {
        [void](TD '.\st' submit build -By ci -Exe cmd.exe -ArgList '/c exit 0' -EstMin 1 -NoQuiet -WorkDir $wd)
        $j = Wait-Job (LastId) @('done', 'failed', 'lost') 40 (Join-Path $rel 'st')
    } finally { Pop-Location }
    Check 'N5 a relative -Dir with another -WorkDir: the job runs' ($j.state -eq 'done')
    Check 'N5 no stray state folder in the -WorkDir' (-not (Test-Path -LiteralPath (Join-Path $wd 'st')))

    # R4-1: [ ] in a job's -WorkDir, and its output captured
    $script:D = New-Dir 'wd'
    $bw = New-Dir 'Game [UE5]'
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c cd & echo out-ok' -EstMin 1 -NoQuiet -WorkDir $bw)
    $j = Wait-Job (LastId) @('done', 'failed', 'lost')
    Check 'R4-1 a bracketed -WorkDir: the job runs' ($j.state -eq 'done' -and $j.exit -eq 0)
    Check 'R4-1 its output is captured' ([IO.File]::ReadAllText([string]$j.out) -match [regex]::Escape('Game [UE5]'))

    # R5-1: a job's name is unique across every lease's queue
    $script:D = New-Dir 'names'
    [void](T take gpu -By holder); [void](T take build -By holder)
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0' -NotBefore +2000 -NoQuiet -EstMin 1)
    Get-ChildItem -LiteralPath (Join-Path $D 'jobs') -Filter *.json | ForEach-Object { $_.LastWriteTime = (Get-Date).AddHours(-25) }
    [void](T submit gpu -By ci -Exe cmd.exe -ArgList '/c exit 0' -NoQuiet -EstMin 1)
    $script:out += "`n" + (@(Get-ChildItem -LiteralPath (Join-Path $D 'jobs') -Filter *.json -Name) -join ' ')
    Check 'R5-1 a second lane name, not a twin' ((LastId) -like 'ci.j2-*')

    # F5: cancelling a job that already ended changes nothing
    $script:D = New-Dir 'cancel'
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0' -EstMin 1 -NoQuiet)
    $id = LastId; $j = Wait-Job $id @('done', 'failed')
    [void](T job -JobId $id -Cancel)
    Check 'F5 cancel on a done job: already done' ($out -match 'already done' -and (Job $id).state -eq 'done')

    # R5-3 and R4-2: check validates -By, and a pid-tied lease covers only its own tree
    $script:D = New-Dir 'check'
    Check 'R5-3 check refuses a -By pattern' ((T check -Exe UnrealEditor.exe -ArgList 'P.uproject -game' -By '*') -eq 1)
    $other = Sleeper
    [void](T take gpu -By agent1 -HolderPid $other.Id)
    Check 'R4-2 a lease tied to another pid: take first' ((T check -Exe UnrealEditor.exe -ArgList 'P.uproject -game' -By agent1) -eq 2 -and $out -match 'tied to pid')
    [void](T release gpu -By agent1); [void](T take gpu -By agent1)
    Check 'R4-2 a pid-less lease of yours: go' ((T check -Exe UnrealEditor.exe -ArgList 'P.uproject -game' -By agent1) -eq 0)

    # Nested: a step started under the holder's own process asks for the same lease (a build script, a launcher's child)
    $script:D = New-Dir 'nested'
    [void](T take build -By outer -HolderPid $PID -EstMin 30)
    Check 'nested take under the holder is covered, not queued' ((T take build -By inner -NoQueue) -eq 0 -and $out -match 'covered')
    Check 'nested hold under the holder is covered' ((T hold build -By inner2 -NoQuiet -TimeoutMin 1) -eq 0 -and $out -match 'covered')
    Check 'nested release gives back nothing' ((T release build -By inner) -eq 0 -and (Status).leases.build.lease.by -eq 'outer')
    Check 'nothing was queued behind the parent' (@((Status).queues.build).Count -eq 0)
    $sib = Sleeper
    [void](T release build -By outer); [void](T take build -By outer -HolderPid $sib.Id)
    Check 'a take from outside the holder''s tree still queues' ((T take build -By inner -NoQueue) -eq 2)

    # The HUD feed's own command line names its services (COMFY=8188,IMAGEGEN=8391): it is not image generation
    $script:D = New-Dir 'hud'
    $fx = Join-Path $base 'hud-fixture.json'
    Put $fx @{ gpu = @{ usedMB = 500; totalMB = 12288; util = 2 }; procs = @(
        @{ pid = 9001; ppid = 4; name = 'pythonw.exe'; cmd = 'C:\Python313\pythonw.exe -u C:\x\wallpaper\thor_hud.py --port 47823 --services OLLAMA=11434,COMFY=8188,IMAGEGEN=8391'; agoSec = 600 },
        @{ pid = 9002; ppid = 4; name = 'python.exe'; cmd = 'python.exe ComfyUI\main.py --listen'; agoSec = 600 }) }
    $st = (& $Shell -NoProfile -File $thor status -Json -Dir $D -Fixture $fx | ConvertFrom-Json)
    $script:out = ($st.reasons -join '; ')
    Check 'the HUD feed is not image generation' (-not ($st.reasons | Where-Object { $_ -match 'pid 9001' }))
    Check 'a real ComfyUI still is' ([bool]($st.reasons | Where-Object { $_ -match 'image generation.*pid 9002' }))

    # MCP: dates keep their zone, dash-led values stay values, booleans are booleans
    $md = New-Dir 'mcp'
    $nonAscii = "caf$([char]0xE9) $([char]0x2014) $([char]0x2713)"   # built from code points: Windows PowerShell 5.1 reads this file as ANSI
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}   # read the server's UTF-8 as UTF-8
    $OutputEncoding = New-Object Text.UTF8Encoding $false                               # and pipe our requests to it as UTF-8 (5.1 sends ASCII)
    $nb = [DateTime]::UtcNow.AddHours(3); $nbs = $nb.ToString('yyyy-MM-ddTHH:mm:00Z')
    $r = Mcp $md @(
        @{ name = 'thor_take'; arguments = @{ lease = 'build'; by = 'holder' } },
        @{ name = 'thor_submit'; arguments = @{ lease = 'build'; by = 'mc'; exe = 'cmd.exe'; argList = '/c exit 0'; notBefore = $nbs; noQuiet = $true; estMin = 1 } },
        @{ name = 'thor_check'; arguments = @{ exe = 'UnrealEditor.exe'; argList = '-game' } },
        @{ name = 'thor_take'; arguments = @{ lease = 'gpu'; by = 'mb'; noQueue = 'maybe' } },
        @{ name = 'thor_take'; arguments = @{ lease = 'gpu'; by = 'mf'; for = $nonAscii; noQueue = 'false' } })
    $script:out = ($r | ForEach-Object { $_.result.content[0].text }) -join "`n---`n"
    $sub = ($r[1].result.content[0].text -split "`n", 2)[1] | ConvertFrom-Json
    $stored = [DateTime]$sub.notBefore
    Check 'S1 MCP notBefore keeps its zone' ([Math]::Abs(($stored.ToUniversalTime() - [DateTime]::Parse($nbs).ToUniversalTime()).TotalMinutes) -lt 1)
    $ck = ($r[2].result.content[0].text -split "`n", 2)[1] | ConvertFrom-Json
    Check 'N1 MCP argList "-game" stays a value' ($ck.kind -eq 'game')
    Check 'R3-3 MCP refuses a boolean that is not one' ($r[3].result.isError -and $r[3].result.content[0].text -match 'true or false')
    Check 'R3-3 MCP "false" is false' ($r[4].result.content[0].text -match '^exit 0')
    Check 'S6/N2 MCP non-ASCII comes back intact' ($r[4].result.content[0].text -match [regex]::Escape($nonAscii))
} finally {
    foreach ($s in $sleepers) { try { Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 1
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "fix: $pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
