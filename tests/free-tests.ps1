# free-tests.ps1 - lease-free kinds (header: Lease-free kinds), each in a throwaway state dir. Needs no GPU and runs no cop.
# Usage: pwsh tests\free-tests.ps1 [-Shell pwsh|powershell]
param([string]$Shell = 'pwsh')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$thor = Join-Path $root 'thor.ps1'
$prof = Join-Path $PSScriptRoot 'free-profile.json'
$fix = Join-Path $PSScriptRoot 'free-fixture.json'
$env:THOR_PROFILE = $prof
$base = Join-Path ([IO.Path]::GetTempPath()) ("thor-free-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($base)
$pass = 0; $fail = 0; $D = ''; $out = ''
function New-Dir([string]$Name) { $p = Join-Path $base $Name; foreach ($s in @('leases', 'queue')) { [void][IO.Directory]::CreateDirectory((Join-Path $p $s)) }; return $p }
function T { $o = & $Shell -NoProfile -ExecutionPolicy Bypass -File $thor @args -Dir $script:D 2>&1 | ForEach-Object { "$_" }; $script:out = $o -join "`n"; return $LASTEXITCODE }
function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red; Write-Host ($script:out -split "`n" | Select-Object -First 15 | Out-String) }
}
function Iso([DateTime]$T) { $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Put([string]$Path, $Obj) { [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
function Put-Lease([string]$Name, [bool]$Quiet) {
    $now = [DateTime]::UtcNow
    Put (Join-Path $script:D "leases\$Name.json") ([ordered]@{ lease = $Name; by = 'timer'; note = 'fps capture'; taken = Iso $now.AddMinutes(-1); until = Iso $now.AddMinutes(30)
            est = 20; eta = Iso $now.AddMinutes(19); pid = $null; pidStart = $null; childPid = $null; host = $env:COMPUTERNAME; quiet = $Quiet })
}
function Bad-Profile([string]$Name, $Obj) { $p = Join-Path $base "$Name.json"; Put $p $Obj; return $p }
$marked = 'C:\work\smoke.cjs --thor-free=webtest'
try {
    # Profile checks: a free kind can't be a lease's, and needs noise.
    $script:D = New-Dir 'profile'
    $p1 = Bad-Profile 'in-busy' @{ leases = @{ gpu = @{ card = $true; busy = @('webtest') } }; rules = @(@{ kind = 'webtest'; name = '.*' }); kinds = @{ webtest = @{ free = $true; noise = 'x' } } }
    $rc = T status -ProfilePath $p1
    Check 'a lease naming a free kind is refused' ($rc -eq 1 -and $out -match "free, so lease 'gpu' can't name it in busy")
    $p2 = Bad-Profile 'no-noise' @{ leases = @{ gpu = @{ card = $true } }; rules = @(@{ kind = 'webtest'; name = '.*' }); kinds = @{ webtest = @{ free = $true } } }
    $rc = T status -ProfilePath $p2
    Check 'a free kind without noise is refused' ($rc -eq 1 -and $out -match 'needs noise')

    # check: the marker makes it free; no marker, no kind; the marker never relabels a run that needs a lease.
    $script:D = New-Dir 'check'
    $rc = T check -Exe node.exe -ArgList $marked -Json
    $j = $out | ConvertFrom-Json
    Check 'check: marked node is free, go' ($rc -eq 0 -and $j.kind -eq 'webtest' -and $j.free -and $j.verdict -eq 'free')
    $rc = T check -Exe node.exe -ArgList 'C:\work\smoke.cjs' -Json
    Check 'check: unmarked node is no kind' ($rc -eq 0 -and ($out | ConvertFrom-Json).verdict -eq 'no kind')
    $rc = T check -Exe UnrealEditor.exe -ArgList 'Outpost.uproject -game --thor-free=webtest' -Json
    $j = $out | ConvertFrom-Json
    Check 'check: a marked -game run is still a game (free rules go last)' ($rc -eq 2 -and $j.kind -eq 'game' -and -not $j.free)

    # Timed work: a quiet-taken card lease or a quiet waiter first in line makes a free run wait; plain gpu work doesn't.
    $script:D = New-Dir 'timed'
    Put-Lease 'gpu' $false
    $rc = T check -Exe node.exe -ArgList $marked -Json
    Check 'plain gpu holder: free run goes' ($rc -eq 0 -and ($out | ConvertFrom-Json).verdict -eq 'free')
    Put-Lease 'gpu' $true
    $rc = T check -Exe node.exe -ArgList $marked -Json
    $j = $out | ConvertFrom-Json
    Check 'quiet-taken gpu lease: free run waits (exit 3)' ($rc -eq 3 -and $j.verdict -eq 'wait' -and $j.timed -match 'timer')
    Remove-Item (Join-Path $D 'leases\gpu.json')
    $now = [DateTime]::UtcNow
    Put (Join-Path $D 'queue\gpu.json') @{ entries = @(@{ by = 'bench'; note = 'frame cost'; est = 10; joined = $now.AddMinutes(-1).ToString('o'); nextCheck = Iso $now.AddMinutes(5); until = Iso $now.AddMinutes(10); needQuiet = $true; parked = 'quiet'; prio = 0 }) }
    $rc = T check -Exe node.exe -ArgList $marked -Json
    Check 'quiet waiter first with the lease free: free run waits' ($rc -eq 3 -and ($out | ConvertFrom-Json).timed -match 'bench')
    Put (Join-Path $D 'queue\gpu.json') @{ entries = @(@{ by = 'plain'; est = 10; joined = $now.AddMinutes(-1).ToString('o'); nextCheck = Iso $now.AddMinutes(5); until = Iso $now.AddMinutes(10); needQuiet = $false; prio = 0 }) }
    $rc = T check -Exe node.exe -ArgList $marked -Json
    Check 'plain waiter first: free run goes' ($rc -eq 0)

    # Quiet sees a running free process as noise, and status tags it lease-free.
    $script:D = New-Dir 'quiet'
    $rc = T quiet -Fixture $fix
    Check 'quiet: a running free process is noise' ($rc -eq 3 -and $out -match 'browser playtest: node\.exe pid 301')
    [void](T status -Fixture $fix)
    Check 'status tags it lease-free' ($out -match 'webtest\s+301.*\[lease-free\]')
    $rc = T check -Exe UnrealBuildTool.exe -ArgList 'x' -Json
    Check 'a build is still struck without the build lease' ($rc -eq 2)

    # free: refuses what isn't free, waits out timed work, else runs and returns the exit code.
    $script:D = New-Dir 'free'
    $rc = T free -By pt -Exe cmd.exe -ArgList '/c exit 0'
    Check 'free refuses an unmarked command (exit 2)' ($rc -eq 2 -and $out -match 'not a lease-free kind')
    $rc = T free -By pt -Exe cmd.exe -ArgList '/c exit 7 --thor-free=webtest'
    $log = Get-Content -LiteralPath (Join-Path $D 'lease.log') -Raw
    Check 'free runs it and returns its exit code' ($rc -eq 7 -and $log -match 'free webtest pt pid \d+' -and $log -match 'free-done webtest pt pid \d+ exit 7')
    Put-Lease 'gpu' $true
    $rc = T free -By pt -Exe cmd.exe -ArgList '/c exit 0 --thor-free=webtest' -TimeoutMin 0.1
    Check 'free gives up behind timed work, nothing started (exit 3)' ($rc -eq 3 -and $out -match 'nothing started')

    # A take that waited for quiet marks its lease quiet; a plain take doesn't.
    $script:D = New-Dir 'mark'
    $env:THOR_PROFILE = 'builtin'
    $calm = Join-Path $base 'calm.json'; Put $calm @{ gpu = @{ usedMB = 500; totalMB = 12288; util = 1 }; procs = @() }
    $job = Start-Job -ScriptBlock { param($s, $t, $d, $f) & $s -NoProfile -ExecutionPolicy Bypass -File $t run -By q -Exe ping.exe -ArgList '-n 6 127.0.0.1' -SettleSec 1 -TimeoutMin 1 -Fixture $f -Dir $d } -ArgumentList $Shell, $thor, $D, $calm
    $lf = Join-Path $D 'leases\gpu.json'; $t0 = [DateTime]::UtcNow.AddSeconds(40); $l = $null
    while ([DateTime]::UtcNow -lt $t0) { if (Test-Path $lf) { try { $l = Get-Content $lf -Raw | ConvertFrom-Json; if ($l.by -eq 'q') { break } } catch {} }; Start-Sleep -Milliseconds 300 }
    $script:out = "lease: $($l | ConvertTo-Json -Compress)"
    Check 'run after a quiet wait marks the lease quiet' ($l -and $l.quiet -eq $true)
    $job | Wait-Job -Timeout 60 | Out-Null; $job | Remove-Job -Force
    [void](T take gpu -By plain -EstMin 5)
    $l = Get-Content $lf -Raw | ConvertFrom-Json; $script:out = "lease: $($l | ConvertTo-Json -Compress)"
    Check 'a plain take is not quiet' ($l.quiet -eq $false)
    $env:THOR_PROFILE = $prof
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$pass passed, $fail failed"
if ($fail) { exit 1 }
