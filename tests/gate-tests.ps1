# gate-tests.ps1 - the project gate: a queued job waits while a clash on the same project runs. The box is a -Fixture,
# so nothing real is read or stopped. Needs no GPU. Usage: pwsh tests\gate-tests.ps1 [-Shell pwsh|powershell]
param([string]$Shell = 'pwsh')
$ErrorActionPreference = 'Stop'
$env:THOR_PROFILE = 'builtin'
$root = Split-Path -Parent $PSScriptRoot
$thor = Join-Path $root 'thor.ps1'
$base = Join-Path ([IO.Path]::GetTempPath()) ("thor-gate-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($base)
$pass = 0; $fail = 0; $D = ''
$U8 = New-Object Text.UTF8Encoding $false
function New-Dir([string]$Name) { $p = Join-Path $base $Name; [void][IO.Directory]::CreateDirectory($p); return $p }
function T { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $thor @args -Dir $script:D 2>&1 | ForEach-Object { "$_" }; $script:out = $o -join "`n"; return $LASTEXITCODE }
function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red; Write-Host ($script:out -split "`n" | Select-Object -First 15 | Out-String) }
}
function Job([string]$Id) { (& $Shell -NoProfile -File $thor job -JobId $Id -Json -Dir $script:D | ConvertFrom-Json) }
function Wait-Job([string]$Id, [string[]]$States, [int]$Sec = 40) {
    $t = [DateTime]::UtcNow.AddSeconds($Sec)
    while ([DateTime]::UtcNow -lt $t) { $j = Job $Id; if ([string]$j.state -in $States) { return $j }; Start-Sleep -Milliseconds 700 }
    return (Job $Id)
}
function LastId { if ($script:out -match 'job -JobId (\S+)') { return $Matches[1] }; return '' }
function Box([string]$Name, [object[]]$Procs) {
    $p = Join-Path $base "$Name.json"
    [IO.File]::WriteAllText($p, (@{ gpu = @{ usedMB = 900; totalMB = 12288; util = 3 }; procs = @($Procs) } | ConvertTo-Json -Depth 5), $U8)
    return $p
}
function Proc([int]$Id, [string]$Name, [string]$Cmd) { return @{ pid = $Id; ppid = 4; name = $Name; agoSec = 600; cmd = $Cmd } }
function Log { Get-Content -LiteralPath (Join-Path $script:D 'lease.log') -Raw }
$quiet = @('-NoQuiet', '-EstMin', '1')
try {
    $editorBox = Box 'editor' @(Proc 201 'UnrealEditor.exe' 'UnrealEditor.exe C:\Proj\Outpost\Outpost.uproject')
    $gameBox = Box 'game' @(Proc 202 'UnrealEditor.exe' 'UnrealEditor.exe C:\Proj\Outpost\Outpost.uproject -game -windowed')
    $ubtBox = Box 'ubt' @(Proc 203 'UnrealBuildTool.exe' 'UnrealBuildTool.exe OutpostEditor Win64 Development -Project=C:\Proj\Outpost\Outpost.uproject')
    $emptyBox = Box 'empty' @()

    # A build of a project waits while its editor is open; another project's build goes.
    $script:D = New-Dir 'build'
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0 & rem Build.bat OutpostEditor Win64 C:\Proj\Outpost\Outpost.uproject' -Fixture $editorBox @quiet)
    $held = LastId; $j = Job $held
    Check 'a build waits while its project''s editor is open' ([string]$j.state -eq 'queued' -and [string]$j.gate -match 'OUTPOST build clashes with editor')
    Check 'the wait is logged once' (([regex]::Matches((Log), "gate build ci\.j1 job $([regex]::Escape($held)) waits")).Count -eq 1)
    Check 'job shows why it waits' ((T job -JobId $held) -eq 0 -and $out -match '\[gate: OUTPOST build')
    $q = @((& $Shell -NoProfile -File $thor status -Json -Dir $D | ConvertFrom-Json).queues.build)
    Check 'its queue entry stands aside' ([string]$q[0].parked -eq 'gate')
    Check 'a plain take is not held behind it' ((T take build -By h -EstMin 5) -eq 0)
    [void](T release build -By h)
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0 & rem Build.bat Harbor.uproject' -Fixture $editorBox @quiet)
    Check 'another project''s build is not held' ([string](Wait-Job (LastId) @('done', 'failed')).state -eq 'done')
    Check 'the held build is still held' ([string](Job $held).state -eq 'queued')
    # The clash ends: the next dispatch pass starts it and says so.
    [void](T submit gpu -By ci -Exe cmd.exe -ArgList '/c exit 0' -Fixture $emptyBox @quiet)
    Check 'once the editor is gone the held build starts' ([string](Wait-Job $held @('done', 'failed')).state -eq 'done')
    Check 'its gate clears in lease.log' ((Log) -match "gate build ci\.j1 job $([regex]::Escape($held)) clear")

    # -NoGate skips it.
    $script:D = New-Dir 'nogate'
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0 & rem Build.bat C:\Proj\Outpost\Outpost.uproject' -Fixture $editorBox -NoGate @quiet)
    Check '-NoGate goes beside the editor' ([string](Wait-Job (LastId) @('done', 'failed')).state -eq 'done')

    # A build that names no project counts as every project.
    $script:D = New-Dir 'unnamed'
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0 & rem Build.bat' -Fixture $editorBox @quiet)
    $j = Job (LastId)
    Check 'a build naming no project waits on any project''s editor' ([string]$j.state -eq 'queued' -and [string]$j.gate -match 'no project named' -and [string]$j.gate -match 'name its \.uproject')

    # A wrapper script is read: a .ps1 that runs a commandlet waits for a -game run of its project.
    $script:D = New-Dir 'wrapper'
    $ps1 = Join-Path $base 'cook.ps1'; [IO.File]::WriteAllText($ps1, "# cooks C:\Proj\Outpost\Outpost.uproject`r`n& UnrealEditor-Cmd.exe C:\Proj\Outpost\Outpost.uproject -run=Cook`r`nexit 0`r`n", $U8)
    [void](T submit editor -By ci -Exe $ps1 -Fixture $gameBox @quiet)
    $j = Job (LastId)
    Check 'a script that runs a commandlet waits for a -game run' ([string]$j.state -eq 'queued' -and [string]$j.gate -match 'OUTPOST write clashes with game')
    [void](T submit editor -By ci -Exe cmd.exe -ArgList "/c exit 0 & rem $ps1" -Fixture $ubtBox @quiet)
    $j2 = Job (LastId)
    Check 'a script named in the arguments is read too' ([string]$j2.state -eq 'queued' -and [string]$j2.gate -match 'OUTPOST write clashes with build')

    # A .py that only names the editor is asking whether it is up: not gated. The same text in a .ps1 is an editor.
    $script:D = New-Dir 'py'
    $py = Join-Path $base 'probe.py'; [IO.File]::WriteAllText($py, "# is UnrealEditor.exe up for C:\Proj\Outpost\Outpost.uproject?`r`n", $U8)
    [void](T submit gpu -By ci -Exe cmd.exe -ArgList "/c exit 0 & rem $py" -Fixture $ubtBox @quiet)
    Check 'a .py that only names the editor is not held by a build' ([string](Wait-Job (LastId) @('done', 'failed')).state -eq 'done')
    $ed = Join-Path $base 'open.ps1'; [IO.File]::WriteAllText($ed, "# opens UnrealEditor.exe C:\Proj\Outpost\Outpost.uproject`r`nexit 0`r`n", $U8)
    [void](T submit editor -By ci -Exe $ed -Fixture $ubtBox @quiet)
    Check 'an editor script waits for a build of its project' ([string](Job (LastId)).gate -match 'OUTPOST editor clashes with build')

    # A running job counts as running: a second build waits behind the first one's project.
    $script:D = New-Dir 'jobs'
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c ping -n 6 127.0.0.1 >nul & rem Build.bat C:\Proj\Outpost\Outpost.uproject' -Fixture $emptyBox @quiet)
    $first = LastId; [void](Wait-Job $first @('running'))
    [void](T submit gpu -By ci -Exe cmd.exe -ArgList '/c exit 0 & rem UnrealEditor.exe C:\Proj\Outpost\Outpost.uproject -game' -Fixture $emptyBox @quiet)
    $j = Job (LastId)
    Check 'a -game job waits for a running build job of its project' ([string]$j.state -eq 'queued' -and [string]$j.gate -match 'job ci\.j1')
    [void](Wait-Job $first @('done', 'failed'))

    # THOR_MUTEX renames the lock, so another copy of the tool on the same folder can share it; a job carries it to its runner.
    $script:D = New-Dir 'mutex'
    $env:THOR_MUTEX = 'ThorGateTest' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    [void](T submit build -By ci -Exe cmd.exe -ArgList '/c exit 0' -Fixture $emptyBox @quiet)
    $j = Wait-Job (LastId) @('done', 'failed')
    Check 'a job carries the mutex base and its runner finishes' ([string]$j.mutex -eq $env:THOR_MUTEX -and [string]$j.state -eq 'done')
    $mx = New-Object Threading.Mutex($false, "Global\$($env:THOR_MUTEX)_lease"); [void]$mx.WaitOne()
    $env:THOR_GATE_TEST_THOR = $thor; $env:THOR_GATE_TEST_DIR = $D
    $bg = Start-Process $Shell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', '$t=[Diagnostics.Stopwatch]::StartNew(); & $env:THOR_GATE_TEST_THOR take gpu -By m -EstMin 1 -Dir $env:THOR_GATE_TEST_DIR | Out-Null; [IO.File]::WriteAllText((Join-Path $env:THOR_GATE_TEST_DIR ''took.txt''), [string]$t.Elapsed.TotalSeconds)') -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 4; $mx.ReleaseMutex(); $mx.Dispose()
    $bg.WaitForExit(60000) | Out-Null
    $took = [double](Get-Content -LiteralPath (Join-Path $D 'took.txt') -ErrorAction SilentlyContinue)
    $script:out = "took $took s"
    Check 'a take waits on the renamed lock held by another process' ($took -ge 2)
    Remove-Item Env:\THOR_MUTEX, Env:\THOR_GATE_TEST_THOR, Env:\THOR_GATE_TEST_DIR -ErrorAction SilentlyContinue

    # The profile's gate is checked.
    $script:D = New-Dir 'profile'
    $bad = Join-Path $base 'bad-gate.json'
    [IO.File]::WriteAllText($bad, '{ "leases": { "gpu": { "card": true } }, "gate": { "classes": [ { "class": "build", "match": "x" } ], "project": [ "(?i)\\.uproject" ] } }', $U8)
    Check 'a gate project pattern with no group 1 is refused' ((T status -ProfilePath $bad) -eq 1 -and $out -match 'no group 1')
    [IO.File]::WriteAllText($bad, '{ "leases": { "gpu": { "card": true } }, "gate": { "classes": [ { "class": "build", "match": "x" } ], "project": [ "(\\w+)\\.uproject" ], "clash": { "build": [ "game" ] } } }', $U8)
    Check 'a clash naming an unknown class is refused' ((T status -ProfilePath $bad) -eq 1 -and $out -match "class 'game'")
    $ml = Join-Path $root 'profiles\ml.json'
    Check 'a profile with no gate loads' ((T status -ProfilePath $ml) -eq 0)
    Check 'the unreal profile file loads' ((T status -ProfilePath (Join-Path $root 'profiles\unreal.json')) -eq 0)
} finally {
    Start-Sleep -Seconds 1
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
