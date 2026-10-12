# seed.ps1 - writes a fake but realistic Thor state (leases, a queue with a dispatched job, lease.log) into -Dir, with times
# relative to now. Pair it with fixture.json (fake processes + GPU) to render the board without touching your machine:
#   pwsh demo\seed.ps1 -Dir $env:TEMP\thor-demo
#   pwsh thor.ps1 watch -Dir $env:TEMP\thor-demo -Fixture demo\fixture.json            # live board, replayed
#   pwsh thor.ps1 watch -Dir $env:TEMP\thor-demo -Fixture demo\fixture.json -Frame     # one frame to stdout
param([string]$Dir = (Join-Path $env:TEMP 'thor-demo'))
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object Text.UTF8Encoding $false
if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
foreach ($d in 'leases', 'queue', 'jobs') { New-Item -ItemType Directory -Force (Join-Path $Dir $d) | Out-Null }
$now = [DateTime]::UtcNow
function T([double]$Min) { $now.AddMinutes($Min).ToString('yyyy-MM-ddTHH:mm:ssZ') }
function TF([double]$Min) { $now.AddMinutes($Min).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
function J($Path, $Obj) { [IO.File]::WriteAllText((Join-Path $Dir $Path), ($Obj | ConvertTo-Json -Depth 6), $Utf8) }

J 'leases\editor.json' ([ordered]@{ lease = 'editor'; by = 'claude-level'; note = 'courtyard blockout + lighting pass'; taken = T -26; until = T 94; est = 40; eta = T 14; pid = $null; pidStart = $null; childPid = $null; host = 'WORKSTATION' })
J 'leases\gpu.json' ([ordered]@{ lease = 'gpu'; by = 'codex-perf'; note = 'fps capture 1440p, 3 cameras'; taken = T -7; until = T 23; est = 18; eta = T 11; pid = $null; pidStart = $null; childPid = $null; host = 'WORKSTATION' })
$job = 'cursor-art.j1-demo'
J 'queue\gpu.json' @{ entries = @(
        [ordered]@{ by = 'cursor-art.j1'; note = 'bake Lumen cards, tier map'; est = 9; joined = TF -5; nextCheck = T 235; until = T 235; pid = $null; pidStart = $null; job = $job },
        [ordered]@{ by = 'claude-audit'; note = '-game smoke test after merge'; est = 12; joined = TF -2; nextCheck = T 9; until = T 14; pid = $null; pidStart = $null }
    ) }
J "jobs\$job.json" ([ordered]@{ id = $job; by = 'cursor-art'; runBy = 'cursor-art.j1'; lease = 'gpu'; note = 'bake Lumen cards, tier map'; est = 9
        exe = 'D:\UE_5.6\Engine\Binaries\Win64\UnrealEditor-Cmd.exe'; args = 'D:\Projects\Outpost\Outpost.uproject -run=LumenBake -map=Tier'; cwd = 'D:\Projects\Outpost'
        noQuiet = $false; timeoutMin = 240; state = 'queued'; why = ''; submitted = T -5; started = $null; ended = $null; exit = $null; runPid = $null; childPid = $null
        log = (Join-Path $Dir "jobs\$job.log"); out = (Join-Path $Dir "jobs\$job.out.log"); err = (Join-Path $Dir "jobs\$job.err.log") })
$log = @(
    "$(T -48) take build you until $(T 12) est 15 min for: Live Coding, AI perception"
    "$(T -33) release build you"
    "$(T -26) take editor claude-level until $(T 94) est 40 min for: courtyard blockout + lighting pass"
    "$(T -21) dispatch gpu codex-perf.j3 job codex-perf.j3-demo for: shader warmup"
    "$(T -20) take gpu codex-perf.j3 until $(T 700) est 6 min pid 18220 for: shader warmup"
    "$(T -14) release gpu codex-perf.j3 (run done)"
    "$(T -14) job-done gpu codex-perf.j3 job codex-perf.j3-demo exit 0"
    "$(T -12) cop-kill gpu 22104 claude-audit (it ran without the gpu lease): Outpost-Win64-Shipping.exe -ResX=1920 -ResY=1080"
    "$(T -9) strike build 9932 claude-audit (a C++ build without the build lease; not stopped): UnrealBuildTool.exe OutpostEditor Win64"
    "$(T -7) take gpu codex-perf until $(T 23) est 18 min for: fps capture 1440p, 3 cameras"
    "$(T -5) submit gpu cursor-art.j1 #1 est 9 min, expects $(T 11) job $job for: bake Lumen cards, tier map"
    "$(T -3) reestimate gpu codex-perf done ~$(T 11) (was $(T 4)); 1 waiting"
    "$(T -2) queue gpu claude-audit #2 est 12 min, expects $(T 20) for: -game smoke test after merge"
)
[IO.File]::WriteAllText((Join-Path $Dir 'lease.log'), (($log -join "`r`n") + "`r`n"), $Utf8)
Write-Host "demo state written to $Dir"
