# thor.ps1 - Thor Traffic Control: GPU / editor / build leases for a Windows box shared by AI agents and a human.
#
# Several AI coding agents (Claude Code, Cowork, Codex, Cursor, scripts...) plus you, all driving one Unreal Engine
# workstation: two -game runs at once tank every frame-time measurement, an agent closes the editor you were using, a C++
# build links while another one launches. Thor is a set of advisory leases with a fair queue, a dispatcher that starts
# queued jobs the moment their lease frees, a "cop" that enforces the GPU rule, and a live terminal board for the human.
#
# Usage:
#   thor.ps1 status  [-Json]
#   thor.ps1 take    <editor|gpu|build> -By <who> [-For 'what'] [-EstMin 20] [-Minutes 60] [-HolderPid <pid>] [-Wait] [-TimeoutMin 30] [-NoQueue]
#   thor.ps1 renew   <lease> -By <who> [-Minutes 60] [-EstMin <minutes from now>]
#   thor.ps1 release <lease> -By <who> [-Force]
#   thor.ps1 unqueue <lease> -By <who>
#   thor.ps1 submit  [gpu|editor|build] -By <who> -Exe <path> [-ArgList '<args>'] [-WorkDir <dir>] [-For 'what'] [-EstMin 20]
#                    [-Quiet] [-NoQuiet] [-TimeoutMin 240] [-NotBefore <+min | time>] [-Priority 0-9] [-Preemptible] [-Json]
#                    (+ quiet's switches)
#   thor.ps1 job    [-JobId <id>] [-By <who>] [-Json] [-Cancel]
#   thor.ps1 stats   [-Days 14] [-By <who>] [-Json]
#   every verb: [-Dir <state folder>] [-ProfilePath <profile.json>]
#   thor.ps1 run     -By <who> -Exe <path> [-ArgList '<args>'] [-Lease gpu] [-For 'what'] [-NoQuiet] [-TimeoutMin 60] (+ quiet's switches)
#   & thor.ps1 hold  [gpu|editor|build] -By <who> [-For 'what'] [-HolderPid <pid>] [-NoQuiet] [-TimeoutMin 30] (+ quiet's switches)
#   thor.ps1 quiet   [-By <who>] [-Wait] [-TimeoutMin 30] [-SettleSec 20] [-MaxVramGB 3.5] [-MaxUtil 50] [-AllowEditor] [-AllowBuild]
#   thor.ps1 watch   [-Every 5] [-NoCop] [-Plain] [-Once] [-NoToast] [-Frame -Cols 150 -Rows 50] [-Fixture <demo.json>]
#   thor.ps1 cop     [-Every 5] [-Once] [-Toast] [-CopDryRun] [-CopLenient] [-CopWait] [-CopMatch <regex>] [-ReapAfterMin 10]
#
# State lives in -Dir (default $env:THOR_DIR, else %ProgramData%\ThorTraffic): leases\<name>.json, queue\<name>.json,
# jobs\<id>.json and lease.log. Every change happens under one named mutex, so two takes can never both win. A finished job's
# files are deleted once they are $env:THOR_JOB_DAYS (30) days old; 0 keeps them all.
#
# Leases. A lease is a file with an expiry (-Minutes; defaults editor 120, build 60, gpu 30; cap 720) that the holder renews
# or releases, because an agent's tool call is short-lived and can't hold a mutex. A lease tied to a process (-HolderPid,
# or run / hold / submit) also ends when that process exits, so a killed run frees it. -EstMin is how long you expect to
# hold it: everyone else's wait times are built from it. Running long: renew -EstMin <minutes still needed> moves the
# estimate (and the expiry covers it); a plain renew keeps the estimate as it stands and never shortens an expiry.
# A lease covers the work, not the session: release it the moment that step ends, before you wait on anything else, and
# take it again when the next step is ready. A launcher handed to run or submit must wait for everything it starts, because
# the lease ends when the launcher exits.
# Wall clock: anything that can wait under a real lease, a test above all, needs its own hard kill at its estimate. -TimeoutMin only limits a job's wait for the
# lease; nothing ends a command once it runs, and the overrun cap only acts when someone is waiting. A scratch -Dir has its own leases but reads the real box: quiet sees real processes.
#
# Waitlist. A take that finds the lease held joins its queue and is told its place, its expected start and when to check
# back (never more than 10 min out, so an early release is noticed). Taking again at that time keeps the place; not back
# within 5 min of it drops you. When a lease frees it is kept for the first in line until they check back. A holder past its
# estimate counts as half the time left to its overrun cap (every lease has one for this sum), at least 5 more minutes, and never past its expiry.
#
# Standing aside. Only a wait for the lease itself reserves the lease. run, hold and jobs wait for quiet from the queue and
# take the lease after -SettleSec, so its estimate starts with the work. While the GPU is noisy the waiter is parked: it
# keeps its place, but the lease isn't kept for it and whoever can use it now takes it (a plain take, a -NoQuiet job). Once
# quiet it unparks, reclaims its place and the lease is kept for it through the settle. A queued job behind one parked for
# quiet with the same quiet switches waits unstarted, because it would only wait too. A holder that calls run or hold lets
# its own lease go while the GPU is noisy. A waiter parked -ParkWarnMin (15) says so in lease.log as park-long, then hourly,
# and the board toasts it.
#
# Dispatcher. submit puts a launch command in the queue as a job (jobs\<id>.json) under its own name <who>.j<n>. It needs
# no check-back: whenever a lease is unheld and its queue's first ready entry is a job, the dispatcher starts it - from the cop,
# from a watch window, or from the submit itself when the lease is free now - as `run -JobId <id>` in a detached, windowless
# process: wait for a quiet GPU if the job waits for one (see Quiet GPU; with the job's own -AllowEditor, -AllowBuild, -MaxVramGB,
# -MaxUtil and -SettleSec), take the lease tied to that runner, start -Exe in -WorkDir with stdout and
# stderr to <id>.out.log / <id>.err.log, release, record the exit code. States: queued, starting (its runner is up, and may
# be waiting for quiet: the waiting field says why), running, done, failed, cancelled, expired (never started within
# -TimeoutMin), lost (runner killed), overrun (stopped at its cap: see the cop), preempted (stopped for a higher priority and queued again). Read a job back with job -JobId <id> -Json.
#
# Later and first. submit -NotBefore +<minutes> or a time (21:30 is the next 21:30; at most 7 days out) queues a job that nobody
# waits for until then: the lease isn't kept for it, and its -TimeoutMin counts from that time. A dispatch pass starts it after,
# so something must run one (the cop, a watch window, any submit). -Priority 0-9 (0) orders a queue: higher first, then who came
# first; plain waiters are 0. A running job submitted -Preemptible gives way when a job of higher priority is first in its lease's
# queue: the cop stops it (state preempted, job-preempt in lease.log, a note) and queues it again under the same name, first among
# its priority. A job that isn't -Preemptible is never stopped for priority.
#
# Quiet GPU. For anything timed: no other holder's gpu lease, under -MaxVramGB of video memory in use, the GPU under
# -MaxUtil % busy (median of samples), no local LLM / image-generation python, no -game / packaged / commandlet run, no
# editor (-AllowEditor ignores it) and no UBT / UAT / shader-compile / cargo work (-AllowBuild ignores it). quiet -Wait,
# run, hold and dispatched jobs need it to hold for -SettleSec in a row. Windows doesn't report VRAM per process, so the
# card total gates. run waits for it on any lease unless -NoQuiet, and hold on gpu only. A job on the gpu lease waits only if
# it asks, with -Quiet or one of quiet's switches, because most gpu work isn't timed. A job on the editor or build lease waits
# unless -NoQuiet: with an editor open, that is what keeps a build job from failing at the link.
#
# The cop (inside watch unless -NoCop, or alone as `cop`; install-cop.ps1 runs it at logon; one cop at a time):
#   - stops agent -game and packaged runs that the gpu lease doesn't cover, once they are -CopGraceSec old (45 s). Never
#     the editor, never a commandlet (those write assets). -CopLenient lets the oldest uncovered run be when nobody holds
#     the gpu lease;
#   - "agent" = the command line carries an automation marker (bRemoteExecution=False, -ExecCmds=, -abslog=, -log=,
#     -ResX=, or your own via $env:THOR_AGENT_MARKERS), or a known agent host (claude.exe, codex, cursor) is up its parent
#     chain. Runs under explorer, Windows Terminal, Visual Studio, Rider or VS Code are yours and never stopped;
#   - covered = the gpu lease's pid, its child pid, or any descendant. A gpu lease with no pid covers the oldest uncovered
#     run started after it was taken;
#   - a stop is logged (cop-kill) and the reason + the fix are appended to the run's -abslog file and, with -ScratchDir,
#     to <ScratchDir>\<who>\THOR_COP.txt, where the agent will see it;
#   - a C++ build (UBT/UAT) without the build lease is logged as a strike, never stopped (a killed link can corrupt
#     binaries for everyone). A profile names what else is struck, per lease: an agent's run of a strike kind without the
#     lease, or a probed daemon busy while nobody holds it. Strikes are only logged; what is stopped stays the card lease's enforce list;
#   - it releases abandoned leases. A lease past its estimate with nothing of its kind running (editor: an editor or commandlet;
#     build: UBT, UAT or a commandlet; gpu: a game, packaged run, local LLM or image generation, or the card over -MaxUtil; any
#     lease: the command run started) gets idleSince on its file. Still idle after -ReapAfterMin (10) with someone in its queue,
#     it goes: reap in lease.log, a toast and, with -ScratchDir, a note in <ScratchDir>\<who>\THOR_COP.txt, <who> being its -By root. A renew clears the
#     mark and -ReapAfterMin 0 turns this off. Anything on the box counts as use, whoever's it is, so this errs toward keeping a lease;
#   - it caps overruns, because the reaper leaves a working job alone. A gpu job's cap falls 2 x its estimate + 5 min after it took the lease. A live gpu lease held by a dispatched
#     job, past its cap, with someone in its queue (the job's own lane counts), is stopped the way job -Cancel stops one: state overrun, job-overrun in lease.log, a toast and,
#     with -ScratchDir, a note. Small overruns are left alone, and with nobody waiting nothing happens until someone does. A commandlet or an editor anywhere in the job's tree
#     writes assets and is never stopped: over-cap in lease.log once per job, and a toast. A -game or packaged run writes none and goes like anything else. A renew's estimate
#     counts from the renew, so the cap is the lease's eta + est + 5: renew -EstMin <n> puts it 2 x n + 5 from then, and a plain renew inside the estimate leaves it. A plain renew
#     past the estimate takes a fresh default estimate, and the cap follows. submit and the dispatch line give the time the cap falls; a job that waits for quiet takes the lease
#     later, and its cap moves with it. -CopDryRun says what it would do; -CopMatch limits it to jobs whose command matches;
#   - its lane breaker is off ($LaneBreakOn), so a stopped job loses only itself and its lane's queued jobs each take their turn and their own cap. With it on: when a gpu job is
#     stopped by the cap, or ends past its cap on its own, the jobs in the gpu queue with its -By root (the text before the first dot: ci.art0 and ci.art10 share ci) are cancelled, with a
#     why that names it, before the lease frees: job-cancel lines and a note. Their estimates are suspect too. Plain waiters, and that lane's jobs on other leases, stay;
#   - it raises an over-cap alarm for a holder the cap can't stop, past the same cap with someone in its queue: a plain take, run or hold on any lease, or a job on the editor or
#     build lease. Stopping a hold would kill its caller's whole script, so nothing is stopped or released: over-cap <lease> <by> [job <id>] (not stopped: ...) in lease.log, a toast, with
#     -ScratchDir a note, and overCap on the lease file, so it is said once per cap. A renew writes a new lease, which clears the mark and moves the cap. -CopDryRun says what it
#     would log; -CopMatch limits it to jobs whose command matches, and to other holders whose -By or -For does.
#
# Board (watch). A live terminal view for the human: GPU memory and load, each lease with its holder and countdown, the
# queue with expected starts, the next 90 minutes as a timeline, what is running tagged with the lease covering it, and
# lease.log. Alerts are Windows toasts for leases changing hands, holders past their estimate, late waiters, cop kills,
# strikes, released leases, long waits for quiet, dispatched/finished jobs, overruns, uncovered runs and the GPU going quiet. Keys: q
# quits, t toggles alerts.
# -Frame prints one coloured frame and exits (docs, CI). -Fixture replays fake processes and GPU readings (demo, tests).
#
# Sinks. The cop hands every new lease.log line to the profile's hooks (each { on, exe, args }: exe starts detached, with the
# event in THOR_AT, THOR_EVENT, THOR_LEASE, THOR_BY, THOR_TEXT and THOR_LINE), to $env:THOR_WEBHOOK_URL as a JSON POST (only
# events matching $env:THOR_WEBHOOK_ON, if set; the url is never read from a file), and with cop -Toast to a Windows toast.
# <Dir>\sinks.pos keeps its place; failures go to <Dir>\sinks.err.log.
#
# Profiles. The leases and the process kinds are a table, and the one built in is the Unreal preset. A profile file replaces it:
# -ProfilePath <file>, else $env:THOR_PROFILE, else thor.profile.json beside this script; the word builtin as either forces the
# preset. profiles\unreal.json is the preset as a file, and the comment above $Traits says what each trait does. Everything on
# one state folder must use one profile: the dispatcher hands its own to the jobs it starts, the cop and the board need the same.
#
# Exit codes: 0 ok, 1 usage or error, 2 lease held by someone else (or kept for the queue's first), 3 not quiet.
param(
    [Parameter(Position = 0, Mandatory)][ValidateSet('status', 'take', 'renew', 'release', 'quiet', 'run', 'hold', 'unqueue', 'watch', 'cop', 'submit', 'job', 'stats')][string]$Verb,
    [Parameter(Position = 1)][string]$Lease,
    [string]$By,
    [string]$For = '',
    [int]$Minutes = 0,
    [double]$EstMin = 0,
    [switch]$NoQueue,
    [int]$HolderPid = 0,
    [switch]$Wait,
    [double]$TimeoutMin = 30,
    [int]$SettleSec = 20,
    [double]$MaxVramGB = 3.5,
    [int]$MaxUtil = 50,
    [switch]$AllowEditor,
    [switch]$AllowBuild,
    [switch]$Force,
    [switch]$Json,
    [string]$Exe,
    [string]$ArgList = '',
    [switch]$NoQuiet,
    [switch]$Quiet,
    [double]$ParkWarnMin = 15,
    [double]$ReapAfterMin = 10,
    [int]$Every = 5,
    [int]$LogLines = 10,
    [double]$Days = 14,
    [switch]$Once,
    [switch]$NoCop,
    [switch]$Plain,
    [int]$CopGraceSec = 45,
    [string]$CopMatch = '',
    [switch]$CopDryRun,
    [switch]$CopLenient,
    [switch]$CopWait,
    [switch]$NoToast,
    [switch]$Toast,
    [int]$TrafficEvery = 30,
    [string]$TrafficScript = '',
    [switch]$NoTraffic,
    [string]$WorkDir = '',
    [string]$JobId = '',
    [switch]$Cancel,
    [string]$ScratchDir = $env:THOR_SCRATCH,
    [string]$Dir = $(if ($env:THOR_DIR) { $env:THOR_DIR } else { Join-Path $env:ProgramData 'ThorTraffic' }),
    [string]$GameExe = $(if ($env:THOR_GAME_EXE) { $env:THOR_GAME_EXE } else { '(?i)-Win64-(Shipping|Development|Test|DebugGame)\.exe$' }),
    [switch]$Frame,
    [int]$Cols = 150,
    [int]$Rows = 50,
    [string]$Fixture = '',
    [string]$ProfilePath = '',
    [string]$NotBefore = '',
    [int]$Priority = 0,
    [switch]$Preemptible
)
$ErrorActionPreference = 'Stop'
$script:BoundKeys = @($PSBoundParameters.Keys)
# ---- the profile: leases and process kinds as data (this one is the Unreal preset; a file can replace it) -----------------
# The code below asks this table what a lease is and what a process is.
# Lease traits: minutes = default expiry. busy = process kinds that count as the lease in use; busyCpp = kinds that count only
#   when they are a C++ build. covers = kinds a live lease covers without a pid tie. strike = kinds the cop logs as a strike, never stops,
#   when an agent's one runs without the lease (a kind also in busyCpp: only its C++ builds); a kind with an idleProbe is a daemon
#   whose callers can't be traced, so it is struck once per busy spell while nobody holds the lease. card = the one lease the GPU reading gates: an agent's uncovered `enforce` kinds are stopped,
#   its jobs are capped, hold waits for quiet on it, a job on it asks for quiet, and it is the lease a verb takes by default.
# Kind rules, first match wins: name = regex on the process name, cmd = regex on its command line, cpp = it is a C++ build.
# Kind traits: noise = the line `quiet` gives for it ({name}, {pid}, {cmd}); allow = the switch that ignores it;
#   neverStop = it writes assets, so the overrun cap never stops a job with one in its tree.
# hooks (a file only) = @( @{ on = regex on a lease.log event; exe; args } ): the cop starts exe for each matching line (see Sinks).
#   idleProbe = @{ url; idle; timeoutMs } for a daemon that stays up with nothing loaded: when the url answers within timeoutMs
#   (1000) and the answer matches the regex idle, a process of that kind is neither noise nor the lease in use. No answer = busy.
$Traits = @{
    name = 'unreal'
    leases = [ordered]@{
        editor = @{ minutes = 120; busy = @('editor', 'commandlet'); busyCpp = @(); covers = @('editor'); strike = @() }
        gpu    = @{ minutes = 30; busy = @('game', 'packaged', 'llm', 'imagegen'); busyCpp = @(); covers = @(); strike = @(); card = $true; enforce = @('game', 'packaged') }
        build  = @{ minutes = 60; busy = @('commandlet'); busyCpp = @('build'); covers = @('build'); strike = @('build') }
    }
    rules = @(
        @{ kind = 'commandlet'; name = '(?i)^UnrealEditor-Cmd\.exe$' }
        @{ kind = 'commandlet'; name = '(?i)^UnrealEditor\.exe$'; cmd = '(?i)(^|\s)-run=' }
        @{ kind = 'game'; name = '(?i)^UnrealEditor\.exe$'; cmd = '(?i)(^|\s)-game(\s|$)' }
        @{ kind = 'editor'; name = '(?i)^UnrealEditor\.exe$' }
        @{ kind = 'packaged'; name = '{GameExe}' }
        @{ kind = 'llm'; name = '(?i)^(llama-server|ollama_llama_server)' }
        @{ kind = 'llm'; name = '(?i)^ollama\.exe$'; cmd = '(?i)\srunner(\s|$)' }
        @{ kind = 'imagegen'; name = '(?i)^pythonw?\.exe$'; cmd = '(?i)comfy|diffusers|flux|stable.?diffusion|sd-?webui|forge|invokeai|imagegen' }
        @{ kind = 'build'; name = '(?i)^(UnrealBuildTool|AutomationTool)\.exe$'; cpp = $true }
        @{ kind = 'build'; name = '(?i)^(ShaderCompileWorker|cargo|rustc)\.exe$' }
        @{ kind = 'build'; name = '(?i)^dotnet\.exe$'; cmd = '(?i)UnrealBuildTool|AutomationTool'; cpp = $true }
    )
    kinds = @{
        llm        = @{ noise = 'local LLM loaded: {name} pid {pid}' }
        imagegen   = @{ noise = 'image generation: {name} pid {pid}' }
        game       = @{ noise = '-game run: pid {pid} {cmd}' }
        packaged   = @{ noise = 'packaged game: {name} pid {pid}' }
        commandlet = @{ noise = 'commandlet: pid {pid} {cmd}'; neverStop = $true }
        editor     = @{ noise = 'editor open: pid {pid} {cmd} (-AllowEditor to ignore)'; allow = 'AllowEditor'; neverStop = $true }
        build      = @{ noise = 'build work: {name} pid {pid} (-AllowBuild to ignore)'; allow = 'AllowBuild' }
    }
}
function To-Hash($o) {
    # ConvertFrom-Json's objects as ordered hashtables (Windows PowerShell 5.1 has no -AsHashtable). Arrays stay arrays, even of one.
    if ($null -eq $o -or $o -is [string] -or $o -is [ValueType]) { return $o }
    if ($o -is [Collections.IEnumerable] -and $o -isnot [Collections.IDictionary]) { return , @($o | ForEach-Object { To-Hash $_ }) }
    $h = [ordered]@{}; foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = To-Hash $pr.Value }
    return $h
}
function Read-Profile([string]$Path) {
    # A profile file as the table, checked: a bad one stops here with what is wrong, before any lease is touched.
    $bad = { param($m) Write-Host "thor: profile $Path`: $m" -ForegroundColor Red; exit 1 }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { & $bad 'file not found' }
    try { $t = To-Hash ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path) | ConvertFrom-Json) } catch { & $bad "not valid JSON: $($_.Exception.Message)" }
    if ($t -isnot [Collections.IDictionary] -or $t.leases -isnot [Collections.IDictionary] -or -not $t.leases.Count) { & $bad 'it needs a "leases" object with at least one lease' }
    if (-not $t.name) { $t.name = [IO.Path]::GetFileNameWithoutExtension($Path) }
    foreach ($n in @($t.leases.Keys)) {
        if ($n -cnotmatch '^[a-z][a-z0-9_-]{0,15}$') { & $bad "lease '$n': a name is lower-case letters, digits, _ or -, at most 16, starting with a letter" }
        if ($t.leases[$n] -isnot [Collections.IDictionary]) { & $bad "lease '$n' must be an object" }
        $m = $t.leases[$n].minutes
        if ($null -ne $m -and ($m -isnot [ValueType] -or $m -lt 1 -or $m -gt 720)) { & $bad "lease '$n': minutes is a number from 1 to 720" }
    }
    if (@($t.leases.Keys | Where-Object { $t.leases[$_].card }).Count -ne 1) { & $bad 'exactly one lease must have "card": true (the lease the GPU reading gates)' }
    if ($null -eq $t.rules) { $t.rules = @() }
    if ($t.rules -is [Collections.IDictionary]) { & $bad '"rules" must be an array' }
    $i = 0
    foreach ($r in @($t.rules)) {
        $i++
        if ($r -isnot [Collections.IDictionary] -or [string]$r.kind -cnotmatch '^[a-z][a-z0-9_-]{0,15}$' -or -not [string]$r.name) { & $bad "rule $i needs a kind (a lower-case word) and a name (a regex on the process name)" }
        foreach ($f in @('name', 'cmd')) {
            if ($r[$f] -and [string]$r[$f] -ne '{GameExe}') { try { [void][regex]::new([string]$r[$f]) } catch { & $bad "rule $i ($($r.kind)): $f is not a regex: $($_.Exception.InnerException.Message)" } }
        }
    }
    if ($null -eq $t.kinds) { $t.kinds = [ordered]@{} }
    if ($t.kinds -isnot [Collections.IDictionary]) { & $bad '"kinds" must be an object' }
    foreach ($k in @($t.kinds.Keys)) {
        if ($t.kinds[$k] -isnot [Collections.IDictionary]) { & $bad "kind '$k' must be an object" }
        if ($t.kinds[$k].allow -and [string]$t.kinds[$k].allow -notin @('AllowEditor', 'AllowBuild')) { & $bad "kind '$k': allow is AllowEditor or AllowBuild" }
        $ip = $t.kinds[$k].idleProbe
        if ($null -ne $ip) {
            if ($ip -isnot [Collections.IDictionary] -or [string]$ip.url -notmatch '^https?://' -or -not [string]$ip.idle) { & $bad "kind '$k': idleProbe needs a url (http or https) and idle (a regex on the answer)" }
            try { [void][regex]::new([string]$ip.idle) } catch { & $bad "kind '$k': idleProbe.idle is not a regex" }
        }
    }
    foreach ($w in @('webhook', 'webhookUrl', 'url')) { if ($t.Contains($w)) { & $bad "a webhook url lives in `$env:THOR_WEBHOOK_URL only, never in a file (it often carries a token)" } }
    if ($null -eq $t.hooks) { $t.hooks = @() }
    if ($t.hooks -is [Collections.IDictionary]) { & $bad '"hooks" must be an array' }
    $i = 0
    foreach ($h in @($t.hooks)) {
        $i++
        if ($h -isnot [Collections.IDictionary] -or -not [string]$h.on -or -not [string]$h.exe) { & $bad "hook $i needs on (a regex on the lease.log event) and exe (what to start)" }
        try { [void][regex]::new([string]$h.on) } catch { & $bad "hook $i`: on is not a regex" }
        foreach ($w in @($h.Keys)) { if ($w -notin @('on', 'exe', 'args')) { & $bad "hook $i`: unknown field '$w' (on, exe, args)" } }
    }
    return $t
}
# Which profile: -ProfilePath, else $env:THOR_PROFILE, else thor.profile.json beside this script. The word builtin keeps the preset above.
$ProfileArg = if ($ProfilePath) { $ProfilePath } elseif ($env:THOR_PROFILE) { [string]$env:THOR_PROFILE } else { '' }
if (-not $ProfileArg -and $PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'thor.profile.json') -PathType Leaf)) { $ProfileArg = Join-Path $PSScriptRoot 'thor.profile.json' }
if ($ProfileArg -and $ProfileArg -ne 'builtin') {
    $Traits = Read-Profile $ProfileArg
    $ProfileArg = (Resolve-Path -LiteralPath $ProfileArg).Path
}
foreach ($n in @($Traits.leases.Keys)) {
    $lt = $Traits.leases[$n]
    if ($null -eq $lt.minutes) { $lt.minutes = 60 }
    foreach ($f in @('busy', 'busyCpp', 'covers', 'strike', 'enforce')) { $lt[$f] = @($lt[$f] | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
}
foreach ($r in @($Traits.rules)) { if ([string]$r.name -eq '{GameExe}') { $r.name = $GameExe } }
$Hooks = @($Traits.hooks | Where-Object { $_ })
$Names = @($Traits.leases.Keys)
if ($Lease) {
    $known = [string]($Names | Where-Object { $_ -eq $Lease } | Select-Object -First 1)
    if (-not $known) { Write-Host "thor: no lease '$Lease' in this profile ($($Traits.name)): name one of $($Names -join ', ')" -ForegroundColor Red; exit 1 }
    $Lease = $known
}
$CardLease = [string]($Names | Where-Object { $Traits.leases[$_].card } | Select-Object -First 1)
$NeverStop = @($Traits.kinds.Keys | Where-Object { $Traits.kinds[$_].neverStop })
$StrikeKinds = @($Names | ForEach-Object { $Traits.leases[$_].strike } | Where-Object { $_ } | Select-Object -Unique)
$script:Struck = @{}
$DefaultMin = @{}; foreach ($n in $Names) { $DefaultMin[$n] = $Traits.leases[$n].minutes }
$LeaseDir = Join-Path $Dir 'leases'
$QueueDir = Join-Path $Dir 'queue'
$JobDir = Join-Path $Dir 'jobs'; $JobWaitMin = 240
$JobKeepDays = 30; if ($env:THOR_JOB_DAYS -as [double]) { $JobKeepDays = [double]$env:THOR_JOB_DAYS }
$CheckMaxMin = 10; $CheckMinMin = 1; $GraceMin = 5; $OverrunMin = 5; $CapPadMin = 5; $LaneBreakOn = $false
$LogFile = Join-Path $Dir 'lease.log'
$Utf8 = New-Object Text.UTF8Encoding $false
New-Item -ItemType Directory -Force $LeaseDir, $QueueDir | Out-Null

function Fail([string]$Msg, [int]$Code = 1) { Write-Host "thor: $Msg" -ForegroundColor Red; exit $Code }
function Say([string]$Msg, [string]$Color = '') {
    if ($Color) { Write-Host "thor: $Msg" -ForegroundColor $Color } else { Write-Host "thor: $Msg" }
}
function Need-By {
    if (-not $script:By) { Fail '-By <who> is required: a short name for you or your agent session (e.g. agent1, s042, me)' }
    $script:By = $script:By.Trim().ToLower()
    if ($script:By -notmatch '^[a-z0-9][a-z0-9_.-]{0,31}$') { Fail "-By '$($script:By)': one word of letters, digits, . _ -" }
}
function Need-Lease { if (-not $script:Lease) { Fail "name a lease: $($Names -join ', ')" } }
function Now-Iso { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function To-Utc($v) {
    if ($v -is [DateTime]) { return $v.ToUniversalTime() }
    $st = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    return [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, $st)
}
function Local-Hm($v) { (To-Utc $v).ToLocalTime().ToString('HH:mm') }
function Iso([DateTime]$T) { $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function IsoFine([DateTime]$T) { $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
function Mins([DateTime]$T) { [int][Math]::Max(0, [Math]::Ceiling(($T - [DateTime]::UtcNow).TotalMinutes)) }
function Log-Line([string]$Line) { [IO.File]::AppendAllText($LogFile, "$(Now-Iso) $Line`r`n", $Utf8) }

$script:LockWaitSec = 45   # under a typical tool call's limit; Wait-Lease raises it, because a waiter has nowhere better to be
function With-Lock([scriptblock]$Body) {
    # Held for a read-modify-write only; waits never sit inside it, and neither do slow reads.
    $m = New-Object Threading.Mutex($false, 'Global\ThorTraffic_lease')
    $got = $false
    try {
        try { $got = $m.WaitOne($script:LockWaitSec * 1000) }
        catch {
            $e = $_.Exception
            while ($e) { if ($e -is [Threading.AbandonedMutexException]) { $got = $true; break }; $e = $e.InnerException }
            if (-not $got) { throw }
        }
        if (-not $got) { throw "the lease mutex stayed busy for $($script:LockWaitSec) s" }
        & $Body
    } finally {
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

function Read-Lease([string]$Name) {
    $p = Join-Path $LeaseDir "$Name.json"
    if (-not (Test-Path $p)) { return $null }
    try { return ([IO.File]::ReadAllText($p, $Utf8) | ConvertFrom-Json) } catch { return $null }
}
function Write-Lease([string]$Name, $Obj) { [IO.File]::WriteAllText((Join-Path $LeaseDir "$Name.json"), ($Obj | ConvertTo-Json), $Utf8) }
function Remove-Lease([string]$Name) { Remove-Item (Join-Path $LeaseDir "$Name.json") -Force -ErrorAction SilentlyContinue }

function Pid-Stamp([int]$P) {
    $pr = Get-Process -Id $P -ErrorAction SilentlyContinue
    if (-not $pr) { return $null }
    try { return [string]$pr.StartTime.ToUniversalTime().Ticks } catch { return '' }
}
function Lease-State($L) {
    # live | expired | ended (its process is gone or the pid was reused)
    if (-not $L) { return 'none' }
    if ((To-Utc $L.until) -le [DateTime]::UtcNow) { return 'expired' }
    if ($L.pid) {
        $stamp = Pid-Stamp ([int]$L.pid)
        if ($null -eq $stamp) { return 'ended' }
        if ($L.pidStart -and $stamp -and $stamp -ne [string]$L.pidStart) { return 'ended' }
    }
    return 'live'
}
function Describe-Lease($L) {
    $left = [int][Math]::Ceiling(((To-Utc $L.until) - [DateTime]::UtcNow).TotalMinutes)
    $s = "$($L.by)"
    if ($L.note) { $s += " '$($L.note)'" }
    $s += ", since $(Local-Hm $L.taken), until $(Local-Hm $L.until) ($left min)"
    if ($L.eta) {
        $eta = To-Utc $L.eta
        if ($eta -gt [DateTime]::UtcNow) { $s += ", expects to be done $(Local-Hm $eta)" } else { $s += ", past its estimate ($(Local-Hm $eta))" }
    }
    if ($L.pid) { $s += ", tied to pid $($L.pid)" }
    if ($L.childPid) { $s += ", running pid $($L.childPid)" }
    if ($L.idleSince) { $s += ", nothing running since $(Local-Hm $L.idleSince)" }
    return $s
}

# ---- the waitlist -------------------------------------------------------------------------------------------------------
function Est-Minutes([string]$Name) {
    if ($EstMin -gt 0) { return [double]$EstMin }
    if ($Minutes -gt 0 -and $Minutes -lt 720) { return [double]$Minutes }
    return [double]$DefaultMin[$Name]
}
function Read-Queue([string]$Name) {
    $p = Join-Path $QueueDir "$Name.json"
    if (-not (Test-Path $p)) { return @() }
    try { $o = [IO.File]::ReadAllText($p, $Utf8) | ConvertFrom-Json } catch { return @() }
    return @($o.entries | Where-Object { $_ })
}
function Write-Queue([string]$Name, $Entries) {
    $p = Join-Path $QueueDir "$Name.json"
    $list = @($Entries)
    if ($list.Count -eq 0) { Remove-Item $p -Force -ErrorAction SilentlyContinue; return }
    [IO.File]::WriteAllText($p, (@{ entries = $list } | ConvertTo-Json -Depth 5), $Utf8)
}
function Sort-Queue($Entries) {
    # Queue order: higher -Priority first, then who joined first.
    return , @(@($Entries) | Where-Object { $_ } | Sort-Object { -[int]$_.prio }, { (To-Utc $_.joined).Ticks }, { [string]$_.by })
}
function Live-Queue([string]$Name, [string]$HolderBy, [switch]$Log) {
    # Drops no-shows (past their check-back plus grace), waiters whose process ended, waiters whose job already ended, and the holder itself.
    $now = [DateTime]::UtcNow; $keep = @()
    foreach ($e in (Sort-Queue (Read-Queue $Name))) {
        $why = $null
        if ((To-Utc $e.until) -le $now) { $why = 'no-show' }
        elseif ($e.pid) { $st = Pid-Stamp ([int]$e.pid); if ($null -eq $st -or ($e.pidStart -and $st -and $st -ne [string]$e.pidStart)) { $why = 'process ended' } }
        if (-not $why -and $e.job) {
            # A job's waiter outlives its job when the job ends without taking the lease (expired, cancelled, lost):
            # left in place it blocks every waiter behind it with the lease free.
            $jp = Join-Path $JobDir "$($e.job).json"
            if (Test-Path -LiteralPath $jp) {
                try { $js = [string]([IO.File]::ReadAllText($jp, $Utf8) | ConvertFrom-Json).state } catch { $js = '' }
                if ($js -in @('expired', 'cancelled', 'failed', 'lost', 'done', 'overrun', 'preempted')) { $why = "job $js" }
            }
        }
        if (-not $why -and $HolderBy -and $e.by -eq $HolderBy) { $why = 'holds it now' }
        if ($why) { if ($Log -and $why -ne 'holds it now') { Log-Line "dequeue $Name $($e.by) ($why)" }; continue }
        $keep += $e
    }
    return , $keep
}
function Queue-First($Q) {
    # Who a free lease is kept for: the first waiter that could use it now (header: Standing aside).
    $quietAhead = @(); $now = [DateTime]::UtcNow
    foreach ($e in @($Q)) {
        if ($e.notBefore -and (To-Utc $e.notBefore) -gt $now) { continue }
        if ($e.parked) { $quietAhead += [string]$e.quietKey; continue }
        if ($e.needQuiet -and $quietAhead -contains [string]$e.quietKey) { continue }
        return $e
    }
    return $null
}
function Quiet-Key { return "$([bool]$AllowEditor)|$([bool]$AllowBuild)|$MaxVramGB|$MaxUtil" }
function Cap-Span([double]$Est) { return 2 * $Est + $CapPadMin }
function Cap-At($L) {
    # When a holder's overrun cap falls (header: the cop): 2 x est + pad after its take. A renew's est counts from the renew, so it is eta + est + pad, never before the eta.
    if (-not $L -or -not $L.eta) { return $null }
    return (To-Utc $L.eta).AddMinutes([double]$L.est + $CapPadMin)
}
function Free-At($L, [string]$State) {
    # When the current holder should be done: its estimate; past that, half the time left to its cap, at least OverrunMin. Never after its expiry.
    $now = [DateTime]::UtcNow
    if ($State -ne 'live') { return $now }
    $until = To-Utc $L.until
    $eta = if ($L.eta) { To-Utc $L.eta } else { $until }
    if ($eta -le $now) { $eta = $now.AddMinutes([Math]::Max($OverrunMin, ((Cap-At $L) - $now).TotalMinutes / 2)) }
    if ($eta -gt $until) { $eta = $until }
    return $eta
}
function Plan-Queue($Entries, [DateTime]$FreeAt) {
    # Each waiter's expected start: when the holder is done plus the estimates of everyone ahead.
    # A job held back by -NotBefore starts at that time at the earliest, and the others go on in the gap.
    $t = $FreeAt; $out = @()
    foreach ($e in $Entries) {
        $nb = if ($e.notBefore) { To-Utc $e.notBefore } else { $null }
        if ($nb -and $nb -gt $t) { $out += [pscustomobject]@{ e = $e; start = $nb }; continue }
        $out += [pscustomobject]@{ e = $e; start = $t }; $t = $t.AddMinutes([double]$e.est)
    }
    return , $out
}
function Check-Back([DateTime]$Start) {
    $now = [DateTime]::UtcNow
    $m = [Math]::Min($CheckMaxMin, [Math]::Max($CheckMinMin, ($Start - $now).TotalMinutes))
    return $now.AddMinutes($m)
}
function Wait-Text($Res, [string]$Name) {
    if ($Res.reservedFor) { $s = "$Name is free but kept for $($Res.reservedFor), first in its queue, until $(Local-Hm $Res.reservedUntil)" }
    else { $s = "$Name is held by $(Describe-Lease $Res.cur)" }
    $verb = if ($Res.queued) { "You're" } else { "You'd be" }
    $s += ". $verb #$($Res.pos) of $($Res.total) in its queue"
    if ($Res.ahead) { $s += " (behind $($Res.ahead -join ', '))" }
    $s += "; expected free for you about $(Local-Hm $Res.start) (in $(Mins $Res.start) min)."
    if ($Res.queued) { $s += " Check back at $(Local-Hm $Res.check) (in $(Mins $Res.check) min) and take it again: that keeps your place. Not back by $(Local-Hm $Res.until) and you drop out." }
    else { $s += ' Not queued (-NoQueue).' }
    return $s
}
function Try-Take([string]$Name, [int]$Min, [int]$TiePid, [bool]$Ready = $true, [bool]$NeedQuiet = $false, [string]$Park = '') {
    # -Ready $false does everything but the take: it keeps the caller's queue place and says if the lease is theirs to take (turn).
    With-Lock {
        $cur = Read-Lease $Name
        $state = Lease-State $cur
        $holder = if ($state -eq 'live') { [string]$cur.by } else { '' }
        $q = Live-Queue $Name $holder -Log
        $now = [DateTime]::UtcNow
        $est = Est-Minutes $Name
        $first = Queue-First $q
        $mine = $holder -eq $By
        $free = -not $holder -and (-not $first -or $first.by -eq $By)
        if ($mine -and -not $Ready) { return @{ ok = $false; turn = $true; mine = $true; cur = $cur } }
        if (($mine -or $free) -and $Ready) {
            if ($cur -and $state -ne 'live') { Log-Line "lapse $Name $($cur.by) ($state)" }
            $taken = Now-Iso
            if ($mine) { $taken = Iso (To-Utc $cur.taken) }
            # Re-estimate: a holder's renew without -EstMin keeps its standing estimate; renew -EstMin <minutes from now>
            # moves it. Either way the expiry covers the estimate plus OverrunMin (cap 720), so the queue's expected starts
            # follow the new estimate.
            $etaT = $now.AddMinutes($est); $oldEta = $null
            if ($mine -and $cur.eta) {
                $oldEta = To-Utc $cur.eta
                if ($script:BoundKeys -notcontains 'EstMin' -and $oldEta -gt $now) { $etaT = $oldEta; $est = [double]$cur.est }
            }
            $untilT = $now.AddMinutes($Min)
            if ($untilT -lt $etaT.AddMinutes($OverrunMin)) { $untilT = $etaT.AddMinutes($OverrunMin) }
            if ($untilT -gt $now.AddMinutes(720)) { $untilT = $now.AddMinutes(720) }
            if ($mine) { $curU = To-Utc $cur.until; if ($curU -gt $untilT) { $untilT = $curU } }   # a renew never shortens (run leases sit at 720)
            $new = [ordered]@{
                lease = $Name; by = $By; note = $(if ($mine -and -not $For) { [string]$cur.note } else { $For }); taken = $taken
                until = Iso $untilT; est = $est; eta = Iso $etaT
                pid = $null; pidStart = $null; childPid = $null; host = $env:COMPUTERNAME
            }
            if ($TiePid) { $new.pid = $TiePid; $new.pidStart = Pid-Stamp $TiePid }
            if ($mine -and $cur.childPid -and [int]$cur.pid -eq [int]$new.pid) { $new.childPid = $cur.childPid }   # a renew keeps run's child
            Write-Lease $Name $new
            Write-Queue $Name @($q | Where-Object { $_.by -ne $By })
            $verb = if ($mine) { 'renew' } else { 'take' }
            Log-Line "$verb $Name $By until $($new.until) est $est min$(if ($TiePid) { " pid $TiePid" })$(if ($For) { " for: $For" })"
            if ($mine -and $oldEta -and [Math]::Abs(($etaT - $oldEta).TotalMinutes) -ge 1) { Log-Line "reestimate $Name $By done ~$($new.eta) (was $(Iso $oldEta))$(if ($q.Count) { "; $($q.Count) waiting" })" }
            return @{ ok = $true; cur = [pscustomobject]$new; renewed = $mine; oldEta = $oldEta; waiting = $q.Count }
        }
        # Held, free but kept for the queue's first, or ours but not ready for it: join (or refresh) the queue and say when to come back.
        $old = $q | Where-Object { $_.by -eq $By } | Select-Object -First 1
        $joined = if ($old) { IsoFine (To-Utc $old.joined) } else { IsoFine $now }
        $me = [ordered]@{
            by = $By; note = $For; est = $est; joined = $joined
            nextCheck = $null; until = $null; pid = $null; pidStart = $null; needQuiet = $NeedQuiet; parked = $Park; quietKey = (Quiet-Key)
        }
        if ($old -and $old.job) { $me.job = [string]$old.job }
        if ($TiePid) { $me.pid = $TiePid; $me.pidStart = Pid-Stamp $TiePid }
        $list = @(@($q | Where-Object { $_.by -ne $By }) + @([pscustomobject]$me) | Sort-Object { (To-Utc $_.joined).Ticks }, { [string]$_.by })
        $plan = Plan-Queue $list (Free-At $cur $state)
        $i = 0; while ($plan[$i].e.by -ne $By) { $i++ }
        $start = $plan[$i].start
        $check = Check-Back $start
        $until = $check.AddMinutes($GraceMin)
        # A parked waiter's turn doesn't end because someone behind it is next: once the GPU is quiet it reclaims its place.
        $turn = $free
        if (-not $turn -and -not $holder -and $old) { $names = @($q | ForEach-Object { [string]$_.by }); $turn = [array]::IndexOf($names, [string]$first.by) -gt [array]::IndexOf($names, $By) }
        $res = @{ ok = $false; turn = $turn; cur = $cur; pos = $i + 1; total = $list.Count; start = $start; check = $check; until = $until
            ahead = @($list[0..([Math]::Max(0, $i - 1))] | Where-Object { $_.by -ne $By } | ForEach-Object { $_.by }); queued = -not $NoQueue }
        if ($i -eq 0) { $res.ahead = @() }
        if (-not $holder -and $first -and $first.by -ne $By) { $res.reservedFor = $first.by; $res.reservedUntil = To-Utc $first.until }
        if ($NoQueue) { return $res }
        $me.nextCheck = Iso $check; $me.until = Iso $until
        $list = @($list | ForEach-Object { if ($_.by -eq $By) { [pscustomobject]$me } else { $_ } })
        Write-Queue $Name $list
        if (-not $old) { Log-Line "queue $Name $By #$($i + 1) est $est min, expects $(Iso $start)$(if ($For) { " for: $For" })" }
        return $res
    }
}
function Do-Unqueue([string]$Name) {
    With-Lock {
        $q = @(Read-Queue $Name)
        $left = @($q | Where-Object { $_.by -ne $By })
        if ($left.Count -eq $q.Count) { return $false }
        Write-Queue $Name $left
        Log-Line "unqueue $Name $By"
        return $true
    }
}
function Do-Release([string]$Name, [switch]$Quiet) {
    With-Lock {
        $cur = Read-Lease $Name
        if (-not $cur) { return @{ ok = $true; msg = "$Name was not held" } }
        $state = Lease-State $cur
        if ($state -eq 'live' -and $cur.by -ne $By -and -not $Force) { return @{ ok = $false; cur = $cur } }
        Remove-Lease $Name
        $how = if ($cur.by -ne $By) { "release-forced (was $($cur.by), $state)" } else { 'release' }
        Log-Line "$how $Name $By"
        $q = Live-Queue $Name ''
        $msg = "$Name released (was $($cur.by))"
        $first = Queue-First $q
        if ($first) { $msg += "; kept for $($first.by), first in its queue (checks back by $(Local-Hm $first.nextCheck))" }
        return @{ ok = $true; msg = $msg }
    }
}

# ---- the dispatcher ------------------------------------------------------------------------------------------------------
function Job-Path([string]$Id) { Join-Path $JobDir "$Id.json" }
function Read-Job([string]$Id) {
    $p = Job-Path $Id
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return ([IO.File]::ReadAllText($p, $Utf8) | ConvertFrom-Json) } catch { return $null }
}
function Write-Job($J) { [IO.File]::WriteAllText((Job-Path $J.id), ($J | ConvertTo-Json -Depth 4), $Utf8) }
function Set-Job([string]$Id, [hashtable]$Fields, [string[]]$OnlyFrom = @()) {
    # Changes fields of a job under the lease mutex; with -OnlyFrom, only while the job is in one of those states.
    With-Lock {
        $j = Read-Job $Id
        if (-not $j) { return $null }
        if ($OnlyFrom.Count -and [string]$j.state -notin $OnlyFrom) { return $null }
        foreach ($fk in $Fields.Keys) { $j | Add-Member -NotePropertyName $fk -NotePropertyValue $Fields[$fk] -Force }
        Write-Job $j; return $j
    }
}
function Drop-JobEntry([string]$Name, [string]$RunBy) {
    With-Lock { Write-Queue $Name @(Read-Queue $Name | Where-Object { $_.by -ne $RunBy }) } | Out-Null
}
function Prune-Jobs {
    # A finished job's files (json and logs) go once they are $JobKeepDays old ($env:THOR_JOB_DAYS, default 30; 0 keeps all), so the
    # folder every dispatch pass lists stays small. At most once an hour per state folder; a job still queued or running stays.
    if ($JobKeepDays -le 0 -or -not (Test-Path $JobDir)) { return 0 }
    $mk = Join-Path $JobDir '.pruned'
    if ((Test-Path -LiteralPath $mk) -and (Get-Item -LiteralPath $mk).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddHours(-1)) { return 0 }
    [IO.File]::WriteAllText($mk, (Now-Iso), $Utf8)
    $cut = [DateTime]::UtcNow.AddDays(-$JobKeepDays); $n = 0
    foreach ($f in @(Get-ChildItem $JobDir -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -lt $cut })) {
        try { $st = [string]([IO.File]::ReadAllText($f.FullName, $Utf8) | ConvertFrom-Json).state } catch { continue }
        if ($st -notin @('done', 'failed', 'cancelled', 'expired', 'lost', 'overrun', 'preempted')) { continue }
        foreach ($x in @('.json', '.log', '.out.log', '.err.log')) { Remove-Item -LiteralPath (Join-Path $JobDir "$($f.BaseName)$x") -Force -ErrorAction SilentlyContinue }
        $n++
    }
    if ($n) { Log-Line "prune jobs - $n finished jobs older than $JobKeepDays days" }
    return $n
}
function Recent-Jobs([int]$Hours = 13) {
    if (-not (Test-Path $JobDir)) { return @() }
    $since = (Get-Date).AddHours(-$Hours)
    return @(Get-ChildItem $JobDir -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since } |
        Sort-Object LastWriteTime | ForEach-Object { try { [IO.File]::ReadAllText($_.FullName, $Utf8) | ConvertFrom-Json } catch {} } | Where-Object { $_ })
}
function Parse-When([string]$S) {
    # -NotBefore: +<minutes> from now, or a time (local unless it says otherwise). A bare 21:30 that has passed means tomorrow's.
    $now = [DateTime]::UtcNow
    if ($S -match '^\+(\d+(\.\d+)?)$') { $t = $now.AddMinutes([double]$Matches[1]) }
    else {
        try { $t = [DateTime]::Parse($S, [Globalization.CultureInfo]::CurrentCulture, [Globalization.DateTimeStyles]::AssumeLocal).ToUniversalTime() }
        catch { Fail "-NotBefore '$S' is not a time: give +<minutes>, or a time like 21:30 or 2026-11-19 02:00" }
        if ($S -match '^\d{1,2}:\d\d$' -and $t -le $now) { $t = $t.AddDays(1) }
    }
    if ($t -le $now) { Fail "-NotBefore $S has already passed" }
    if ($t -gt $now.AddDays(7)) { Fail '-NotBefore is at most 7 days out' }
    return $t
}
function Do-Submit {
    if ($Priority -lt 0 -or $Priority -gt 9) { Fail '-Priority is 0 to 9 (higher goes first)' }
    $nb = if ($NotBefore) { Parse-When $NotBefore } else { $null }
    $exePath = $Exe
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        $gc = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $gc) { Fail "-Exe '$Exe' not found" }
        $exePath = $gc.Source
    } else { $exePath = (Resolve-Path -LiteralPath $exePath).Path }
    $cwd = if ($WorkDir) { if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { Fail "-WorkDir '$WorkDir' not found" }; (Resolve-Path -LiteralPath $WorkDir).Path } else { (Get-Location).ProviderPath }
    $tmo = if ($script:BoundKeys -contains 'TimeoutMin') { [double]$TimeoutMin } else { [double]$JobWaitMin }
    $est = Est-Minutes $Lease
    New-Item -ItemType Directory -Force $JobDir | Out-Null
    # Reading a day of job files is slow, so it happens before the lock. A job submitted meanwhile is in the queue or holds a lease, and both are read under it.
    $liveJobs = @(Recent-Jobs 24 | Where-Object { [string]$_.state -in @('queued', 'starting', 'running') } | ForEach-Object { [string]$_.runBy })
    $res = With-Lock {
        $now = [DateTime]::UtcNow
        $cur = Read-Lease $Lease; $state = Lease-State $cur
        $holder = if ($state -eq 'live') { [string]$cur.by } else { '' }
        $q = Live-Queue $Lease $holder -Log
        # The job's own name on the lease (<by>.j<n>): unique among waiters, holders and live jobs, so one session can queue several.
        $used = @{}; if ($holder) { $used[$holder] = 1 }
        foreach ($e in $q) { $used[[string]$e.by] = 1 }
        foreach ($nm in $Names) { $l2 = Read-Lease $nm; if ($l2) { $used[[string]$l2.by] = 1 } }
        foreach ($rb in $liveJobs) { $used[$rb] = 1 }
        $jn = 1; while ($used.ContainsKey("$By.j$jn")) { $jn++ }
        $runBy = "$By.j$jn"
        $id = "$runBy-$($now.ToLocalTime().ToString('MMdd-HHmmss'))"
        $job = [pscustomobject][ordered]@{
            id = $id; by = $By; runBy = $runBy; lease = $Lease; note = $For; est = $est
            exe = $exePath; args = $ArgList; cwd = $cwd; noQuiet = [bool]$NoQuiet; timeoutMin = $tmo
            allowEditor = [bool]$AllowEditor; allowBuild = [bool]$AllowBuild; maxVramGB = $MaxVramGB; maxUtil = $MaxUtil; settleSec = $SettleSec
            prio = $Priority; preemptible = [bool]$Preemptible; notBefore = $(if ($nb) { Iso $nb } else { $null })
            state = 'queued'; why = ''; submitted = Iso $now; started = $null; took = $null; ended = $null; exit = $null; runPid = $null; childPid = $null
            log = (Join-Path $JobDir "$id.log"); out = (Join-Path $JobDir "$id.out.log"); err = (Join-Path $JobDir "$id.err.log")
        }
        Write-Job $job
        # Its queue place never needs a check-back: the dispatcher starts it. It drops out only after -TimeoutMin of waiting.
        $from = if ($nb) { $nb } else { $now }
        $me = [pscustomobject][ordered]@{ by = $runBy; note = $For; est = $est; joined = IsoFine $now; nextCheck = Iso $from.AddMinutes($tmo); until = Iso $from.AddMinutes($tmo); pid = $null; pidStart = $null; job = $id; needQuiet = -not [bool]$NoQuiet; parked = ''; quietKey = (Quiet-Key); prio = $Priority; notBefore = $(if ($nb) { Iso $nb } else { $null }) }
        $list = Sort-Queue (@($q) + @($me))
        Write-Queue $Lease $list
        $plan = Plan-Queue $list (Free-At $cur $state)
        $pos = 1; for ($k = 0; $k -lt $list.Count; $k++) { if ($list[$k].by -eq $runBy) { $pos = $k + 1 } }; $start = $plan[$pos - 1].start
        Log-Line "submit $Lease $runBy #$pos est $est min, expects $(Iso $start) job $id$(if ($Priority) { " priority $Priority" })$(if ($Preemptible) { ' preemptible' })$(if ($nb) { " not before $(Iso $nb)" })$(if ($For) { " for: $For" })"
        return @{ id = $id; runBy = $runBy; pos = $pos; total = $list.Count; start = $start; holder = $holder }
    }
    [void](Dispatch-Pass)
    $j = Read-Job $res.id
    # The estimate check: jobs like this one have a history, and an estimate far under it is everyone else's wait time.
    $hint = ''
    try {
        $like = @(Job-Stats 30 | Where-Object { $_.key -eq (Job-Kind $j) }) | Select-Object -First 1
        if ($like -and $like.n -ge 3 -and $like.actual -ge 1.25 * $est -and ($like.actual - $est) -ge 2) {
            $hint = "the last $($like.n) jobs like this ran a median of $($like.actual) min and you said $est. Your estimate is everyone's wait and sets its cap: cancel it and submit again with a true -EstMin, or renew -EstMin once it runs"
        }
    } catch {}
    if ($Json) { if ($hint) { $j | Add-Member -NotePropertyName estimateHint -NotePropertyValue $hint -Force }; $j | ConvertTo-Json -Depth 4; exit 0 }
    if ($j.state -eq 'queued') {
        $ahead = if ($res.holder) { "held by $($res.holder)" } elseif ($nb) { 'free' } else { 'free, but behind the queue' }
        $held = if ($nb) { "held back until $(Local-Hm $nb), then " } else { '' }
        Say "job $($res.id) queued: $Lease #$($res.pos) of $($res.total) ($ahead); $($held)expected start about $(Local-Hm $res.start) (in $(Mins $res.start) min). It starts itself; no check-back needed." Green
        if ($nb) { Say 'a dispatch pass starts it once its time comes: keep the cop (or a watch window) running' }
    } else { Say "job $($res.id): $Lease was free; $($j.state) now" Green }
    if ($Lease -eq $CardLease) {
        $capT = $(if ($j.state -eq 'queued') { $res.start } else { [DateTime]::UtcNow }).AddMinutes((Cap-Span $est))
        Say "its cap falls about $(Local-Hm $capT), $(Cap-Span $est) min after it starts (2 x est + $CapPadMin). Past that with someone waiting, the cop stops it$(if ($LaneBreakOn) { " and cancels its lane's queued jobs" }); renew gpu -By $($res.runBy) -EstMin <n> moves it."
    }
    if ($Lease -eq $CardLease -and $script:BoundKeys -notcontains 'NoQuiet' -and $NoQuiet) { Say 'it does not wait for a quiet GPU; timed work (fps, load, frame cost) must add -Quiet' }
    if ($Preemptible) { Say "it is preemptible: a job of priority above $Priority, first in the $Lease queue, makes the cop stop it and queue it again" }
    if ($hint) { Say "estimate check: $hint." Yellow }
    Say "follow it: thor.ps1 job -JobId $($res.id)   (-Json for scripts, -Cancel to stop it; output in $($j.out))"
    exit 0
}
function Job-CapAt($J) { return (To-Utc $J.started).AddMinutes((Cap-Span ([double]$J.est))) }
function Dispatch-Pass {
    # Starts a lease's first ready waiter when it is a submitted job and nobody holds the lease (free, kept for that job). Safe to
    # call from any process: queued -> starting flips under the lease mutex, so a job starts once. Also settles jobs whose runner
    # died and queued jobs that fell out of the queue. The runner is `run -JobId` (waits for a quiet GPU, takes the lease tied to
    # itself, starts the command, releases, records the exit code).
    if (-not (Test-Path $JobDir)) { return @() }
    try { [void](Prune-Jobs) } catch {}
    $begun = @()
    foreach ($nm in $Names) {
        $go = With-Lock {
            $cur = Read-Lease $nm
            if ((Lease-State $cur) -eq 'live') { return $null }
            $q = Live-Queue $nm ''
            $first = Queue-First $q
            if (-not $first -or -not $first.job) { return $null }
            $j = Read-Job ([string]$first.job)
            if (-not $j -or [string]$j.state -ne 'queued') { return $null }
            $j.state = 'starting'; $j.started = Now-Iso; Write-Job $j
            Log-Line "dispatch $nm $($j.runBy) job $($j.id)$(if ($nm -eq $CardLease) { " cap ~$(Iso (Job-CapAt $j))" })$(if ($j.note) { " for: $($j.note)" })"
            return $j
        }
        if (-not $go) { continue }
        $host1 = (Get-Process -Id $PID).Path
        if ($host1 -notmatch '(?i)pwsh\.exe$|powershell\.exe$') { $host1 = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
        # Detached through WMI under a headless console: no window, and no inherited pipes, so a `submit` that starts a job at
        # once returns at once (a plain child would hold the caller's output pipe open until the job ended).
        $pf = if ($ProfileArg) { ' -ProfilePath "' + $ProfileArg + '"' } else { '' }
        $cl = "`"$(Join-Path $env:SystemRoot 'System32\conhost.exe')`" --headless `"$host1`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" run $nm -By $($go.runBy) -JobId $($go.id) -Dir `"$Dir`"$pf"
        $ca = @{ CommandLine = $cl }
        if ($go.cwd -and (Test-Path -LiteralPath $go.cwd)) { $ca.CurrentDirectory = [string]$go.cwd }
        try {
            $cr = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $ca -ErrorAction Stop
            if ($cr.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($cr.ReturnValue)" }
            [void](Set-Job $go.id @{ runPid = [int]$cr.ProcessId }); $begun += $go
        }
        catch {
            [void](Set-Job $go.id @{ state = 'failed'; ended = Now-Iso; why = "the runner did not start: $($_.Exception.Message)" })
            Drop-JobEntry $nm $go.runBy; Log-Line "job-failed $nm $($go.runBy) job $($go.id) (the runner did not start)"
        }
    }
    foreach ($j in (Recent-Jobs 13)) {
        $st = [string]$j.state
        if ($st -in @('starting', 'running')) {
            $age = if ($j.started) { ([DateTime]::UtcNow - (To-Utc $j.started)).TotalSeconds } else { 999 }
            $alive = $j.runPid -and (Get-Process -Id ([int]$j.runPid) -ErrorAction SilentlyContinue)
            if (-not $alive -and $age -gt 30) {
                if (Set-Job $j.id @{ state = 'lost'; ended = Now-Iso; why = 'its runner exited without reporting (killed, or the box restarted)' } @('starting', 'running')) {
                    Drop-JobEntry $j.lease $j.runBy; Log-Line "job-lost $($j.lease) $($j.runBy) job $($j.id)"
                }
            }
        } elseif ($st -eq 'queued') {
            $inq = @(Live-Queue ([string]$j.lease) '' | Where-Object { $_.job -eq $j.id }).Count
            $age = ([DateTime]::UtcNow - (To-Utc $j.submitted)).TotalSeconds
            if (-not $inq -and $age -gt 30) {
                if (Set-Job $j.id @{ state = 'expired'; ended = Now-Iso; why = "left the queue without starting (waited past $($j.timeoutMin) min, or unqueued)" } @('queued')) {
                    Log-Line "job-expired $($j.lease) $($j.runBy) job $($j.id)"
                }
            }
        }
    }
    return , $begun
}
function Stop-Tree([int]$Root) {
    # Kills a process and every descendant, deepest first. A child whose parent was reused (younger parent) is not followed.
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate -ErrorAction SilentlyContinue)
    $kids = @{}; $born = @{}
    foreach ($p in $all) { $born[[int]$p.ProcessId] = $p.CreationDate; $k = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($k)) { $kids[$k] = @() }; $kids[$k] += [int]$p.ProcessId }
    $order = New-Object Collections.Generic.List[int]; $stack = New-Object Collections.Generic.Stack[int]; $stack.Push($Root)
    while ($stack.Count) {
        $cur = $stack.Pop(); $order.Add($cur)
        foreach ($c in @($kids[$cur])) { if ($c -and $c -ne $cur -and (-not $born[$cur] -or $born[$c] -ge $born[$cur])) { $stack.Push($c) } }
    }
    for ($i = $order.Count - 1; $i -ge 0; $i--) { Stop-Process -Id $order[$i] -Force -ErrorAction SilentlyContinue }
}
function Stop-JobTree($Jb) {
    # Stops a running job: the command's whole tree first (a cmd /c or a launcher leaves children that keep running and hold the
    # output logs open), so the runner releases the lease itself; then the runner, if it is still there.
    if ($Jb.childPid) { Stop-Tree ([int]$Jb.childPid) }
    Start-Sleep -Seconds 3
    if ($Jb.runPid -and (Get-Process -Id ([int]$Jb.runPid) -ErrorAction SilentlyContinue)) {
        # runPid is the headless console; its runner is the pwsh under it.
        foreach ($rc in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$([int]$Jb.runPid)" -ErrorAction SilentlyContinue)) { Stop-Process -Id $rc.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id ([int]$Jb.runPid) -Force -ErrorAction SilentlyContinue
    }
}
function Job-Line($J) {
    $t = { param($v) if ($v) { Local-Hm $v } else { '--:--' } }
    $ex = if ($null -ne $J.exit) { " exit $($J.exit)" } else { '' }
    $wt = if ([string]$J.state -eq 'starting' -and $J.waiting) { "  [waits: $(Short ([string]$J.waiting) 70)]" } else { '' }
    return ('{0,-26} {1,-9} {2,-6} sub {3}  start {4}  end {5}{6}  {7}{8}' -f $J.id, $J.state, $J.lease, (& $t $J.submitted), (& $t $J.started), (& $t $J.ended), $ex, (Short ([string]$J.note) 60), $wt)
}
# ---- stats ---------------------------------------------------------------------------------------------------------------
function Job-Kind($J) {
    # What "a job like this one" means: the same lease, the same program and the same note with its numbers flattened, so run 3
    # and run 12 are one kind. With no note its arguments stand in.
    $leaf = [string]$J.exe; try { $leaf = [IO.Path]::GetFileName($leaf) } catch {}
    $what = if ([string]$J.note) { [string]$J.note } else { [string]$J.args }
    return ("$($J.lease)|$leaf|$(Short ($what -replace '\d+', '#') 80)").ToLower()
}
function Job-Ran($J) {
    # Minutes its command ran, or $null if it never ran or was cancelled. Counted from the take (took), so a wait for quiet isn't
    # billed to it; a job file from before that field has only its dispatch time.
    if (-not $J.ended -or [string]$J.state -notin @('done', 'failed', 'overrun')) { return $null }
    if ([string]$J.state -eq 'failed' -and $null -eq $J.exit) { return $null }
    $from = if ($J.took) { $J.took } else { $J.started }
    if (-not $from) { return $null }
    return [Math]::Max(0.0, ((To-Utc $J.ended) - (To-Utc $from)).TotalMinutes)
}
function Median($V) {
    $s = @($V | Sort-Object); $c = $s.Count
    if (-not $c) { return $null }
    if ($c % 2) { return [double]$s[[int](($c - 1) / 2)] }
    return ([double]$s[[int]($c / 2) - 1] + [double]$s[[int]($c / 2)]) / 2
}
function Job-Stats([double]$SinceDays, [string]$Root = '') {
    # One row per kind of job that ran in the window: what its estimates said against what it took. Worst ratio first.
    $acc = @()
    $jobs = @(Recent-Jobs ([int][Math]::Ceiling($SinceDays * 24)) | Where-Object { -not $Root -or (Lane-Root ([string]$_.by)) -eq $Root })
    foreach ($g in @($jobs | Group-Object { Job-Kind $_ })) {
        $ran = @($g.Group | ForEach-Object {
                $m = Job-Ran $_
                if ($null -ne $m) { [pscustomobject]@{ min = $m; est = [double]$_.est; state = [string]$_.state; wait = $(if ($_.took) { ((To-Utc $_.took) - (To-Utc $_.submitted)).TotalMinutes }) } }
            })
        if (-not $ran.Count) { continue }
        $k = [string]$g.Name -split '\|', 3
        $est = Median @($ran | ForEach-Object { $_.est }); $act = Median @($ran | ForEach-Object { $_.min })
        $waits = @($ran | Where-Object { $null -ne $_.wait } | ForEach-Object { $_.wait })
        $acc += [pscustomobject][ordered]@{
            key = [string]$g.Name; lease = $k[0]; what = "$($k[1]) $($k[2])".Trim(); n = $ran.Count
            est = [Math]::Round($est, 1); actual = [Math]::Round($act, 1); ratio = $(if ($est -gt 0) { [Math]::Round($act / $est, 2) } else { 0 })
            late = @($ran | Where-Object { $_.min -gt $_.est }).Count; overrun = @($ran | Where-Object { $_.state -eq 'overrun' }).Count
            wait = $(if ($waits.Count) { [Math]::Round((Median $waits), 1) })
        }
    }
    return @($acc | Sort-Object -Property @{ Expression = { [double]$_.ratio }; Descending = $true }, @{ Expression = { $_.n }; Descending = $true })
}
# ---- the box ------------------------------------------------------------------------------------------------------------
function Read-Fixture {
    if (-not $script:FixtureData) { $script:FixtureData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Fixture).Path, $Utf8) | ConvertFrom-Json }
    return $script:FixtureData
}
function Get-GpuSample {
    if ($Fixture) { $g = (Read-Fixture).gpu; if (-not $g) { return $null }; return [pscustomobject]@{ usedMB = [int]$g.usedMB; totalMB = [int]$g.totalMB; util = [int]$g.util } }
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    $line = & $smi.Source --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1
    $f = @($line -split ',' | ForEach-Object { $_.Trim() })
    if ($f.Count -lt 3) { return $null }
    [pscustomobject]@{ usedMB = [int]$f[0]; totalMB = [int]$f[1]; util = [int]$f[2] }
}
function Get-Gpu([int]$Samples = 3) {
    $s = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $g = Get-GpuSample
        if (-not $g) { return $null }
        $s += $g
        if ($i -lt $Samples - 1 -and -not $Fixture) { Start-Sleep -Milliseconds 700 }
    }
    # The lower middle of the sorted samples: with two samples that is the lower one.
    $u = @($s | ForEach-Object { $_.util } | Sort-Object)
    [pscustomobject]@{
        usedMB = ($s | Measure-Object usedMB -Maximum).Maximum
        totalMB = $s[0].totalMB
        util = $u[[int][Math]::Floor(($u.Count - 1) / 2)]
    }
}
function Short-Cmd([string]$Name, [string]$Cmd) {
    $c = $Cmd -replace '^\s*("[^"]+"|\S+)\s*', ''
    $c = $c -replace '-ini:Engine:\[/Script/PythonScriptPlugin\.PythonScriptPluginSettings\]:bRemoteExecution=False', '-NoRemote'
    $c = ($c -replace '\s+', ' ').Trim()
    if ($c.Length -gt 110) { $c = $c.Substring(0, 107) + '...' }
    return $c
}
$script:ProbeSeen = @{}
function Probe-Idle([string]$Kind) {
    # For a kind with an idleProbe in the profile (a daemon that is up with nothing loaded): true only when its status url answers
    # in time and the answer matches. No answer, a slow one or an error counts as busy. One ask per kind every 2 s.
    if (-not $Kind) { return $false }
    $kt = $Traits.kinds[$Kind]; if (-not $kt -or -not $kt.idleProbe) { return $false }
    $pr = $kt.idleProbe; $c = $script:ProbeSeen[$Kind]
    if ($c -and ([DateTime]::UtcNow - $c.at).TotalSeconds -lt 2) { return $c.idle }
    $idle = $false; $ms = if ($pr.timeoutMs) { [Math]::Min(5000, [Math]::Max(100, [int]$pr.timeoutMs)) } else { 1000 }
    try {
        $rq = [Net.WebRequest]::Create([string]$pr.url); $rq.Timeout = $ms; $rq.ReadWriteTimeout = $ms; $rq.Proxy = $null
        $rs = $rq.GetResponse()
        try { $body = (New-Object IO.StreamReader($rs.GetResponseStream())).ReadToEnd() } finally { $rs.Close() }
        $idle = [bool]($body -match [string]$pr.idle)
    } catch {}
    $script:ProbeSeen[$Kind] = @{ at = [DateTime]::UtcNow; idle = $idle }
    return $idle
}
function Get-Procs {
    if ($Fixture) {
        # Demo/test replay: processes from the fixture, start times relative to now (agoSec).
        $fx = Read-Fixture
        $all = @($fx.procs | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ ProcessId = [int]$_.pid; ParentProcessId = [int]$_.ppid; Name = [string]$_.name
                    CommandLine = [string]$_.cmd; CreationDate = (Get-Date).AddSeconds(-[double]$_.agoSec) } })
    } else { $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate }
    $script:ParentOf = @{}; $script:Info = @{}
    foreach ($p in $all) {
        $script:ParentOf[[int]$p.ProcessId] = [int]$p.ParentProcessId
        $script:Info[[int]$p.ProcessId] = @{ name = [string]$p.Name; cmd = [string]$p.CommandLine; parent = [int]$p.ParentProcessId
            started = $(if ($p.CreationDate) { ([DateTime]$p.CreationDate).ToUniversalTime() } else { [DateTime]::MinValue }) }
    }
    $out = foreach ($p in $all) {
        $n = [string]$p.Name; $c = [string]$p.CommandLine; $k = $null; $cpp = $false
        foreach ($r in $Traits.rules) {
            if (-not $r.name -or $n -notmatch $r.name) { continue }
            if ($r.cmd -and $c -notmatch $r.cmd) { continue }
            $k = $r.kind; $cpp = [bool]$r.cpp; break
        }
        if ($k) { [pscustomobject]@{ kind = $k; cpp = $cpp; idle = (Probe-Idle $k); pid = [int]$p.ProcessId; name = $n; cmd = (Short-Cmd $n $c); full = $c; started = $(if ($p.CreationDate) { ([DateTime]$p.CreationDate).ToUniversalTime() } else { [DateTime]::UtcNow }) } }
    }
    return @($out)
}
function Get-Leases {
    $h = [ordered]@{}
    foreach ($n in $Names) { $l = Read-Lease $n; $h[$n] = [pscustomobject]@{ lease = $l; state = (Lease-State $l) } }
    return $h
}
function Quiet-Reasons($Gpu, $Procs, $Leases, [int[]]$SkipPids = @()) {
    $r = New-Object Collections.Generic.List[string]
    $g = $Leases[$CardLease]
    if ($g.state -eq 'live' -and $g.lease.by -ne $By) { $r.Add("gpu lease: $(Describe-Lease $g.lease)") }
    if (-not $Gpu) { $r.Add('nvidia-smi gave no reading') }
    else {
        if ($Gpu.usedMB -gt $MaxVramGB * 1024) { $r.Add(('{0:N1} GB video memory in use (gate {1} GB)' -f ($Gpu.usedMB / 1024), $MaxVramGB)) }
        if ($Gpu.util -gt $MaxUtil) { $r.Add("GPU $($Gpu.util) % busy (gate $MaxUtil %)") }
    }
    $allowed = @{ AllowEditor = [bool]$AllowEditor; AllowBuild = [bool]$AllowBuild }
    foreach ($p in $Procs) {
        if ($SkipPids -contains $p.pid -or $p.idle) { continue }
        $kt = $Traits.kinds[[string]$p.kind]
        if (-not $kt -or -not $kt.noise) { continue }
        if ($kt.allow -and $allowed[$kt.allow]) { continue }
        $r.Add($kt.noise.Replace('{name}', [string]$p.name).Replace('{pid}', [string]$p.pid).Replace('{cmd}', [string]$p.cmd))
    }
    return , $r
}
function Wait-Quiet([DateTime]$Deadline) {
    # True once quiet held for SettleSec in a row; False at the deadline.
    $since = $null; $lastMsg = ''; $lastAt = [DateTime]::MinValue
    while ($true) {
        $reasons = Quiet-Reasons (Get-Gpu) (Get-Procs) (Get-Leases)
        if ($reasons.Count -eq 0) {
            if (-not $since) { $since = [DateTime]::UtcNow; Say "quiet; settling $SettleSec s" }
            if (([DateTime]::UtcNow - $since).TotalSeconds -ge $SettleSec) { return $true }
        } else {
            $since = $null
            $msg = $reasons -join '; '
            if ($msg -ne $lastMsg -or ([DateTime]::UtcNow - $lastAt).TotalSeconds -ge 60) {
                Say "waiting for a quiet GPU: $msg" Yellow; $lastMsg = $msg; $lastAt = [DateTime]::UtcNow
            }
        }
        if ([DateTime]::UtcNow -ge $Deadline) { return $false }
        Start-Sleep -Seconds 2
    }
}
function Wait-Lease([string]$Name, [int]$Min, [int]$TiePid, [DateTime]$Deadline, [bool]$NeedQuiet) {
    # run's and hold's wait: in the queue until the lease is ours to take; then, if asked, until the GPU has been quiet for
    # SettleSec; only then the take (header: Standing aside). Returns the take, or @{ ok = $false; code; msg; why } at the deadline.
    $script:LockWaitSec = 300
    $ready = -not $NeedQuiet; $park = ''; $since = $null; $said = [DateTime]::MinValue; $lastMsg = ''; $logged = $false; $parkedAt = $null; $warnAt = $null; $fails = 0
    while ($true) {
        try {
            if ($JobId) {
                $jn = With-Lock { Read-Job $JobId }
                if ($jn -and [string]$jn.state -ne 'starting') { [void](Do-Unqueue $Name); return @{ ok = $false; code = 1; msg = "job $JobId is $($jn.state): nothing started"; why = '' } }
            }
            $res = Try-Take $Name $Min $TiePid -Ready $ready -NeedQuiet $NeedQuiet -Park $park
            $fails = 0
            if ($res.ok) { return $res }
            $now = [DateTime]::UtcNow
            if (-not $res.turn) {
                $since = $null; $ready = -not $NeedQuiet
                if ($now -ge $Deadline) { [void](Do-Unqueue $Name); return @{ ok = $false; code = 2; msg = "gave up after $TimeoutMin min and left the queue; $(Wait-Text $res $Name)"; why = "gave up waiting for $Name after $TimeoutMin min" } }
                if (($now - $said).TotalSeconds -ge 60) { Say "waiting: $(Wait-Text $res $Name)" Yellow; $said = $now }
                Start-Sleep -Seconds 5
                continue
            }
            $reasons = Quiet-Reasons (Get-Gpu) (Get-Procs) (Get-Leases)
            if ($reasons.Count) {
                $since = $null; $ready = $false
                $msg = $reasons -join '; '
                if ($res.mine) { [void](Do-Release $Name); Say "your $Name lease is let go while the GPU is noisy; you keep a queue place" Yellow }
                if ($msg -ne $lastMsg -or ($now - $said).TotalSeconds -ge 60) {
                    Say "waiting for a quiet GPU, $Name left free: $msg" Yellow; $lastMsg = $msg; $said = $now
                    if ($JobId) { [void](Set-Job $JobId @{ waiting = "no quiet GPU: $msg" } @('starting')) }
                }
                if (-not $logged) { $logged = $true; $parkedAt = $now; $warnAt = $now.AddMinutes($ParkWarnMin); Log-Line "park $Name $By waiting for a quiet GPU, $Name left free: $(Short $msg 120)" }
                if ($now -ge $warnAt) {
                    Log-Line "park-long $Name $By $([int][Math]::Ceiling(($now - $parkedAt).TotalMinutes)) min waiting for a quiet GPU: $(Short $msg 100). Not a timing run? $(if ($JobId) { 'Cancel it and submit without -Quiet.' } else { 'Use -NoQuiet.' })"
                    $warnAt = $now.AddMinutes(60)
                }
                if ($park -ne 'quiet') { $park = 'quiet'; continue }
            } else {
                if (-not $since) {
                    $since = $now; Say "quiet; settling $SettleSec s"
                    if ($JobId) { [void](Set-Job $JobId @{ waiting = '' } @('starting')) }
                }
                if ($park) { $park = ''; continue }
                if (($now - $since).TotalSeconds -ge $SettleSec) { $ready = $true; continue }
            }
            if ($now -ge $Deadline) { [void](Do-Unqueue $Name); return @{ ok = $false; code = 3; msg = "no quiet GPU within $TimeoutMin min; left the $Name queue, nothing started"; why = "no quiet GPU within $TimeoutMin min" } }
            Start-Sleep -Seconds 2
        } catch {
            # Everything is in files and each look starts over, so a busy lock or a failed process list costs one look, not the job.
            $fails++
            Say "look failed, trying again ($fails): $($_.Exception.Message)" Yellow
            if ($fails -ge 30 -or [DateTime]::UtcNow -ge $Deadline) { return @{ ok = $false; code = 1; msg = "gave up after $fails failed looks: $($_.Exception.Message)"; why = "gave up after $fails failed looks: $($_.Exception.Message)" } }
            Start-Sleep -Seconds 5
        }
    }
}
function Lease-Busy([string]$Name, $L, $Procs) {
    # Is anything using this lease? A command it started, or anything of its kind on the box, whoever's it is: a false yes only keeps a lease a while longer.
    if ($L.childPid -and (Get-Process -Id ([int]$L.childPid) -ErrorAction SilentlyContinue)) { return $true }
    $lt = $Traits.leases[$Name]
    if (-not $lt) { return $true }
    if (@($Procs | Where-Object { -not $_.idle -and ($_.kind -in $lt.busy -or ($_.kind -in $lt.busyCpp -and $_.cpp)) }).Count) { return $true }
    if ($lt.card) { $card = Get-Gpu; return (-not $card) -or $card.util -gt $MaxUtil }
    return $false
}
function Reap-Pass($Procs, $Leases) {
    # Frees a lease nobody is using (header: the cop). Past its estimate and nothing running: the idle clock starts. Still idle after -ReapAfterMin with someone waiting: it goes.
    $out = @()
    if ($ReapAfterMin -le 0) { return , $out }
    foreach ($n in $Names) {
        $x = $Leases[$n]
        if ($x.state -ne 'live' -or -not $x.lease.eta) { continue }
        $L = $x.lease; $now = [DateTime]::UtcNow
        $idle = (To-Utc $L.eta) -lt $now -and -not (Lease-Busy $n $L $Procs)
        if (-not $idle -and -not $L.idleSince) { continue }
        $waiting = (Live-Queue $n ([string]$L.by)).Count
        if ($idle -and $L.idleSince -and $waiting -and ($now - (To-Utc $L.idleSince)).TotalMinutes -ge $ReapAfterMin) {
            $why = "past its estimate since $(Local-Hm $L.eta), nothing running since $(Local-Hm $L.idleSince), $waiting waiting"
            if ($CopDryRun) { Say "would release $n from $($L.by): $why" Yellow; continue }
            $gone = With-Lock {
                $cur = Read-Lease $n
                if (-not $cur -or $cur.by -ne $L.by -or [string]$cur.taken -ne [string]$L.taken -or -not $cur.idleSince) { return $false }
                Remove-Lease $n; Log-Line "reap $n $($L.by) ($why)"; return $true
            }
            if (-not $gone) { continue }
            $out += @{ lease = $n; by = $L.by; why = $why }
            Cop-Note ([string]$L.by) "released your $n lease: $why.`r`n[THOR COP] A lease covers the work, not the session. Take it again when the next step is ready, or renew -EstMin if the step is still going."
            continue
        }
        if ($CopDryRun -or $idle -eq [bool]$L.idleSince) { continue }
        # The mark goes on the lease file, so it survives a cop restart and status can show it. A renew writes a new lease, which clears it.
        With-Lock {
            $cur = Read-Lease $n
            if ($cur -and $cur.by -eq $L.by -and [string]$cur.taken -eq [string]$L.taken) {
                $cur | Add-Member -NotePropertyName idleSince -NotePropertyValue $(if ($idle) { Iso $now } else { $null }) -Force; Write-Lease $n $cur
            }
        } | Out-Null
    }
    return , $out
}
function Lane-Root([string]$Who) { return ($Who -split '\.')[0] }
function Cop-Note([string]$Who, [string]$Text) {
    # What the holder's agent reads, with -ScratchDir: <ScratchDir>\<who>\THOR_COP.txt, <who> being its -By root (ci.art0 -> ci).
    if (-not $ScratchDir) { return }
    $d = Join-Path $ScratchDir (Lane-Root $Who)
    if (Test-Path $d) { try { [IO.File]::AppendAllText((Join-Path $d 'THOR_COP.txt'), "`r`n[THOR COP] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text`r`n", $Utf8) } catch {} }
}
function Lane-Queued($Over, [string]$Name) {
    # The jobs of its lane still in this queue. A job parked for quiet reads as starting, but it has started nothing.
    $root = Lane-Root ([string]$Over.by); $out = @()
    foreach ($e in @(Read-Queue $Name)) {
        if (-not $e.job -or [string]$e.job -eq [string]$Over.id) { continue }
        $j = Read-Job ([string]$e.job)
        if ($j -and [string]$j.state -in @('queued', 'starting') -and (Lane-Root ([string]$j.by)) -eq $root) { $out += $j }
    }
    return $out
}
function Lane-Break($Over, [string]$Name) {
    # The lane breaker (header: the cop), off while $LaneBreakOn is. Runs before the lease frees and under the lock, so none of them can be dispatched first.
    if (-not $LaneBreakOn) { return '' }
    $why = "lane breaker: $($Over.runBy) (job $($Over.id)) went over its cap"
    $gone = With-Lock {
        $names = @()
        foreach ($j in @(Lane-Queued $Over $Name)) {
            $was = [string]$j.state
            $j.state = 'cancelled'; $j.ended = Now-Iso; $j.why = $why; Write-Job $j
            Log-Line "job-cancel $Name $($j.runBy) job $($j.id) (was $was; $why)"
            $names += [string]$j.runBy
        }
        if ($names.Count) { Write-Queue $Name @(Read-Queue $Name | Where-Object { $names -notcontains [string]$_.by }) }
        return ($names -join ', ')
    }
    if ($gone) { Cop-Note ([string]$Over.by) "cancelled your queued $Name jobs $($gone): $($Over.runBy) went over its cap, so their estimates are suspect too. Fix -EstMin and submit them again." }
    return $gone
}
function Asset-Writer([int]$Root, $Procs) {
    # A commandlet or an editor in the tree under $Root, from Get-Procs' table. A -game run isn't one: the cop already stops those, and it writes no assets.
    foreach ($p in @($Procs | Where-Object { $_.kind -in $NeverStop })) {
        $cur = $p.pid
        for ($i = 0; $i -lt 32; $i++) {
            if ($cur -eq $Root) { return $p }
            $me = $script:Info[$cur]; if (-not $me) { break }
            $par = $script:Info[$me.parent]
            if (-not $par -or $me.parent -eq $cur -or $par.started -gt $me.started) { break }
            $cur = $me.parent
        }
    }
    return $null
}
function Lease-Job($L, [string[]]$States = @('running')) {
    # The running job that holds a lease, or nothing for a plain take, run or hold. On a lease a job goes by its runBy; a name comes back only after its job ended, so the newest file wins.
    if ([string]$L.by -notmatch '\.j\d+$' -or -not (Test-Path $JobDir)) { return $null }
    foreach ($f in @(Get-ChildItem $JobDir -Filter "$($L.by)-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $j = Read-Job $f.BaseName
        if ($j -and [string]$j.runBy -eq [string]$L.by -and [string]$j.state -in $States) { return $j }
    }
    return $null
}
function Cap-Pass($Leases) {
    # Stops a gpu job past its cap with someone waiting (header: the cop). With a commandlet or an editor in its tree it only says so. Plain takes and the other leases go to Alarm-Pass.
    $out = @()
    $x = $Leases[$CardLease]
    if ($x.state -ne 'live') { return $out }
    $L = $x.lease; $now = [DateTime]::UtcNow
    $cap = Cap-At $L
    if (-not $cap -or $now -lt $cap) { return $out }
    $waiting = (Live-Queue $CardLease ([string]$L.by)).Count
    if (-not $waiting) { return $out }
    $j = Lease-Job $L
    if (-not $j -or -not $j.childPid) { return $out }
    if ($CopMatch -and "$($j.exe) $($j.args)" -notmatch $CopMatch) { return $out }
    $over = "held $([int]($now - (To-Utc $L.taken)).TotalMinutes) min on an estimate of $($L.est) min, past its cap $(Local-Hm $cap), $waiting waiting"
    # A fresh list, not the pass's: a chain may have started a commandlet in the seconds since.
    $writer = Asset-Writer ([int]$j.childPid) @(Get-Procs)
    if ($writer) {
        if ($j.overCap) { return $out }
        $what = "$($writer.kind) pid $($writer.pid) in its tree, not stopped"
        if ($CopDryRun) { Say "would log over-cap for job $($j.id) ($what): $over" Yellow; return $out }
        if (Set-Job $j.id @{ overCap = Now-Iso } @('running')) { Log-Line "over-cap gpu $($L.by) job $($j.id) ($what`: $over)" }
        $out += @{ job = $j.id; by = $L.by; stopped = $false; why = "$what`: $over" }
        return $out
    }
    if ($CopDryRun) {
        $sibs = if ($LaneBreakOn) { @(Lane-Queued $j $CardLease | ForEach-Object { [string]$_.runBy }) -join ', ' } else { '' }
        Say "would stop job $($j.id) ($over)$(if ($sibs) { " and cancel $sibs" })" Yellow
        return $out
    }
    $marked = With-Lock {
        # It may have renewed, or ended, since the look above. Marked first, so the runner's own ending can't write over it.
        $cur = Read-Lease $CardLease; $jn = Read-Job $j.id
        if (-not $cur -or $cur.by -ne $L.by -or [string]$cur.taken -ne [string]$L.taken -or [string]$cur.eta -ne [string]$L.eta) { return $false }
        if (-not $jn -or [string]$jn.state -ne 'running' -or -not (Get-Process -Id ([int]$j.childPid) -ErrorAction SilentlyContinue)) { return $false }
        $jn.state = 'overrun'; $jn.ended = Now-Iso; $jn.why = "stopped by the cop at its overrun cap: $over"; Write-Job $jn
        Log-Line "job-overrun gpu $($L.by) job $($j.id) ($over)"
        return $true
    }
    if (-not $marked) { return $out }
    $gone = Lane-Break $j $CardLease
    Stop-JobTree $j
    Cop-Note ([string]$j.by) "stopped your job $($j.id) at its overrun cap: $over.`r`n[THOR COP] The cap is 2 x -EstMin + $CapPadMin min. Submit it again with a true estimate; while a job runs, renew gpu -By $($L.by) -EstMin <n> moves its cap to 2 x n + $CapPadMin from then."
    $out += @{ job = $j.id; by = $L.by; stopped = $true; why = "$over$(if ($gone) { "; cancelled $gone" })" }
    return $out
}
function Requeue-Job($J) {
    # A preempted job's second go: a fresh job file with the same command and switches under the same name, first among its priority.
    return With-Lock {
        $now = [DateTime]::UtcNow; $n = [string]$J.lease
        $id = "$($J.runBy)-$($now.ToLocalTime().ToString('MMdd-HHmmss'))"
        $nj = $J | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $fresh = [ordered]@{ id = $id; state = 'queued'; why = "queued again after preemption (was $($J.id))"; submitted = Iso $now; started = $null; took = $null; ended = $null
            exit = $null; runPid = $null; childPid = $null; waiting = ''; notBefore = $null; preempts = [int]$J.preempts + 1
            log = (Join-Path $JobDir "$id.log"); out = (Join-Path $JobDir "$id.out.log"); err = (Join-Path $JobDir "$id.err.log") }
        foreach ($k in $fresh.Keys) { $nj | Add-Member -NotePropertyName $k -NotePropertyValue $fresh[$k] -Force }
        Write-Job $nj
        $cur = Read-Lease $n; $holder = if ((Lease-State $cur) -eq 'live') { [string]$cur.by } else { '' }
        $q = Live-Queue $n $holder
        $tmo = [double]$J.timeoutMin
        $me = [pscustomobject][ordered]@{ by = [string]$J.runBy; note = [string]$J.note; est = [double]$J.est; joined = $(if ($J.submitted) { [string]$J.submitted } else { IsoFine $now }); nextCheck = Iso $now.AddMinutes($tmo); until = Iso $now.AddMinutes($tmo); pid = $null; pidStart = $null; job = $id; needQuiet = -not [bool]$J.noQuiet; parked = ''; quietKey = "$([bool]$J.allowEditor)|$([bool]$J.allowBuild)|$($J.maxVramGB)|$($J.maxUtil)"; prio = [int]$J.prio; notBefore = $null }
        Write-Queue $n (Sort-Queue (@($q | Where-Object { $_.by -ne $J.runBy }) + @($me)))
        Log-Line "submit $n $($J.runBy) again job $id (after preemption of $($J.id))"
        return $id
    }
}
function Preempt-Pass($Leases) {
    # A running -Preemptible job gives way when a job of higher -Priority is first in its lease's queue (header: Later and first).
    $out = @()
    foreach ($n in $Names) {
        $x = $Leases[$n]
        if ($x.state -ne 'live') { continue }
        $L = $x.lease; $j = Lease-Job $L
        if (-not $j -or -not $j.preemptible -or -not $j.childPid) { continue }
        $first = Queue-First (Live-Queue $n ([string]$L.by))
        if (-not $first -or -not $first.job -or [int]$first.prio -le [int]$j.prio) { continue }
        if ($CopMatch -and "$($j.exe) $($j.args)" -notmatch $CopMatch) { continue }
        $why = "$($first.by) waits at priority $([int]$first.prio) and this preemptible job runs at $([int]$j.prio)"
        if ($CopDryRun) { Say "would preempt job $($j.id) ($why)" Yellow; continue }
        $marked = With-Lock {
            $cur = Read-Lease $n; $jn = Read-Job $j.id
            if (-not $cur -or $cur.by -ne $L.by -or [string]$cur.taken -ne [string]$L.taken) { return $false }
            if (-not $jn -or [string]$jn.state -ne 'running') { return $false }
            $jn.state = 'preempted'; $jn.ended = Now-Iso; $jn.why = "stopped by the cop: $why; queued again"; Write-Job $jn
            Log-Line "job-preempt $n $($L.by) job $($j.id) ($why)"
            return $true
        }
        if (-not $marked) { continue }
        Stop-JobTree $j
        $again = Requeue-Job $j
        Cop-Note ([string]$j.by) "preempted your job $($j.id): $why. It is queued again as $again and starts over when its turn comes."
        $out += @{ job = $j.id; again = $again; lease = $n; why = $why }
    }
    return , $out
}
function Alarm-Pass($Leases) {
    # A holder past its cap that Cap-Pass can't stop, with someone waiting: says so once per cap and stops nothing (header: the cop).
    $out = @()
    foreach ($n in $Names) {
        $x = $Leases[$n]
        if ($x.state -ne 'live' -or $x.lease.overCap) { continue }
        $L = $x.lease; $now = [DateTime]::UtcNow
        $cap = Cap-At $L
        if (-not $cap -or $now -lt $cap) { continue }
        $waiting = (Live-Queue $n ([string]$L.by)).Count
        if (-not $waiting) { continue }
        # A gpu job is the cap's. A job just stopped can keep its lease for a moment, until its runner lets go.
        $j = Lease-Job $L @('running', 'overrun', 'cancelled', 'preempted')
        if ($j -and ($n -eq $CardLease -or [string]$j.state -ne 'running')) { continue }
        if ($CopMatch -and $(if ($j) { "$($j.exe) $($j.args)" } else { "$($L.by) $($L.note)" }) -notmatch $CopMatch) { continue }
        $tag = if ($j) { " job $($j.id)" } else { '' }
        $over = "held $([int]($now - (To-Utc $L.taken)).TotalMinutes) min on an estimate of $($L.est) min, past its cap $(Local-Hm $cap), $waiting waiting"
        if ($CopDryRun) { Say "would log over-cap for $($L.by)'s $n lease$tag`: $over" Yellow; continue }
        $said = With-Lock {
            # It may have renewed, or ended, since the look above.
            $cur = Read-Lease $n
            if (-not $cur -or $cur.overCap -or $cur.by -ne $L.by -or [string]$cur.taken -ne [string]$L.taken -or [string]$cur.eta -ne [string]$L.eta) { return $false }
            $cur | Add-Member -NotePropertyName overCap -NotePropertyValue (Now-Iso) -Force; Write-Lease $n $cur
            Log-Line "over-cap $n $($L.by)$tag (not stopped: $over)"
            return $true
        }
        if (-not $said) { continue }
        Cop-Note ([string]$L.by) "your $n lease is past its overrun cap: $over. Nothing was stopped.`r`n[THOR COP] Done with it? release $n -By $($L.by). Still working? renew $n -By $($L.by) -EstMin <minutes left>, so the queue's times are true."
        $out += @{ lease = $n; by = $L.by; job = $(if ($j) { $j.id }); why = $over }
    }
    return $out
}
function Status-Queue([string]$Name, $X) {
    $holder = if ($X.state -eq 'live') { [string]$X.lease.by } else { '' }
    $q = Live-Queue $Name $holder
    $plan = Plan-Queue $q (Free-At $X.lease $X.state)
    return @($plan | ForEach-Object { [pscustomobject]@{ by = $_.e.by; note = $_.e.note; est = $_.e.est; joined = $_.e.joined; start = Iso $_.start; nextCheck = $_.e.nextCheck; until = $_.e.until; job = $_.e.job; needQuiet = $_.e.needQuiet; parked = $_.e.parked; quietKey = $_.e.quietKey; prio = [int]$_.e.prio; notBefore = $_.e.notBefore } })
}
# ---- watch: the live board ---------------------------------------------------------------------------------------------
function Lease-Of([int]$P, $LeasePids) {
    # The lease covering a process: its own pid or one of its first four ancestors holds or runs under a lease.
    $cur = $P
    for ($i = 0; $i -lt 5 -and $cur; $i++) {
        if ($LeasePids.ContainsKey($cur)) { return $LeasePids[$cur] }
        if (-not $script:ParentOf -or -not $script:ParentOf.ContainsKey($cur)) { break }
        $next = $script:ParentOf[$cur]; if ($next -eq $cur) { break }; $cur = $next
    }
    return $null
}
function Short([string]$S, [int]$N) {
    $S = ($S -replace '\s+', ' ').Trim()
    if ($S.Length -gt $N) { return $S.Substring(0, $N - 1) + '~' }
    return $S
}
function In-Min([DateTime]$T) {
    $m = [int][Math]::Round(($T - [DateTime]::UtcNow).TotalMinutes)
    if ($m -ge 0) { return "in ${m}m" } else { return "$(-$m)m ago" }
}
function Take-Mutex($M) {
    # Non-blocking; a mutex abandoned by a killed cop window counts as taken (it is ours after the exception).
    try { return $M.WaitOne(0) }
    catch { $e = $_.Exception; while ($e) { if ($e -is [Threading.AbandonedMutexException]) { return $true }; $e = $e.InnerException }; return $false }
}
function Is-AgentRun([string]$Cmd) {
    # Automation markers: what agent launch scripts pass and a human's double-click never does. Add yours with
    # $env:THOR_AGENT_MARKERS (a regex), e.g. '-MyAgentFlag|-CaptureScript='.
    if ($env:THOR_AGENT_MARKERS -and $Cmd -match $env:THOR_AGENT_MARKERS) { return $true }
    return $Cmd -match '(?i)bRemoteExecution=False|-ExecCmds=|-abslog=|(^|\s)-log=|-ResX='
}
function Ancestors([int]$P, [int]$Depth = 10) {
    # Live ancestors from Get-Procs' table. A parent must be older than its child, else the pid was reused and the chain ends.
    $out = @(); $cur = $P
    for ($i = 0; $i -lt $Depth; $i++) {
        $me = $script:Info[$cur]; if (-not $me) { break }
        $pp = $me.parent; $par = $script:Info[$pp]
        if (-not $par -or $pp -eq $cur -or $par.started -gt $me.started) { break }
        $out += $par; $cur = $pp
    }
    return , $out
}
function Origin($P) {
    # 'agent', 'human' or 'unknown'. Agent: an automation marker on the command line, or a known agent host up its parent
    # chain. Human: a shell or IDE up the chain (explorer, Windows Terminal, Visual Studio, Rider, VS Code). Unknown: the
    # chain broke first (a launcher that exited; agents' background runs).
    if (Is-AgentRun $P.full) { return 'agent' }
    foreach ($a in (Ancestors $P.pid)) {
        if ($a.name -match '(?i)^(claude|codex|cursor-agent|aider)\.exe$' -or $a.cmd -match '(?i)\\Claude Extensions\\|@anthropic-ai[\\/]claude-code|@openai[\\/]codex') { return 'agent' }
        if ($a.name -match '(?i)^(explorer|WindowsTerminal|devenv|rider64|Code|Cursor)\.exe$') { return 'human' }
    }
    return 'unknown'
}
function Is-Agent($P) { return (Origin $P) -eq 'agent' }
function Is-StrikeBuild($P) {
    # A C++ build is struck unless it is a human's or the editor's (live coding, hot reload): builds are only logged, never
    # stopped, so an unknown origin counts as an agent's.
    if ((Origin $P) -eq 'human') { return $false }
    foreach ($a in (Ancestors $P.pid)) { if ($a.name -ieq 'UnrealEditor.exe') { return $false } }
    return $true
}
function Run-Session($P) {
    # Which agent launched it: -By <who> on it or an ancestor, else a <ScratchDir>\<who> path; '?' if none.
    $cmds = @($P.full) + @((Ancestors $P.pid) | ForEach-Object { $_.cmd })
    $rxs = @('(?i)-By\s+[''"]?([a-z0-9][a-z0-9_.-]{0,31})')
    if ($ScratchDir) { $rxs += '(?i)' + [regex]::Escape($ScratchDir.TrimEnd('\')) + '[\\/]+([a-z0-9][a-z0-9_.-]{0,31})(?=[\\/])' }
    foreach ($rx in $rxs) {
        foreach ($c in $cmds) { if ($c -match $rx) { return $Matches[1].ToLower() } }
    }
    return '?'
}
function Tell-Agent($P, [string]$Sess, [string]$Why) {
    # The stopped run's agent reads its own log: the reason and the fix go at the end of its -abslog file, and into
    # <ScratchDir>\<who>\THOR_COP.txt when -ScratchDir is set and the agent is known.
    $by = if ($Sess -ne '?') { $Sess } else { '<who>' }
    $txt = "`r`n[THOR COP] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') stopped this run (pid $($P.pid)): $Why.`r`n" +
        "[THOR COP] A -game or packaged run takes the gpu lease (the editor lease never covers one). Rerun it under the lease: " +
        "& thor.ps1 hold gpu -By $by -For '<what>' -EstMin <min> in the launcher, thor.ps1 run -By $by -Exe <exe> -ArgList '<args>', " +
        "or queue it: thor.ps1 submit gpu -By $by -Exe <exe> -ArgList '<args>' -EstMin <min>.`r`n"
    $files = @()
    if ($P.full -match '(?i)-abslog=("([^"]+)"|(\S+))') { $files += $(if ($Matches[2]) { $Matches[2] } else { $Matches[3] }) }
    if ($ScratchDir -and $Sess -ne '?') { $d = Join-Path $ScratchDir $Sess; if (Test-Path $d) { $files += (Join-Path $d 'THOR_COP.txt') } }
    foreach ($f in $files) {
        try { if (-not (Test-Path (Split-Path -Parent $f))) { continue } } catch { continue }
        for ($i = 0; $i -lt 8; $i++) { try { [IO.File]::AppendAllText($f, $txt, $Utf8); break } catch { Start-Sleep -Milliseconds 250 } }
    }
}
function Has-Lease([string]$Tag, [string]$Name) {
    # True when a coverage tag ("gpu agent1", or several joined: "gpu agent1 + build agent1") includes the named lease.
    return @($Tag -split ' \+ ' | Where-Object { $_ -like "$Name *" }).Count -gt 0
}
function Coverage($Procs, $Leases) {
    # pid -> 'gpu agent1' for each process a lease covers. By pid: the lease's pid or child pid, or a descendant of either.
    # A gpu lease with no pid covers the oldest -game/packaged run started after it was taken (agent runs first); the
    # editor and build leases cover the editor and build processes.
    $cov = @{}; $lp = @{}
    foreach ($n in $Names) {
        $x = $Leases[$n]; if ($x.state -ne 'live') { continue }
        # One process can hold several leases (build + gpu on one launcher): keep them all, joined with " + ", or the
        # last one written hides the others and the cop stops a covered run.
        foreach ($q in @($x.lease.pid, $x.lease.childPid)) {
            if (-not $q) { continue }
            $tag = "$n $($x.lease.by)"; $k = [int]$q
            if (-not $lp.ContainsKey($k)) { $lp[$k] = $tag } elseif (-not (Has-Lease $lp[$k] $n)) { $lp[$k] = "$($lp[$k]) + $tag" }
        }
    }
    foreach ($p in $Procs) { $o = Lease-Of $p.pid $lp; if ($o) { $cov[$p.pid] = $o } }
    $g = $Leases[$CardLease]
    if ($g.state -eq 'live' -and -not $g.lease.pid) {
        $t0 = (To-Utc $g.lease.taken).AddSeconds(-60)
        $cand = @($Procs | Where-Object { $_.kind -in $Traits.leases[$CardLease].enforce -and -not $cov.ContainsKey($_.pid) -and $_.started -ge $t0 } |
            Sort-Object { -not (Is-Agent $_) }, started)
        if ($cand.Count) { $cov[$cand[0].pid] = "$CardLease $($g.lease.by)" }
    }
    foreach ($n in $Names) {
        $x = $Leases[$n]
        if ($x.state -eq 'live') { foreach ($p in $Procs) { if ($p.kind -in $Traits.leases[$n].covers -and -not $cov.ContainsKey($p.pid)) { $cov[$p.pid] = "$n $($x.lease.by)" } } }
    }
    return $cov
}
function Run-Tag($P, $Cov) {
    if ($Cov.ContainsKey($P.pid)) { return @{ t = $Cov[$P.pid]; k = 'ok' } }
    if ($P.kind -in @('game', 'packaged')) {
        $o = Origin $P
        if ($o -eq 'human') { return @{ t = 'YOU'; k = 'human' } }
        if ($o -eq 'unknown') { return @{ t = 'unknown'; k = 'unk' } }
    }
    if ($P.kind -in @('editor', 'game', 'packaged', 'commandlet')) { return @{ t = 'NO LEASE'; k = 'bad' } }
    return @{ t = ''; k = 'none' }
}
function Cop-Pass($Procs, $Leases) {
    # Stops agent -game/packaged runs the gpu lease doesn't cover and logs agent C++ builds without the build lease
    # (rules in the header). Returns @{ killed; spared; struck }.
    $now = [DateTime]::UtcNow; $out = @{ killed = @(); spared = @(); struck = @() }
    # -CopMatch narrows the whole pass (coverage too), so a test never sees, or hands a pid-less lease to, a real run.
    $mine = @($Procs | Where-Object { -not $CopMatch -or $_.full -match $CopMatch })
    $cov = Coverage $mine $Leases
    $g = $Leases[$CardLease]; $gl = if ($g.state -eq 'live') { $g.lease } else { $null }
    $runs = @($mine | Where-Object { $_.kind -in $Traits.leases[$CardLease].enforce } | Sort-Object started)
    $uncov = @($runs | Where-Object { -not (Has-Lease ([string]$cov[$_.pid]) $CardLease) })
    $allowed = $null
    if ($CopLenient -and -not $gl) { $allowed = @($uncov | Where-Object { Is-Agent $_ }) | Select-Object -First 1 }
    foreach ($p in $uncov) {
        if ($allowed -and $p.pid -eq $allowed.pid) { continue }
        if (-not (Is-Agent $p)) { $out.spared += $p; continue }
        if (($now - $p.started).TotalSeconds -lt $CopGraceSec) { continue }
        $sess = Run-Session $p
        $why = if ($gl) { "the gpu lease is $($gl.by)'s and doesn't cover it" }
               elseif ($allowed) { "no gpu lease and pid $($allowed.pid) was running first" }
               else { 'it ran without the gpu lease' }
        $el = $Leases['editor']
        if ($el.state -eq 'live' -and (Has-Lease ([string]$cov[$p.pid]) 'editor')) { $why += " (the editor lease $($el.lease.by) holds doesn't cover a -game run)" }
        if ($CopDryRun) { Say "would stop pid $($p.pid) [$sess] ($why): $($p.cmd)" Yellow; continue }
        try { Stop-Process -Id $p.pid -Force -ErrorAction Stop } catch { continue }
        Log-Line "cop-kill gpu $($p.pid) $sess ($why): $($p.cmd)"; $out.killed += $p
        Start-Sleep -Milliseconds 300; Tell-Agent $p $sess $why
    }
    # Strikes: a lease's strike kinds running without it go in lease.log, once per process, and are never stopped (a killed link
    # can leave broken binaries for everyone). A kind in busyCpp counts only as a C++ build: cargo locks its own target dir.
    # A probed daemon works for whoever calls it over http, so it is struck while busy with nobody on the lease, again after
    # each idle spell.
    foreach ($ln in $Names) {
        $lt = $Traits.leases[$ln]; $sk = @($lt.strike)
        if (-not $sk.Count) { continue }
        foreach ($p in @($mine | Where-Object { $_.kind -in $sk -and ($_.kind -notin @($lt.busyCpp) -or $_.cpp) })) {
            $key = "$ln/$($p.pid)"; $daemon = [bool]$Traits.kinds[[string]$p.kind].idleProbe
            if ($daemon -and $p.idle) { $script:Struck.Remove($key); continue }
            if ($cov.ContainsKey($p.pid) -or $script:Struck.ContainsKey($key)) { continue }
            if ($daemon) {
                if ($Leases[$ln].state -eq 'live') { continue }
                $sess = '?'; $what = "a busy $($p.kind) daemon with nobody on the $ln lease"
            } else {
                if (-not (Is-StrikeBuild $p)) { continue }
                if (($now - $p.started).TotalSeconds -lt $CopGraceSec) { continue }
                $sess = Run-Session $p
                $what = if ($p.cpp) { "a C++ build without the $ln lease" } else { "a $($p.kind) run without the $ln lease" }
            }
            if ($CopDryRun) { Say "would log a strike: pid $($p.pid) [$sess] $($what): $($p.cmd)" Yellow; continue }
            $script:Struck[$key] = 1
            Log-Line "strike $ln $($p.pid) $sess ($what; not stopped): $($p.name) $($p.cmd)"; $out.struck += $p
        }
    }
    return $out
}
function Strikes-Today {
    # session -> count of cop-kill and strike lines in lease.log since local midnight.
    $h = [ordered]@{}
    if (-not (Test-Path $LogFile)) { return $h }
    $mid = [DateTime]::Today.ToUniversalTime()
    foreach ($ln in @(Get-Content $LogFile -Tail 4000 -ErrorAction SilentlyContinue)) {
        if ($ln -notmatch '^(\S+) (cop-kill|strike) \S+ \d+ ?([a-z0-9][a-z0-9_.-]{0,31}|\?)?') { continue }
        $t1 = $Matches[1]; $who = if ($Matches[3]) { $Matches[3] } else { '?' }
        try { if ((To-Utc $t1) -lt $mid) { continue } } catch { continue }
        if ($h.Contains($who)) { $h[$who]++ } else { $h[$who] = 1 }
    }
    return $h
}
function Read-LogTail([int]$N) {
    if (-not (Test-Path $LogFile)) { return @() }
    $rows = foreach ($ln in @(Get-Content $LogFile -Tail $N -ErrorAction SilentlyContinue)) {
        if ($ln -match '^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$') {
            $m1 = $Matches[1]; $v = $Matches[2]; $m3 = $Matches[3]; $m4 = $Matches[4]; $m5 = $Matches[5]
            $t = try { (To-Utc $m1).ToLocalTime().ToString('HH:mm:ss') } catch { $m1 }
            $rest = [regex]::Replace($m5, '\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z', [Text.RegularExpressions.MatchEvaluator] { param($mm) try { Local-Hm $mm.Value } catch { $mm.Value } })
            [pscustomobject]@{ t = $t; verb = $v; lease = $m3; by = $m4; rest = $rest }
        } else { [pscustomobject]@{ t = ''; verb = ''; lease = ''; by = ''; rest = $ln } }
    }
    return @($rows)
}
function Build-Groups($Procs, $Cov) {
    # Build work as board rows: C++ (UBT/UAT; takes the build lease) and compile (cargo, rustc, shader workers; no lease).
    $out = @()
    foreach ($grp in @(@{ label = 'c++ build'; cpp = $true }, @{ label = 'compile'; cpp = $false })) {
        $ps = @($Procs | Where-Object { $_.kind -eq 'build' -and [bool]$_.cpp -eq $grp.cpp })
        if (-not $ps.Count) { continue }
        $names = ($ps | Group-Object name | ForEach-Object { "$($_.Name -replace '\.exe$', '') x$($_.Count)" }) -join ', '
        $own = $ps | ForEach-Object { $Cov[$_.pid] } | Where-Object { $_ } | Select-Object -First 1
        if (-not $grp.cpp) { $tg = @{ t = 'no lease'; k = 'free' } }
        elseif ($own) { $tg = @{ t = $own; k = 'ok' } }
        elseif (@($ps | Where-Object { Is-StrikeBuild $_ }).Count) { $tg = @{ t = 'NO LEASE'; k = 'bad' } }
        else { $tg = @{ t = 'YOU'; k = 'human' } }
        $out += @{ label = $grp.label; names = $names; tag = $tg }
    }
    return , $out
}
function Sink-Err([string]$Msg) { try { [IO.File]::AppendAllText((Join-Path $Dir 'sinks.err.log'), "$(Now-Iso) $Msg`r`n", $Utf8) } catch {} }
function Run-Hook($H, $Ev) {
    # A hook starts detached and windowless, and inherits none of the cop's handles. The event reaches it only as environment
    # (THOR_AT, THOR_EVENT, THOR_LEASE, THOR_BY, THOR_TEXT, THOR_LINE), never spliced into its command line.
    $vars = @($Ev.Keys | ForEach-Object { 'THOR_' + $_.ToUpper() }); $was = @{}
    foreach ($k in @($Ev.Keys)) { $nm = 'THOR_' + $k.ToUpper(); $was[$nm] = [Environment]::GetEnvironmentVariable($nm); [Environment]::SetEnvironmentVariable($nm, [string]$Ev[$k]) }
    try {
        $sp = @{ FilePath = [string]$H.exe; WindowStyle = 'Hidden' }
        if ([string]$H.args) { $sp.ArgumentList = [string]$H.args }
        Start-Process @sp
    } catch { Sink-Err "hook $($H.exe): $($_.Exception.Message)" }
    finally { foreach ($nm in $vars) { [Environment]::SetEnvironmentVariable($nm, $was[$nm]) } }
}
function Post-Hook([string]$Url, $Ev) {
    # One POST of the whole event as JSON, 3 s at most, so a dead endpoint costs the cop a pass and nothing else. The line carries
    # command lines and local paths: that is why the url lives in the environment and on no disk.
    try {
        $body = $Utf8.GetBytes(([pscustomobject]$Ev | ConvertTo-Json -Compress))
        $rq = [Net.WebRequest]::Create($Url); $rq.Method = 'POST'; $rq.ContentType = 'application/json'; $rq.Timeout = 3000; $rq.ReadWriteTimeout = 3000
        $st = $rq.GetRequestStream(); try { $st.Write($body, 0, $body.Length) } finally { $st.Close() }
        $rs = $rq.GetResponse(); $rs.Close()
    } catch { Sink-Err "webhook: $($_.Exception.Message)" }
}
function Sink-Pass {
    # Hands each new lease.log line to the profile's hooks, to $env:THOR_WEBHOOK_URL (filtered by $env:THOR_WEBHOOK_ON, a regex on
    # the event) and, under cop -Toast, to a toast. Only a cop runs it, one at a time. sinks.pos keeps its place across cop restarts;
    # the first pass on a state folder starts at the log's end, so nothing old floods out. Sink failures go to sinks.err.log, not
    # lease.log, which feeds the sinks.
    $wh = [string]$env:THOR_WEBHOOK_URL
    if (-not $Hooks.Count -and -not $wh -and -not $Toast) { return 0 }
    if (-not (Test-Path -LiteralPath $LogFile)) { return 0 }
    $pf = Join-Path $Dir 'sinks.pos'; $len = (Get-Item -LiteralPath $LogFile).Length
    $raw = if (Test-Path -LiteralPath $pf) { ([IO.File]::ReadAllText($pf)).Trim() } else { '' }
    $pos = if ($raw -match '^\d+$') { [long]$raw } else { -1 }
    if ($pos -lt 0 -or $pos -gt $len) { $pos = $len }
    if ($pos -eq $len) { if ($raw -ne [string]$len) { [IO.File]::WriteAllText($pf, [string]$len) }; return 0 }
    $buf = New-Object byte[] ([int]($len - $pos)); $got = 0
    $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
    try { [void]$fs.Seek($pos, 'Begin'); while ($got -lt $buf.Length) { $r = $fs.Read($buf, $got, $buf.Length - $got); if ($r -le 0) { break }; $got += $r } } finally { $fs.Dispose() }
    $txt = $Utf8.GetString($buf, 0, $got); $cut = $txt.LastIndexOf("`n")
    if ($cut -lt 0) { return 0 }
    $txt = $txt.Substring(0, $cut + 1)
    [IO.File]::WriteAllText($pf, [string]($pos + $Utf8.GetByteCount($txt)))
    $n = 0; $toasts = @()
    foreach ($ln in ($txt -split "`r?`n")) {
        if ($ln -notmatch '^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$') { continue }
        $ev = [ordered]@{ at = $Matches[1]; event = $Matches[2]; lease = $Matches[3]; by = $Matches[4]; text = $Matches[5]; line = $ln }
        foreach ($h in $Hooks) { if ($ev.event -match [string]$h.on) { Run-Hook $h $ev; $n++ } }
        if ($wh -and (-not $env:THOR_WEBHOOK_ON -or $ev.event -match $env:THOR_WEBHOOK_ON)) { Post-Hook $wh $ev; $n++ }
        if ($Toast -and ($ev.event -match '^(cop-kill|strike|lapse|dequeue|dispatch|job-|over-cap|reestimate|reap|park-long)' -or $ln -match ' forced')) { $toasts += Short "$($ev.event) $($ev.lease) $($ev.by) $($ev.text)" 160 }
    }
    if ($toasts.Count) {
        $title = if ($toasts.Count -gt 1) { "THOR traffic: $($toasts.Count) changes" } else { 'THOR traffic' }
        Show-Toast $title @(@($toasts[0]) + @(if ($toasts.Count -gt 1) { ($toasts | Select-Object -Skip 1) -join ' | ' }))
    }
    return $n
}
function Board-Model {
    $m = @{ now = [DateTime]::UtcNow }
    $m.gpu = Get-Gpu 2; $m.procs = Get-Procs; $m.leases = Get-Leases
    if ($script:CopOn) {
        $cp = Cop-Pass $m.procs $m.leases
        if ($cp.killed.Count) { $script:CopKills += $cp.killed.Count; Start-Sleep -Milliseconds 800; $m.procs = Get-Procs; $m.gpu = Get-Gpu 2 }
    }
    if ($script:CopOn) { try { if ((Reap-Pass $m.procs $m.leases).Count) { $m.leases = Get-Leases } } catch {} }
    if ($script:CopOn) { try { if (@(Cap-Pass $m.leases).Count) { $m.leases = Get-Leases; $m.procs = Get-Procs } } catch {} }
    if ($script:CopOn) { try { if (@(Preempt-Pass $m.leases).Count) { $m.leases = Get-Leases; $m.procs = Get-Procs } } catch {} }
    if ($script:CopOn) { try { if (@(Alarm-Pass $m.leases).Count) { $m.leases = Get-Leases } } catch {} }
    if ($script:CopOn) { try { if ((Dispatch-Pass).Count) { $m.leases = Get-Leases } } catch {} }
    if ($script:CopOn) { try { [void](Sink-Pass) } catch {} }
    $m.cov = Coverage $m.procs $m.leases
    $m.reasons = Quiet-Reasons $m.gpu $m.procs $m.leases
    $m.queues = @{}; foreach ($n in $Names) { $m.queues[$n] = @(Status-Queue $n $m.leases[$n]) }
    $m.log = Read-LogTail $LogLines
    $m.strikes = Strikes-Today
    return $m
}
function Cop-Text {
    if ($script:CopOn) { return "on in this window ($(if ($CopLenient) { 'lenient' } else { 'strict' })): stops agent -game/packaged runs without the gpu lease after $CopGraceSec s (stopped: $($script:CopKills))" }
    if ($script:CopNote) { return $script:CopNote }
    return 'off (-NoCop)'
}
function Board-Lines($M) {
    # Plain frame (for -Once, -Plain and consoles without colour codes) as @{t=text; c=color} rows.
    $rows = New-Object Collections.Generic.List[object]
    function Row([string]$T, [string]$C = 'Gray') { $rows.Add(@{ t = $T; c = $C }) }
    $now = $M.now; $gpu = $M.gpu; $reasons = $M.reasons
    Row ("THOR TRAFFIC   {0}   refresh {1} s   Ctrl+C quits" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Every) 'White'
    if ($gpu) {
        $f = [Math]::Min([double]1, [double]$gpu.usedMB / [Math]::Max([double]1, [double]$gpu.totalMB)); $n = [int][Math]::Round($f * 20)
        Row ("GPU  {0,4:N1} / {1:N1} GB  [{2}{3}]  {4,3} % busy      Quiet GPU: {5}" -f ($gpu.usedMB / 1024), ($gpu.totalMB / 1024), ('#' * $n), ('-' * (20 - $n)), $gpu.util, $(if ($reasons.Count) { 'NO' } else { 'yes' })) $(if ($reasons.Count) { 'Yellow' } else { 'Green' })
    } else { Row 'GPU  no nvidia-smi reading' 'Yellow' }
    Row "GPU COP: $(Cop-Text)" $(if ($script:CopOn) { 'Magenta' } else { 'DarkGray' })
    if ($M.strikes.Count) { Row ("STRIKES today (runs stopped + C++ builds without the lease): " + (($M.strikes.Keys | ForEach-Object { "$_ x$($M.strikes[$_])" }) -join ', ')) 'Red' }
    Row ('-' * 100) 'DarkGray'
    foreach ($n in $Names) {
        $x = $M.leases[$n]; $L = $x.lease; $q = $M.queues[$n]
        if ($x.state -eq 'live') {
            Row ("{0,-7} {1}{2}" -f $n.ToUpper(), $L.by, $(if ($L.note) { "  '$($L.note)'" } else { '' })) 'Cyan'
            $bits = @("since $(Local-Hm $L.taken)"); $c = 'Gray'
            if ($L.eta) {
                $eta = To-Utc $L.eta
                if ($eta -gt $now) { $bits += "done ~$(Local-Hm $eta) ($(In-Min $eta))" } else { $bits += "PAST its estimate by $([int]($now - $eta).TotalMinutes)m (est $($L.est)m)"; $c = 'Red' }
            }
            $bits += "expires $(Local-Hm $L.until) ($(In-Min (To-Utc $L.until)))"
            if ($L.pid) { $bits += "tied to pid $($L.pid)" }
            Row ('        ' + ($bits -join '  |  ')) $c
        } else {
            $first = Queue-First $q
            $kept = if ($first) { "  - kept for $($first.by), first in line, until $(Local-Hm $first.until)" } else { '' }
            $tail = if ($x.state -ne 'none') { "  ($($L.by)'s lease $($x.state))" } else { '' }
            Row ("{0,-7} free{1}{2}" -f $n.ToUpper(), $kept, $tail) $(if ($first) { 'Yellow' } else { 'Green' })
        }
        $k = 0
        foreach ($w in $q) {
            $k++; $back = To-Utc $w.nextCheck; $late = $back -lt $now
            $when = if ($w.parked) { 'stands aside: waiting for a quiet GPU' } elseif ($late) { "LATE: checks back by $(Local-Hm $back), drops at $(Local-Hm $w.until)" } else { "checks back $(Local-Hm $back) ($(In-Min $back))" }
            Row ("    {0}. {1,-6} {2,-34} ~{3,3}m   starts ~{4} ({5})   {6}" -f $k, $w.by, $(if ($w.note) { "'$(Short $w.note 32)'" } else { '' }), [int][double]$w.est, (Local-Hm $w.start), (In-Min (To-Utc $w.start)), $when) $(if ($late) { 'Red' } else { 'Yellow' })
        }
    }
    Row ('-' * 100) 'DarkGray'
    Row 'RUNNING' 'White'
    if ($M.procs.Count -eq 0) { Row '  nothing on the watch list: no editor, game, LLM, image generation or build' 'DarkGray' }
    foreach ($p in ($M.procs | Where-Object { $_.kind -ne 'build' })) {
        $tg = Run-Tag $p $M.cov
        Row ("  {0,-10} {1,6}  {2,-12} {3}" -f $p.kind, $p.pid, $(if ($tg.t) { "[$($tg.t)]" } else { '' }), $p.cmd) $(if ($tg.k -eq 'bad') { 'Red' } else { 'Gray' })
    }
    foreach ($bg in (Build-Groups $M.procs $M.cov)) {
        Row ("  {0,-10} {1,6}  {2,-12} {3}" -f $bg.label, '', "[$($bg.tag.t)]", $bg.names) $(if ($bg.tag.k -eq 'bad') { 'Red' } else { 'Gray' })
    }
    if ($reasons.Count) { Row 'NOT QUIET (what a timing run would wait on)' 'Yellow'; foreach ($r in $reasons) { Row "  - $r" 'Yellow' } }
    else { Row 'QUIET: a timing run could start now' 'Green' }
    Row ('-' * 100) 'DarkGray'
    Row "RECENT  ($LogFile)" 'White'
    if (-not $M.log.Count) { Row '  (no log yet)' 'DarkGray' }
    foreach ($e in $M.log) {
        $c = switch -Regex ($e.verb) { '^take|^renew' { 'Cyan' } '^queue' { 'Yellow' } '^dequeue|^lapse|forced|^cop|^reap|^park-long|^job-overrun|^over-cap' { 'Red' } default { 'Gray' } }
        Row ("  {0}  {1,-8} {2,-7} {3,-7} {4}" -f $e.t, $e.verb, $e.lease, $e.by, $e.rest) $c
    }
    return , $rows
}
function Show-Board($Rows) {
    $w = 120; try { $w = [Math]::Max(40, [Console]::WindowWidth - 1) } catch {}
    foreach ($r in $Rows) {
        $t = [string]$r.t; if ($t.Length -gt $w) { $t = $t.Substring(0, $w - 1) + '>' }
        Write-Host $t -ForegroundColor $r.c
    }
}
# ---- the coloured board (Windows Terminal, pwsh, any console with VT codes) ---------------------------------------------
$script:E = [char]27; $script:R0 = "$([char]27)[0m"
function Fg([int]$r, [int]$g, [int]$b) { "$($script:E)[38;2;$r;$g;$($b)m" }
function Bg([int]$r, [int]$g, [int]$b) { "$($script:E)[48;2;$r;$g;$($b)m" }
$script:K = @{
    dim = (Fg 118 126 138); txt = (Fg 214 219 226); hi = "$([char]27)[1m" + (Fg 245 247 250)
    cyan = (Fg 92 204 222); green = (Fg 102 212 138); amber = (Fg 242 188 74); red = (Fg 244 104 94)
    magenta = (Fg 204 140 236); blue = (Fg 116 172 248); orange = (Fg 246 152 76)
    ink = (Fg 18 20 24); hdr = (Bg 34 39 48); title = (Bg 58 110 178)
    bcyan = (Bg 92 204 222); bgreen = (Bg 102 212 138); bamber = (Bg 242 188 74); bred = (Bg 244 104 94)
    bblue = (Bg 116 172 248); bmag = (Bg 204 140 236); bgrey = (Bg 92 100 112); borange = (Bg 246 152 76)
}
$script:Ch = @{ h = [string][char]0x2500; full = [string][char]0x2588; light = [string][char]0x2591; dot = [string][char]0x25CF; arr = [string][char]0x25B8; mid = [string][char]0x00B7 }
# A segment is a hashtable (t = text, s = style codes): hashtables never unroll in @() or +=, so a row stays a flat list.
function Seg([string]$T, [string]$S = '') { return @{ t = $T; s = $S } }
function Pill([string]$T, [string]$BgStyle) { return @{ t = " $T "; s = ("$($script:E)[1m" + $script:K.ink + $BgStyle) } }
function Bar([double]$Frac, [int]$N, [string]$Style) {
    $f = [Math]::Max(0, [Math]::Min($N, [int][Math]::Round($Frac * $N)))
    return @((Seg ($script:Ch.full * $f) $Style), (Seg ($script:Ch.light * ($N - $f)) $script:K.dim))
}
function Level-Style([double]$Frac) { if ($Frac -ge 0.8) { $script:K.red } elseif ($Frac -ge 0.5) { $script:K.amber } else { $script:K.green } }
function Render-Row($Row, [int]$W) {
    $sb = New-Object Text.StringBuilder; $vis = 0
    foreach ($s in $Row.s) {
        $t = [string]$s.t
        if ($vis + $t.Length -gt $W) { $t = $t.Substring(0, [Math]::Max(0, $W - $vis)) }
        if ($t.Length) { [void]$sb.Append($s.s).Append($t).Append($script:R0); $vis += $t.Length }
        if ($vis -ge $W) { break }
    }
    if ($Row.fill -and $vis -lt $W) { [void]$sb.Append($Row.fill).Append(' ' * ($W - $vis)).Append($script:R0) }
    [void]$sb.Append("$($script:E)[K")
    return $sb.ToString()
}
function Short-Reason([string]$R) {
    if ($R -match '^gpu lease: (\S+)') { return "gpu lease $($Matches[1])" }
    if ($R -match '^([\d.]+ GB) video memory') { return "$($Matches[1]) VRAM" }
    if ($R -match '^GPU (\d+) % busy') { return "$($Matches[1])% busy" }
    if ($R -match '^-game run: pid (\d+)') { return "-game pid $($Matches[1])" }
    if ($R -match '^packaged game: \S+ pid (\d+)') { return "packaged pid $($Matches[1])" }
    if ($R -match '^commandlet: pid (\d+)') { return "commandlet pid $($Matches[1])" }
    if ($R -match '^editor open') { return 'editor open' }
    if ($R -match '^local LLM') { return 'LLM loaded' }
    if ($R -match '^image generation') { return 'imagegen running' }
    if ($R -match '^build work: (\S+)') { return "build: $($Matches[1] -replace '\.exe$', '')" }
    return $R
}
function Ansi-Rows($M, [int]$Width, [int]$Height) {
    # Variable names here never reuse $k/$w/$h: PowerShell names ignore case, so they would hit $K and the typed params.
    $K = $script:K; $Ch = $script:Ch; $now = $M.now
    $rows = New-Object Collections.Generic.List[object]
    function Add($Segs, [string]$Fill = '') { $rows.Add(@{ s = $Segs; fill = $Fill }) }
    function Rule([string]$Name) { Add @((Seg " $Name " $K.hi), (Seg ($Ch.h * 200) $K.dim)) }
    # header
    $cop = if ($script:CopOn) { @((Pill $(if ($CopLenient) { 'COP ON lenient' } else { 'COP ON strict' }) $K.bgreen), (Seg "  stopped $($script:CopKills)  " ($K.txt + $K.hdr))) }
           elseif ($script:CopNote -match '^on') { @((Pill 'COP ON ELSEWHERE' $K.bgrey), (Seg '  ' $K.hdr)) }
           else { @((Pill 'COP OFF' $K.bred), (Seg '  ' $K.hdr)) }
    Add (@((Pill 'THOR TRAFFIC' $K.title), (Seg "   $(Get-Date -Format 'ddd HH:mm:ss')   " ($K.txt + $K.hdr)), (Seg "refresh $Every s   " ($K.dim + $K.hdr))) + $cop + @((Alert-Pill), (Seg '  ' $K.hdr))) $K.hdr
    Add @()
    # gpu
    $gpu = $M.gpu
    if ($gpu) {
        $vf = [double]$gpu.usedMB / [Math]::Max([double]1, [double]$gpu.totalMB); $uf = [double]$gpu.util / 100
        $q = if ($M.reasons.Count) { Pill 'NOT QUIET' $K.bamber } else { Pill 'QUIET' $K.bgreen }
        Add (@((Seg '  GPU   ' $K.hi)) + (Bar $vf 28 (Level-Style $vf)) + @((Seg ('  {0,4:N1} / {1:N1} GB' -f ($gpu.usedMB / 1024), ($gpu.totalMB / 1024)) $K.txt), (Seg '     LOAD ' $K.dim)) + (Bar $uf 12 (Level-Style $uf)) + @((Seg (' {0,3}%     ' -f $gpu.util) $K.txt), $q))
    } else { Add @((Seg '  GPU   ' $K.hi), (Seg 'no nvidia-smi reading' $K.amber)) }
    if ($M.reasons.Count) {
        $segs = @((Seg '        waiting on  ' $K.dim)); $i = 0
        foreach ($gr in @($M.reasons | ForEach-Object { Short-Reason $_ } | Group-Object)) {
            if ($i) { $segs += Seg "  $($Ch.mid)  " $K.dim }
            $segs += Seg $(if ($gr.Count -gt 1) { "$($gr.Name) x$($gr.Count)" } else { $gr.Name }) $K.amber; $i++
        }
        Add $segs
    }
    if ($M.strikes.Count) {
        $segs = @((Seg '  STRIKES ' $K.hi), (Pill ("{0} today" -f (@($M.strikes.Values) | Measure-Object -Sum).Sum) $K.bred), (Seg '  ' ''))
        $i = 0
        foreach ($who in $M.strikes.Keys) { if ($i) { $segs += Seg "  $($Ch.mid)  " $K.dim }; $segs += Seg $who $K.red; $segs += Seg " x$($M.strikes[$who])" $K.txt; $i++ }
        $segs += Seg '   runs stopped by the cop + C++ builds without the build lease' $K.dim
        Add $segs
    }
    Add @()
    # leases
    Rule 'LEASES'
    foreach ($n in $Names) {
        $x = $M.leases[$n]; $L = $x.lease; $q = $M.queues[$n]
        $name = Seg ('{0,-8}' -f $n.ToUpper()) $K.hi
        if ($x.state -eq 'live') {
            $eta = if ($L.eta) { To-Utc $L.eta } else { To-Utc $L.until }
            $over = $eta -le $now
            $st = if ($over) { Pill 'OVER' $K.bred } else { Pill 'HELD' $K.bcyan }
            Add @((Seg '  ' ''), (Seg "$($Ch.dot) " $(if ($over) { $K.red } else { $K.cyan })), $name, $st, (Seg '  ' ''), (Seg $L.by ($K.hi)), (Seg "   $(Short ([string]$L.note) 70)" $K.txt))
            $t0 = To-Utc $L.taken; $span = [Math]::Max(1, ($eta - $t0).TotalSeconds); $frac = ($now - $t0).TotalSeconds / $span
            $left = [int][Math]::Round(($eta - $now).TotalMinutes)
            $doneTxt = if ($over) { Seg ("  {0}m past its estimate" -f (-$left)) $K.red } else { Seg ("  done ~{0}" -f (Local-Hm $eta)) $K.txt }
            $leftTxt = if ($over) { Seg '' '' } else { Seg ("  ({0}m left)" -f $left) $K.dim }
            Add (@((Seg '              ' '')) + (Bar $frac 24 $(if ($over) { $K.red } else { $K.cyan })) + @($doneTxt, $leftTxt, (Seg "     expires $(Local-Hm $L.until)" $K.dim), (Seg $(if ($L.pid) { "   pid $($L.pid)" } else { '' }) $K.dim)))
        } elseif ($first = Queue-First $q) {
            Add @((Seg '  ' ''), (Seg "$($Ch.dot) " $K.amber), $name, (Pill 'KEPT' $K.bamber), (Seg '  for ' $K.dim), (Seg $first.by $K.hi), (Seg "   first in line, until $(Local-Hm $first.until)" $K.dim))
        } else {
            Add @((Seg '  ' ''), (Seg "$($Ch.dot) " $K.green), $name, (Pill 'FREE' $K.bgreen), (Seg $(if (@($q).Count) { '  waiters stand aside: anyone can take it' } else { '  nobody waiting' }) $K.dim))
        }
        $qi = 0
        foreach ($qe in $q) {
            $qi++; $back = To-Utc $qe.nextCheck; $late = $back -lt $now; $start = To-Utc $qe.start
            $backSeg = if ($qe.parked) { Seg 'aside: waiting for a quiet GPU' $K.cyan } elseif ($qe.job) { Seg 'AUTO: starts itself' $K.green } elseif ($late) { Seg "LATE, drops $(Local-Hm $qe.until)" $K.red } else { Seg (Local-Hm $back) $K.txt }
            Add @((Seg ('              {0} ' -f $qi) $K.dim), (Seg "$($Ch.arr) " $K.amber), (Seg ('{0,-6}' -f $qe.by) ($K.amber)), (Seg ('  {0,-36} ' -f (Short ([string]$qe.note) 36)) $K.txt),
                (Seg ('{0,5}' -f ('~' + [int][double]$qe.est + 'm')) $K.dim), (Seg '   starts ' $K.dim), (Seg (Local-Hm $start) $K.txt), (Seg (' ({0})' -f (In-Min $start)) $K.dim), (Seg $(if ($qe.job) { '   ' } else { '   back ' }) $K.dim), $backSeg)
        }
        if ($q.Count -or $x.state -eq 'live') { Add @() }
    }
    if ($rows[$rows.Count - 1].s.Count) { Add @() }
    # next 90 minutes, per lease
    Rule 'NEXT 90 MIN'
    foreach ($tlr in (Timeline-Rows $M $Width)) { $rows.Add($tlr) }
    Add @()
    # running
    Rule 'RUNNING'
    $kc = @{ editor = $K.bblue; game = $K.bmag; packaged = $K.bmag; commandlet = $K.bamber; llm = $K.borange; imagegen = $K.borange; build = $K.bgrey }
    $any = $false
    foreach ($p in ($M.procs | Where-Object { $_.kind -ne 'build' })) {
        $any = $true; $tg = Run-Tag $p $M.cov
        $tag = switch ($tg.k) { 'ok' { Pill ('{0,-11}' -f $tg.t) $K.bgreen } 'human' { Pill ('{0,-11}' -f 'YOU') $K.bblue } 'unk' { Pill ('{0,-11}' -f 'UNKNOWN') $K.bamber } 'bad' { Pill ('{0,-11}' -f 'NO LEASE') $K.bred } default { Seg (' ' * 13) '' } }
        Add @((Seg '  ' ''), (Pill ('{0,-10}' -f $p.kind) $kc[$p.kind]), (Seg (' {0,6}  ' -f $p.pid) $K.dim), $tag, (Seg "  $($p.cmd)" $K.dim))
    }
    foreach ($bg in (Build-Groups $M.procs $M.cov)) {
        $any = $true
        $tag = switch ($bg.tag.k) { 'ok' { Pill ('{0,-11}' -f $bg.tag.t) $K.bgreen } 'bad' { Pill ('{0,-11}' -f 'NO LEASE') $K.bred } 'human' { Pill ('{0,-11}' -f 'YOU') $K.bblue } default { Pill ('{0,-11}' -f 'no lease') $K.bgrey } }
        Add @((Seg '  ' ''), (Pill ('{0,-10}' -f $bg.label) $kc.build), (Seg '         ' ''), $tag, (Seg "  $($bg.names)" $K.dim))
    }
    if (-not $any) { Add @((Seg '  nothing running: no editor, -game, commandlet, LLM, imagegen or build' $K.dim)) }
    Add @()
    # sessions, trees and flags (thor_traffic.ps1)
    foreach ($tfr in (Traffic-Rows)) { $rows.Add($tfr) }
    # recent: as many as fit
    Rule 'RECENT'
    $room = [Math]::Max(3, $Height - $rows.Count - 2)
    $log = @($M.log | Select-Object -Last $room)
    if (-not $log.Count) { Add @((Seg '  (no lease events yet)' $K.dim)) }
    foreach ($e in $log) {
        $vc = switch -Regex ($e.verb) { '^take|^renew' { $K.cyan } '^release|^unqueue' { $K.green } '^queue' { $K.amber } '^dequeue|^lapse|forced|^cop|^reap|^park-long|^job-overrun|^over-cap' { $K.red } default { $K.txt } }
        Add @((Seg "  $($e.t)  " $K.dim), (Seg ('{0,-11}' -f $e.verb) $vc), (Seg ('{0,-7}' -f $e.lease) $K.txt), (Seg ('{0,-6}' -f $e.by) $K.hi), (Seg "  $($e.rest)" $K.dim))
    }
    Add @((Seg "  q quits  $($Ch.mid)  t alerts on/off  $($Ch.mid)  r re-reads sessions  $($Ch.mid)  $(Show-Path $Dir)  $($Ch.mid)  -Plain for plain text  $($Ch.mid)  COP: $(Cop-Text)" $K.dim))
    return , $rows
}
function Show-Ansi($M) {
    $w = 120; $h = 40
    try { $w = [Math]::Max(60, [Console]::WindowWidth - 1); $h = [Math]::Max(15, [Console]::WindowHeight - 1) } catch {}
    $rows = Ansi-Rows $M $w $h
    if ($rows.Count -gt $h) { $rows = @($rows | Select-Object -First $h) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("$($script:E)[?25l$($script:E)[H")
    $i = 0; foreach ($r in $rows) { if ($i) { [void]$sb.Append("`n") }; [void]$sb.Append((Render-Row $r $w)); $i++ }
    [void]$sb.Append("$($script:E)[J")
    [Console]::Write($sb.ToString())
}
# ---- board extras: timeline, sessions (optional thor_traffic.ps1 beside this script), toasts, keys ------------------------
$script:Tf = @{ data = $null; at = $null; proc = $null; task = $null; err = ''; next = [DateTime]::MinValue; started = $null }
$script:Al = @{ on = -not $NoToast; primed = $false; prev = @{}; over = @{}; late = @{}; bad = @{}; flags = @{}; flagsPrimed = $false
    tfAt = $null; logAt = ''; quietRun = 0; quietSaid = $true; pending = New-Object Collections.Generic.List[string]; shown = [DateTime]::MinValue; count = 0 }
$script:ToastApp = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
function Poll-Traffic {
    # Non-blocking: `thor_traffic.ps1 status -Json` takes ~10 s, so it runs as a hidden process every -TrafficEvery s and
    # the board shows its last answer.
    $tf = $script:Tf
    if ($tf.proc) {
        if (-not $tf.proc.HasExited) {
            if (([DateTime]::UtcNow - $tf.started).TotalSeconds -gt 120) {
                try { $tf.proc.Kill() } catch {}
                $tf.proc.Dispose(); $tf.proc = $null; $tf.err = 'thor_traffic ran over 2 min (stopped)'; $tf.next = [DateTime]::UtcNow.AddSeconds($TrafficEvery)
            }
            return
        }
        try {
            $txt = $tf.task.Result
            if ([string]::IsNullOrWhiteSpace($txt)) { throw "no output (exit $($tf.proc.ExitCode))" }
            $tf.data = $txt | ConvertFrom-Json; $tf.at = [DateTime]::UtcNow; $tf.err = ''
        } catch { $tf.err = "thor_traffic: $($_.Exception.Message)" }
        $tf.proc.Dispose(); $tf.proc = $null; $tf.next = [DateTime]::UtcNow.AddSeconds([Math]::Max(10, $TrafficEvery))
    }
    if ([DateTime]::UtcNow -lt $tf.next) { return }
    $tp = if ($TrafficScript) { $TrafficScript } else { Join-Path $PSScriptRoot 'thor_traffic.ps1' }
    if ($NoTraffic -or $Fixture -or -not (Test-Path $tp)) { $tf.next = [DateTime]::UtcNow.AddSeconds(300); $tf.off = $true; return }
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tp`" status -Json")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    try {
        $tf.proc = [Diagnostics.Process]::Start($psi); $tf.started = [DateTime]::UtcNow
        $tf.task = $tf.proc.StandardOutput.ReadToEndAsync(); [void]$tf.proc.StandardError.ReadToEndAsync()
    } catch { $tf.err = "thor_traffic: $($_.Exception.Message)"; $tf.proc = $null; $tf.next = [DateTime]::UtcNow.AddSeconds(60) }
}
function Traffic-On {
    $tp = if ($TrafficScript) { $TrafficScript } else { Join-Path $PSScriptRoot 'thor_traffic.ps1' }
    return -not $NoTraffic -and -not $Fixture -and (Test-Path $tp)
}
function Show-Path([string]$P) { if ($env:USERPROFILE -and $P.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $P.Substring($env:USERPROFILE.Length) }; return $P }
function Stop-Traffic { $p = $script:Tf.proc; if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch {} } }
function Who-Style([string]$Who) {
    # One background colour per name, the same on every row and every redraw.
    $pal = @($script:K.bcyan, $script:K.bmag, $script:K.bblue, $script:K.borange, $script:K.bgreen, $script:K.bamber)
    $sum = 0; foreach ($c in $Who.ToCharArray()) { $sum += [int]$c }
    return $pal[$sum % $pal.Count]
}
function Timeline-Rows($M, [int]$Wid) {
    # Next 90 minutes per lease: the holder until the queue expects it done (Free-At), then
    # each waiter from its expected start for its estimate. Bold = holds it now; plain = waiting.
    $KK = $script:K; $now = $M.now; $span = 90
    $cols = [Math]::Max(30, $Wid - 12); $perCol = $span / $cols
    $out = New-Object Collections.Generic.List[object]
    $ruler = (' ' * $cols).ToCharArray()
    for ($mm = 0; $mm -lt $span; $mm += 15) {
        $c = [int][Math]::Floor($mm / $perCol)
        $lab = if ($mm -eq 0) { "$([char]0x25BC)now" } else { "$([char]0x2502)" + $now.AddMinutes($mm).ToLocalTime().ToString('HH:mm') }
        if ($c + $lab.Length -gt $cols) { $c = $cols - $lab.Length }
        for ($i = 0; $i -lt $lab.Length; $i++) { $ruler[$c + $i] = $lab[$i] }
    }
    $out.Add(@{ s = @((Seg '          ' ''), (Seg (-join $ruler) $KK.dim)); fill = '' })
    foreach ($n in $Names) {
        $x = $M.leases[$n]; $spans = @()
        if ($x.state -eq 'live') {
            $L = $x.lease
            $end = Free-At $L 'live'
            $spans += @{ who = [string]$L.by; a = $now; b = $end; held = $true }
        }
        foreach ($qe in @($M.queues[$n])) {
            if (-not $qe) { continue }
            $a = To-Utc $qe.start; if ($a -lt $now) { $a = $now }
            $spans += @{ who = [string]$qe.by; a = $a; b = $a.AddMinutes([Math]::Max(1, [double]$qe.est)); held = $false }
        }
        $cells = New-Object 'int[]' $cols; for ($i = 0; $i -lt $cols; $i++) { $cells[$i] = -1 }
        for ($si = 0; $si -lt $spans.Count; $si++) {
            $c0 = [int][Math]::Floor(($spans[$si].a - $now).TotalMinutes / $perCol)
            $c1 = [int][Math]::Ceiling(($spans[$si].b - $now).TotalMinutes / $perCol)
            for ($c = [Math]::Max(0, $c0); $c -lt [Math]::Min($cols, $c1); $c++) { if ($cells[$c] -lt 0) { $cells[$c] = $si } }
        }
        $segs = @((Seg ('  {0,-8}' -f $n.ToUpper()) $KK.hi))
        $i = 0
        while ($i -lt $cols) {
            $own = $cells[$i]; $j = $i; while ($j -lt $cols -and $cells[$j] -eq $own) { $j++ }
            $len = $j - $i
            if ($own -lt 0) {
                $free = if ($i -eq 0 -and $len -ge 6) { 'free' + ($script:Ch.mid * ($len - 4)) } else { $script:Ch.mid * $len }
                $segs += Seg $free $KK.dim
            } else {
                $sp = $spans[$own]; $lab = " $($sp.who)"
                $txt = if ($lab.Length -ge $len) { $lab.Substring(0, $len) } else { $lab + (' ' * ($len - $lab.Length)) }
                $st = $KK.ink + (Who-Style $sp.who); if ($sp.held) { $st = "$($script:E)[1m" + $st }
                $segs += @{ t = $txt; s = $st }
            }
            $i = $j
        }
        $out.Add(@{ s = $segs; fill = '' })
    }
    return , $out
}
function Traffic-Rows {
    # SESSIONS, trees and FLAGS from the last thor_traffic.ps1 read.
    $KK = $script:K; $tf = $script:Tf; $out = New-Object Collections.Generic.List[object]
    if (-not (Traffic-On)) { return , $out }   # no thor_traffic.ps1 beside this script (or -NoTraffic / -Fixture): no SESSIONS strip
    function A2($Segs) { $out.Add(@{ s = $Segs; fill = '' }) }
    $age = if ($tf.at) { 'read {0}s ago' -f [int]([DateTime]::UtcNow - $tf.at).TotalSeconds } elseif ($tf.proc) { 'reading' } else { 'no read yet' }
    if ($tf.proc -and $tf.at) { $age += ', re-reading' }
    A2 @((Seg ' SESSIONS ' $KK.hi), (Seg "$($script:Ch.h * 2) thor_traffic $age " $KK.dim), (Seg ($script:Ch.h * 200) $KK.dim))
    if ($tf.err) { A2 @((Seg "  $($tf.err)" $KK.amber)) }
    $d = $tf.data
    if (-not $d) { A2 @((Seg '  (the first read takes ~10 s)' $KK.dim)); A2 @(); return , $out }
    $ss = @($d.sessions | Where-Object { $_ })
    if (-not $ss.Count) { A2 @((Seg '  no session signs in the last hour' $KK.dim)) }
    foreach ($se in ($ss | Select-Object -First 8)) {
        $last = if ($se.last) { To-Utc $se.last } else { $null }
        $mins = if ($last) { [int][Math]::Floor(([DateTime]::UtcNow - $last).TotalMinutes) } else { 99999 }
        $dotc = if ($se.leases -or $se.procs) { $KK.green } elseif ($se.queued) { $KK.amber } elseif ($mins -le 15) { $KK.cyan } else { $KK.dim }
        $what = @()
        if ($se.leases) { $what += "holds $($se.leases)" }
        if ($se.queued) { $what += "waits $($se.queued)" }
        if ($se.procs) { $what += "runs $($se.procs)" }
        $lastTxt = if ($last) { '{0} {1}' -f (Local-Hm $last), $(if ($mins -lt 1) { 'now' } else { "${mins}m ago" }) } else { '' }
        $tail = [string]$se.lastWhat; if ($se.note) { $tail = "'$($se.note)'  $tail" }
        A2 @((Seg '  ' ''), (Seg "$($script:Ch.dot) " $dotc), (Seg ('{0,-9}' -f (Short ([string]$se.id) 9)) $KK.hi), (Seg ('{0,-20} ' -f (Short ([string]$se.card) 20)) $KK.txt),
            (Seg ('{0,-28} ' -f (Short ($what -join ', ') 28)) $KK.cyan), (Seg ('{0,-13}' -f $lastTxt) $KK.txt), (Seg "  $(Short $tail 90)" $KK.dim))
    }
    if ($ss.Count -gt 8) { A2 @((Seg "  +$($ss.Count - 8) more (thor_traffic.ps1)" $KK.dim)) }
    $trees = @(foreach ($tr in @($d.trees | Where-Object { $_ })) {
        $b = "$($tr.name) $($tr.head)"; if ($tr.dirty) { $b += " dirty $($tr.dirty)" }; if ($tr.behind) { $b += " behind $($tr.behind)" }; if ($tr.stale) { $b += ' STALE' }; $b
    })
    if ($trees.Count) { A2 @((Seg '  trees  ' $KK.dim), (Seg ($trees -join "  $($script:Ch.mid)  ") $KK.txt)) }
    A2 @()
    $fl = @($d.flags | Where-Object { $_ })
    if ($fl.Count) {
        A2 @((Seg ' FLAGS ' $KK.hi), (Pill "$($fl.Count)" $KK.bred), (Seg ' ' ''), (Seg ($script:Ch.h * 200) $KK.dim))
        foreach ($f in ($fl | Select-Object -First 6)) { A2 @((Seg "  $f" $KK.red)) }
        if ($fl.Count -gt 6) { A2 @((Seg "  +$($fl.Count - 6) more (thor_traffic.ps1)" $KK.dim)) }
    } else { A2 @((Seg ' FLAGS ' $KK.hi), (Pill 'NONE' $KK.bgreen), (Seg '  no clashes, idle leases or unleased heavy work' $KK.dim)) }
    A2 @()
    return , $out
}
function Alert-Pill {
    $al = $script:Al
    if (-not $al.on) { return (Pill 'ALERTS OFF' $script:K.bgrey) }
    return (Pill $(if ($al.count) { "ALERTS ON $($al.count)" } else { 'ALERTS ON' }) $script:K.bblue)
}
function Show-Toast([string]$Title, [string[]]$Lines) {
    # A Windows toast through Windows PowerShell 5.1 (pwsh 7 has no WinRT); no window, nothing waited on.
    $tx = @($Title) + @($Lines | Select-Object -First 2) | ForEach-Object { '<text>' + [Security.SecurityElement]::Escape([string]$_) + '</text>' }
    $xml = '<toast><visual><binding template="ToastGeneric">' + ($tx -join '') + '</binding></visual></toast>'
    $code = "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null; " +
        "[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null; " +
        "`$x = New-Object Windows.Data.Xml.Dom.XmlDocument; `$x.LoadXml('" + ($xml -replace "'", "''") + "'); " +
        "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$($script:ToastApp)').Show((New-Object Windows.UI.Notifications.ToastNotification `$x))"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), "-NoProfile -NonInteractive -EncodedCommand $enc")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    try { [void][Diagnostics.Process]::Start($psi) } catch {}
}
function Flag-Key([string]$F) {
    # A flag's identity without the times and ages that change every read.
    return ((($F -replace '\(?\d+(\.\d+)? ?(min|h|s) ago\)?', '') -replace '\d{1,2}:\d\d', '' -replace '\s+', ' ').Trim())
}
function Watch-Alerts($M) {
    # Compares this pass with the last and toasts what changed. The first pass (and the first thor_traffic read) only primes.
    $al = $script:Al; $ev = New-Object Collections.Generic.List[string]; $now = $M.now
    foreach ($n in $Names) {
        $x = $M.leases[$n]; $up = $n.ToUpper()
        $cur = if ($x.state -eq 'live') { [string]$x.lease.by } else { '' }
        $was = [string]$al.prev[$n]
        if ($cur -ne $was) {
            $nt = if ($cur) { "  '$(Short ([string]$x.lease.note) 60)'" } else { '' }
            if ($cur -and $was) { $ev.Add("$up lease: $was -> $cur$nt") }
            elseif ($cur) { $ev.Add("$up lease taken by $cur$nt") }
            else { $ev.Add("$up lease is free (was $was's)") }
        }
        $al.prev[$n] = $cur
        if ($cur) {
            $eta = if ($x.lease.eta) { To-Utc $x.lease.eta } else { To-Utc $x.lease.until }
            $ok = "$n|$cur|$($x.lease.taken)"
            if ($eta -le $now -and -not $al.over.ContainsKey($ok)) { $al.over[$ok] = 1; $ev.Add("$up lease: $cur is past its estimate") }
        }
        foreach ($qe in @($M.queues[$n])) {
            if (-not $qe -or $qe.job) { continue }
            $lk = "$n|$($qe.by)|$($qe.nextCheck)"
            if ((To-Utc $qe.nextCheck) -lt $now -and -not $al.late.ContainsKey($lk)) { $al.late[$lk] = 1; $ev.Add("$up queue: $($qe.by) is LATE checking back (drops at $(Local-Hm $qe.until))") }
        }
    }
    # lease.log: stops, strikes, lapses, drops
    if (Test-Path $LogFile) {
        foreach ($ln in @(Get-Content $LogFile -Tail 40 -ErrorAction SilentlyContinue)) {
            if ($ln -notmatch '^(\S+Z) (\S+)') { continue }
            $ts = $Matches[1]; $vb = $Matches[2]
            if ([string]::CompareOrdinal($ts, $al.logAt) -le 0) { continue }
            $al.logAt = $ts
            if ($vb -match '^(cop-kill|strike|lapse|dequeue|dispatch|job-|over-cap|reestimate|reap|park-long)' -or $ln -match ' forced') { $ev.Add((Short ("$vb " + ($ln -replace '^\S+ \S+ ', '')) 160)) }
        }
    }
    # runs no lease covers
    foreach ($p in @($M.procs)) {
        if ((Run-Tag $p $M.cov).k -ne 'bad') { continue }
        $bk = "$($p.pid)|$($p.started)"
        if (-not $al.bad.ContainsKey($bk)) { $al.bad[$bk] = 1; $ev.Add("NO LEASE: $($p.kind) pid $($p.pid)  $(Short ([string]$p.cmd) 80)") }
    }
    # quiet GPU, two passes in a row
    if ($M.reasons.Count) { $al.quietRun = 0; $al.quietSaid = $false }
    else { $al.quietRun++; if ($al.quietRun -ge 2 -and -not $al.quietSaid) { $al.quietSaid = $true; $ev.Add('GPU is quiet: a timing run could start now') } }
    if (-not $al.primed) { $al.primed = $true; $al.quietSaid = -not $M.reasons.Count; $ev.Clear() }
    # thor_traffic flags, once per read
    $tf = $script:Tf
    if ($tf.data -and $tf.at -ne $al.tfAt) {
        $al.tfAt = $tf.at; $seen = @{}
        foreach ($f in @($tf.data.flags | Where-Object { $_ })) {
            $fk = Flag-Key $f; $seen[$fk] = 1
            if (-not $al.flags.ContainsKey($fk) -and $al.flagsPrimed) { $ev.Add(($f -replace '^!\s*', 'flag: ')) }
        }
        $al.flags = $seen; $al.flagsPrimed = $true
    }
    if ($ev.Count) { $al.count += $ev.Count; if ($al.on) { foreach ($e1 in $ev) { $al.pending.Add($e1) } } }
    # at most one toast per 8 s; what piles up goes out together
    if ($al.pending.Count -and ([DateTime]::UtcNow - $al.shown).TotalSeconds -ge 8) {
        $items = @($al.pending); $al.pending.Clear(); $al.shown = [DateTime]::UtcNow
        $title = if ($items.Count -gt 1) { "THOR traffic: $($items.Count) changes" } else { 'THOR traffic' }
        $more = if ($items.Count -gt 2) { @($items[1], "+$($items.Count - 2) more: " + (($items | Select-Object -Skip 2) -join ' | ')) } else { @($items | Select-Object -Skip 1) }
        Show-Toast $title (@($items[0]) + $more)
    }
}
function Wait-Keys([int]$Sec) {
    # Sleeps up to $Sec while polling thor_traffic and the keyboard. q or Esc: $true (quit); t: alerts on/off; r: re-read now.
    $until = [DateTime]::UtcNow.AddSeconds($Sec)
    while ([DateTime]::UtcNow -lt $until) {
        Poll-Traffic
        $ki = $null
        try { if ([Console]::KeyAvailable) { $ki = [Console]::ReadKey($true) } } catch {}
        if ($ki) {
            if ($ki.Key -eq [ConsoleKey]::Escape -or $ki.KeyChar -eq 'q' -or $ki.KeyChar -eq 'Q') { return $true }
            if ($ki.KeyChar -eq 't' -or $ki.KeyChar -eq 'T') { $script:Al.on = -not $script:Al.on; if (-not $script:Al.on) { $script:Al.pending.Clear() }; return $false }
            if ($ki.KeyChar -eq 'r' -or $ki.KeyChar -eq 'R') { $script:Tf.next = [DateTime]::MinValue; Poll-Traffic; return $false }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
function Lease-Minutes([string]$Name) {
    $m = if ($Minutes -gt 0) { $Minutes } else { $DefaultMin[$Name] }
    return [Math]::Min($m, 720)
}

# ---- verbs --------------------------------------------------------------------------------------------------------------
switch ($Verb) {
    'status' {
        $gpu = Get-Gpu; $procs = Get-Procs; $leases = Get-Leases
        $reasons = Quiet-Reasons $gpu $procs $leases
        if ($Json) {
            $lj = [ordered]@{}; $qj = [ordered]@{}
            foreach ($n in $Names) { $lj[$n] = $leases[$n]; $qj[$n] = @(Status-Queue $n $leases[$n]) }
            [ordered]@{
                at = Now-Iso; profile = [string]$Traits.name; gpu = $gpu
                leases = $lj
                queues = $qj
                procs = $procs; quiet = ($reasons.Count -eq 0); reasons = @($reasons)
            } | ConvertTo-Json -Depth 5
            exit 0
        }
        $g = if ($gpu) { '{0:N1} / {1:N1} GB video memory, {2} % busy' -f ($gpu.usedMB / 1024), ($gpu.totalMB / 1024), $gpu.util } else { 'no nvidia-smi reading' }
        Write-Host "THOR $(Get-Date -Format 'yyyy-MM-dd HH:mm')  $g"
        Write-Host 'Leases'
        foreach ($n in $Names) {
            $x = $leases[$n]
            if ($x.state -eq 'live') { Write-Host ('  {0,-7} {1}' -f $n, (Describe-Lease $x.lease)) -ForegroundColor Cyan }
            elseif ($x.state -eq 'none') { Write-Host ('  {0,-7} free' -f $n) }
            else { Write-Host ('  {0,-7} free ({1}''s lease {2})' -f $n, $x.lease.by, $x.state) }
            $k = 0
            foreach ($w in (Status-Queue $n $x)) {
                $k++
                $lab = if ($k -eq 1) { 'queue:' } else { '' }
                $line = '          {0,-6} {1}. {2}{3} ~{4} min, expected start {5}, checks back by {6}' -f $lab, $k, $w.by, $(if ($w.note) { " '$($w.note)'" } else { '' }), $w.est, (Local-Hm $w.start), (Local-Hm $w.nextCheck)
                if ($w.parked) { $line += "; stands aside, waiting for a quiet GPU, so the lease isn't kept for it" }
                Write-Host $line -ForegroundColor Yellow
            }
        }
        Write-Host 'Running'
        if ($procs.Count -eq 0) { Write-Host '  nothing on the watch list: no editor, game, LLM, image generation or build' }
        $leasedPids = @(); foreach ($n in $Names) { $l = $leases[$n]; if ($l.state -eq 'live') { $leasedPids += @($l.lease.pid, $l.lease.childPid) | Where-Object { $_ } } }
        $builds = @($procs | Where-Object { $_.kind -eq 'build' })
        foreach ($p in ($procs | Where-Object { $_.kind -ne 'build' })) {
            $tag = ''
            if ($leasedPids -contains $p.pid) { $tag = '  [leased]' }
            elseif ($p.kind -in @('editor', 'game', 'packaged', 'commandlet')) {
                $want = if ($p.kind -eq 'editor') { 'editor' } else { 'gpu' }
                if ($leases[$want].state -ne 'live') { $tag = "  [no $want lease]" }
            }
            Write-Host ('  {0,-10} {1,6}  {2}{3}' -f $p.kind, $p.pid, $p.cmd, $tag)
        }
        if ($builds.Count) {
            $names = ($builds | Group-Object name | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
            $tag = if ($leases['build'].state -ne 'live' -and @($builds | Where-Object { $_.cpp }).Count) { '  [C++ build, no build lease]' } else { '' }
            Write-Host ('  {0,-10} {1}{2}' -f 'build', $names, $tag)
        }
        if ($reasons.Count -eq 0) { Write-Host 'Quiet GPU: yes' -ForegroundColor Green }
        else { Write-Host "Quiet GPU: no - $($reasons -join '; ')" -ForegroundColor Yellow }
        exit 0
    }
    'take' {
        Need-By; Need-Lease
        if ($HolderPid -and -not (Get-Process -Id $HolderPid -ErrorAction SilentlyContinue)) { Fail "-HolderPid $HolderPid is not running" }
        $min = Lease-Minutes $Lease
        $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMin)
        $lastSaid = [DateTime]::MinValue
        while ($true) {
            try { $res = Try-Take $Lease $min $HolderPid }
            catch {
                if (-not $Wait -or [DateTime]::UtcNow -ge $deadline) { throw }
                Say "look failed, trying again: $($_.Exception.Message)" Yellow; Start-Sleep -Seconds 5; continue
            }
            if ($res.ok) {
                $what = if ($res.renewed) { 'renewed' } else { 'taken' }
                Say "$Lease $what by $(Describe-Lease $res.cur)" Green
                if ($Lease -eq 'build' -and @(Get-Procs | Where-Object { $_.kind -eq 'editor' }).Count) {
                    Say 'note: an editor is open; close it before a source rebuild (save or check dirty packages first)' Yellow
                }
                exit 0
            }
            if (-not $Wait) { Fail (Wait-Text $res $Lease) 2 }
            if ([DateTime]::UtcNow -ge $deadline) { [void](Do-Unqueue $Lease); Fail "gave up after $TimeoutMin min and left the queue; $(Wait-Text $res $Lease)" 2 }
            if (([DateTime]::UtcNow - $lastSaid).TotalSeconds -ge 60) { Say "waiting: $(Wait-Text $res $Lease)" Yellow; $lastSaid = [DateTime]::UtcNow }
            Start-Sleep -Seconds 5
        }
    }
    'renew' {
        Need-By; Need-Lease
        $cur = Read-Lease $Lease
        if (-not $cur -or $cur.by -ne $By) { Fail "you ($By) don't hold $Lease; take it instead" 2 }
        $res = Try-Take $Lease (Lease-Minutes $Lease) ([int]$(if ($HolderPid) { $HolderPid } elseif ($cur.pid -and (Lease-State $cur) -eq 'live') { $cur.pid } else { 0 }))
        if (-not $res.ok) { Fail "$Lease lapsed and went on: $(Wait-Text $res $Lease)" 2 }
        Say "$Lease renewed: $(Describe-Lease $res.cur)" Green
        if ($res.oldEta -and [Math]::Abs(((To-Utc $res.cur.eta) - $res.oldEta).TotalMinutes) -ge 1) {
            Say "re-estimated: done ~$(Local-Hm $res.cur.eta) (was $(Local-Hm $res.oldEta)); $($res.waiting) waiting in its queue see the new time when they check back" Cyan
        }
        exit 0
    }
    'release' {
        Need-By; Need-Lease
        $res = Do-Release $Lease
        if (-not $res.ok) { Fail "$Lease is held by $(Describe-Lease $res.cur); -Force only if that holder is gone" 2 }
        Say $res.msg Green
        exit 0
    }
    'cop' {
        $script:CopMutex = New-Object Threading.Mutex($false, 'Global\ThorTraffic_cop')
        if (-not (Take-Mutex $script:CopMutex)) {
            if (-not $CopWait) { Fail 'another cop is already running (a watch window or a cop task)' 2 }
            # The logon task's cop: wait for a watch window's cop to close, then take over.
            Say 'another cop is on; waiting to take over when it stops' DarkGray
            while (-not (Take-Mutex $script:CopMutex)) { Start-Sleep -Seconds 5 }
        }
        Say "GPU cop on (every $Every s, grace $CopGraceSec s); Ctrl+C stops it" Magenta
        while ($true) {
            $procs = $null
            try { $procs = @(Get-Procs); $cp = Cop-Pass $procs (Get-Leases); foreach ($k in $cp.killed) { Say "stopped pid $($k.pid): $($k.cmd)" Red } } catch { Say "cop pass failed: $($_.Exception.Message)" Yellow }
            # No process list means no judging who is idle.
            if ($null -ne $procs) { try { foreach ($rp in (Reap-Pass $procs (Get-Leases))) { Say "released $($rp.lease) from $($rp.by): $($rp.why)" Yellow } } catch { Say "reap pass failed: $($_.Exception.Message)" Yellow } }
            try { foreach ($cj in (Cap-Pass (Get-Leases))) { Say "$(if ($cj.stopped) { 'stopped' } else { 'over its cap, not stopped:' }) job $($cj.job): $($cj.why)" Red } } catch { Say "cap pass failed: $($_.Exception.Message)" Yellow }
            try { foreach ($pj in (Preempt-Pass (Get-Leases))) { Say "preempted job $($pj.job) ($($pj.why)); queued again as $($pj.again)" Yellow } } catch { Say "preempt pass failed: $($_.Exception.Message)" Yellow }
            try { foreach ($ca in (Alarm-Pass (Get-Leases))) { Say "over its cap, not stopped: $($ca.by)'s $($ca.lease) lease$(if ($ca.job) { " (job $($ca.job))" }): $($ca.why)" Red } } catch { Say "alarm pass failed: $($_.Exception.Message)" Yellow }
            try { foreach ($dj in (Dispatch-Pass)) { Say "dispatched $($dj.id): $($dj.exe) $($dj.args)$(if ($dj.lease -eq $CardLease) { " (cap ~$(Local-Hm (Job-CapAt $dj)))" })" Cyan } } catch { Say "dispatch pass failed: $($_.Exception.Message)" Yellow }
            try { [void](Sink-Pass) } catch { Say "sink pass failed: $($_.Exception.Message)" Yellow }
            if ($Once) { exit 0 }
            Start-Sleep -Seconds ([Math]::Max(2, $Every))
        }
    }
    'watch' {
        $script:CopKills = 0; $script:CopOn = $false; $script:CopNote = ''
        if ($Fixture) { $NoCop = $true; $NoToast = $true; $script:Al.on = $false }   # a replay never stops real processes
        if ($Frame) {
            # One coloured frame on stdout, then exit: for docs, screenshots and CI.
            try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
            $probe = New-Object Threading.Mutex($false, 'Global\ThorTraffic_cop')
            if ($Fixture) { $script:CopNote = 'on in another window or task' }
            elseif (Take-Mutex $probe) { $probe.ReleaseMutex(); $script:CopNote = 'off: no watch window or cop task is running' } else { $script:CopNote = 'on in another window or task' }
            $probe.Dispose()
            $bm = Board-Model
            $fr = foreach ($r in (Ansi-Rows $bm $Cols $Rows)) { Render-Row $r $Cols }
            [Console]::Out.Write((($fr -join "`n") + "$($script:R0)`n")); exit 0
        }
        if (-not $NoCop -and -not $Once) {
            $script:CopMutex = New-Object Threading.Mutex($false, 'Global\ThorTraffic_cop')
            if (Take-Mutex $script:CopMutex) { $script:CopOn = $true } else { $script:CopNote = 'on in another window or task' }
        }
        if ($Once) {
            # Say whether a cop is running elsewhere: try its mutex, and let go at once if it was free.
            $probe = New-Object Threading.Mutex($false, 'Global\ThorTraffic_cop')
            if (Take-Mutex $probe) { $probe.ReleaseMutex(); $script:CopNote = 'off: no watch window or cop task is running' } else { $script:CopNote = 'on in another window or task' }
            $probe.Dispose()
            Show-Board (Board-Lines (Board-Model)); exit 0
        }
        # One board at a time: a second launch (the desktop shortcut clicked again) says so and closes.
        $script:BoardMutex = New-Object Threading.Mutex($false, 'Global\ThorTraffic_board')
        if (-not (Take-Mutex $script:BoardMutex)) { Write-Host 'THOR traffic is already open in another window.' -ForegroundColor Yellow; Start-Sleep -Seconds 2; exit 0 }
        try { $host.UI.RawUI.WindowTitle = 'THOR traffic' } catch {}
        $vt = $false; try { $vt = [bool]$host.UI.SupportsVirtualTerminal } catch {}
        if ($Plain -or -not $vt) {
            while ($true) {
                try { $rows = Board-Lines (Board-Model) } catch { $rows = @(@{ t = "thor watch: $($_.Exception.Message) (retrying)"; c = 'Red' }) }
                Clear-Host; Show-Board $rows
                Start-Sleep -Seconds ([Math]::Max(2, $Every))
            }
        }
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
        Clear-Host; $lastW = -1
        Poll-Traffic
        try {
            while ($true) {
                $w = 0; try { $w = [Console]::WindowWidth } catch {}
                if ($w -ne $lastW) { [Console]::Write("$($script:E)[2J"); $lastW = $w }
                try { $bm = Board-Model; Poll-Traffic; try { Watch-Alerts $bm } catch {}; Show-Ansi $bm }
                catch { [Console]::Write("$($script:E)[H$($script:K.red)thor watch: $($_.Exception.Message) (retrying)$($script:R0)$($script:E)[K") }
                if (Wait-Keys ([Math]::Max(2, $Every))) { break }
            }
        } finally { Stop-Traffic; [Console]::Write("$($script:E)[0m$($script:E)[?25h`n") }
    }
    'unqueue' {
        Need-By; Need-Lease
        if (Do-Unqueue $Lease) { Say "$By left the $Lease queue" Green } else { Say "$By wasn't in the $Lease queue" }
        exit 0
    }
    'quiet' {
        if ($By) { Need-By }
        if ($Wait) {
            $ok = Wait-Quiet ([DateTime]::UtcNow.AddMinutes($TimeoutMin))
            if ($ok) { Say 'quiet GPU' Green; exit 0 }
            Fail "no quiet GPU within $TimeoutMin min" 3
        }
        $reasons = Quiet-Reasons (Get-Gpu) (Get-Procs) (Get-Leases)
        if ($reasons.Count -eq 0) { Say 'quiet GPU' Green; exit 0 }
        Fail "not quiet: $($reasons -join '; ')" 3
    }
    'hold' {
        Need-By
        if (-not $Lease) { $Lease = $CardLease }
        $tie = if ($HolderPid) { $HolderPid } else { $PID }
        if (-not (Get-Process -Id $tie -ErrorAction SilentlyContinue)) { Fail "-HolderPid $tie is not running" }
        if ($Minutes -le 0) { $Minutes = 720 }
        $min = Lease-Minutes $Lease
        $res = Wait-Lease $Lease $min $tie ([DateTime]::UtcNow.AddMinutes($TimeoutMin)) ($Lease -eq $CardLease -and -not $NoQuiet)
        if (-not $res.ok) { Fail $res.msg $res.code }
        Say "$Lease held: $(Describe-Lease $res.cur)" Green
        exit 0
    }
    'run' {
        $jb = $null
        if ($JobId) {
            # A dispatched job: everything comes from its file (the dispatcher passes only the id).
            $jb = Read-Job $JobId
            if (-not $jb) { Fail "no job $JobId in $JobDir" }
            $By = [string]$jb.runBy; $Lease = [string]$jb.lease; $Exe = [string]$jb.exe; $ArgList = [string]$jb.args; $For = [string]$jb.note
            $EstMin = [double]$jb.est; $NoQuiet = [bool]$jb.noQuiet; $TimeoutMin = [double]$jb.timeoutMin; $WorkDir = [string]$jb.cwd
            # A job file from an older version has no quiet switches and keeps the defaults.
            if ($null -ne $jb.maxVramGB) { $AllowEditor = [bool]$jb.allowEditor; $AllowBuild = [bool]$jb.allowBuild; $MaxVramGB = [double]$jb.maxVramGB; $MaxUtil = [int]$jb.maxUtil; $SettleSec = [int]$jb.settleSec }
            try { Start-Transcript -LiteralPath ([string]$jb.log) -Append | Out-Null } catch {}
        }
        function Job-End([string]$State, $Code, [string]$Why) {
            if (-not $JobId) { return }
            $done = Set-Job $JobId @{ state = $State; exit = $Code; ended = Now-Iso; why = $Why } @('starting', 'running')
            if ($done) { Log-Line "job-$(if ($State -eq 'done') { 'done' } else { 'failed' }) $Lease $By job $JobId$(if ($null -ne $Code) { " exit $Code" })$(if ($Why) { " ($Why)" })" }
            try { Stop-Transcript | Out-Null } catch {}
        }
        Need-By
        if (-not $Exe) { Fail 'run needs -Exe <path> (and -ArgList for its arguments)' }
        if (-not $Lease) { $Lease = $CardLease }
        if ($Minutes -le 0) { $Minutes = 720 }
        $min = Lease-Minutes $Lease
        $res = Wait-Lease $Lease $min $PID ([DateTime]::UtcNow.AddMinutes($TimeoutMin)) (-not $NoQuiet)
        if (-not $res.ok) { Job-End 'failed' $null $res.why; Fail $res.msg $res.code }
        $code = 1; $why = ''
        try {
            $sp = @{ FilePath = $Exe; PassThru = $true }
            if ($ArgList) { $sp.ArgumentList = $ArgList }
            if ($WorkDir) { $sp.WorkingDirectory = $WorkDir }
            if ($jb) { $sp.RedirectStandardOutput = [string]$jb.out; $sp.RedirectStandardError = [string]$jb.err; $sp.NoNewWindow = $true }
            try { $p = Start-Process @sp } catch { $why = "could not start: $($_.Exception.Message)"; throw }
            $null = $p.Handle
            With-Lock {
                $cur = Read-Lease $Lease
                if ($cur -and $cur.by -eq $By -and [int]$cur.pid -eq $PID) { $cur.childPid = $p.Id; Write-Lease $Lease $cur }
            } | Out-Null
            if ($JobId) { [void](Set-Job $JobId @{ state = 'running'; childPid = $p.Id; waiting = ''; took = Now-Iso } @('starting')) }
            Say "$Lease held; started pid $($p.Id): $Exe $ArgList" Green
            $p.WaitForExit()
            $code = $p.ExitCode
            Say "pid $($p.Id) exited $code"
        } finally {
            # A gpu job that ended past its cap on its own: its lane's queued jobs go first, while it still holds the lease (header: the cop).
            if ($JobId -and $Lease -eq $CardLease) {
                try {
                    $cur = Read-Lease $Lease; $cap = Cap-At $cur; $jn = Read-Job $JobId
                    if ($cap -and [DateTime]::UtcNow -gt $cap -and $cur.by -eq $By -and [string]$jn.state -eq 'running') { [void](Lane-Break $jn $Lease) }
                } catch { Say "lane breaker failed: $($_.Exception.Message)" Yellow }
            }
            # The lease is tied to this process, so it ends with it anyway; the job's exit code has only this one chance to land.
            try {
                With-Lock {
                    $cur = Read-Lease $Lease
                    if ($cur -and $cur.by -eq $By -and [int]$cur.pid -eq $PID) { Remove-Lease $Lease; Log-Line "release $Lease $By (run done)" }
                } | Out-Null
            } catch { Say "release failed: $($_.Exception.Message)" Yellow }
            if ($why) { Job-End 'failed' $null $why } else { Job-End $(if ($code -eq 0) { 'done' } else { 'failed' }) $code $(if ($code -ne 0) { "exited $code" } else { '' }) }
        }
        exit $code
    }
    'submit' {
        Need-By
        if (-not $Lease) { $Lease = $CardLease }
        if (-not $Exe) { Fail 'submit needs -Exe <path> (and -ArgList for its arguments)' }
        if ($Quiet -and $NoQuiet) { Fail 'pick one: -Quiet (a timing run) or -NoQuiet' }
        # Quiet on the gpu lease is for timed work, so a gpu job asks for it: -Quiet, or one of quiet's switches. A job on another
        # lease keeps the wait: it's what keeps a build job off an open editor.
        if ($Lease -eq $CardLease -and -not @($script:BoundKeys | Where-Object { $_ -in @('Quiet', 'AllowEditor', 'AllowBuild', 'MaxVramGB', 'MaxUtil', 'SettleSec') }).Count) { $NoQuiet = $true }
        Do-Submit
    }
    'stats' {
        $root = if ($By) { Lane-Root ($By.Trim().ToLower()) } else { '' }
        $all = @(Recent-Jobs ([int][Math]::Ceiling($Days * 24)) | Where-Object { -not $root -or (Lane-Root ([string]$_.by)) -eq $root })
        $kinds = @(Job-Stats $Days $root)
        $ran = 0; foreach ($r in $kinds) { $ran += [int]$r.n }
        $never = @($all | Where-Object { [string]$_.state -in @('expired', 'lost') -or ([string]$_.state -eq 'failed' -and $null -eq $_.exit) }).Count
        $canc = @($all | Where-Object { [string]$_.state -eq 'cancelled' }).Count
        $ovr = @($all | Where-Object { [string]$_.state -eq 'overrun' }).Count
        if ($Json) { [ordered]@{ days = $Days; by = $root; jobs = $all.Count; ran = $ran; neverStarted = $never; cancelled = $canc; overrun = $ovr; kinds = $kinds } | ConvertTo-Json -Depth 4; exit 0 }
        Say "jobs in the last $Days days$(if ($root) { " for $root" }): $($all.Count) submitted, $ran ran, $never never started, $canc cancelled, $ovr stopped at their cap"
        if (-not $kinds.Count) { exit 0 }
        Write-Host ('  {0,-7} {1,4} {2,7} {3,7} {4,6} {5,5} {6,7}  {7}' -f 'lease', 'ran', 'est', 'actual', 'x est', 'late', 'waited', 'what')
        foreach ($r in $kinds) {
            $col = if ($r.ratio -ge 1.5) { 'Red' } elseif ($r.ratio -gt 1) { 'Yellow' } else { 'Gray' }
            Write-Host ('  {0,-7} {1,4} {2,7} {3,7} {4,6} {5,5} {6,7}  {7}' -f $r.lease, $r.n, $r.est, $r.actual, $r.ratio, $r.late, $(if ($null -ne $r.wait) { $r.wait } else { '-' }), $r.what) -ForegroundColor $col
        }
        Say 'est and actual are medians in minutes; late = runs past their estimate; waited = median minutes from submit to the take.'
        exit 0
    }
    'job' {
        if (-not $JobId) {
            $js = @(Recent-Jobs 24 | Where-Object { -not $By -or $_.by -eq $By.Trim().ToLower() })
            if ($Json) { ConvertTo-Json -InputObject @($js) -Depth 4; exit 0 }
            if (-not $js.Count) { Say 'no jobs in the last 24 h'; exit 0 }
            foreach ($j in $js) { Write-Host (Job-Line $j) -ForegroundColor $(switch ([string]$j.state) { 'done' { 'Green' } 'running' { 'Cyan' } 'starting' { 'Cyan' } 'queued' { 'Yellow' } default { 'Red' } }) }
            exit 0
        }
        $jb = Read-Job $JobId
        if (-not $jb) { Fail "no job $JobId in $JobDir" }
        if ($Cancel) {
            $was = [string]$jb.state
            if ($was -notin @('queued', 'starting', 'running')) { Say "job $JobId is already $was"; exit 0 }
            [void](Set-Job $JobId @{ state = 'cancelled'; ended = Now-Iso; why = "cancelled$(if ($By) { " by $($By.Trim().ToLower())" })" })
            Drop-JobEntry ([string]$jb.lease) ([string]$jb.runBy)
            if ($was -ne 'queued') { Stop-JobTree $jb }
            Log-Line "job-cancel $($jb.lease) $($jb.runBy) job $JobId (was $was)"
            Say "job $JobId cancelled (was $was)" Green; exit 0
        }
        if ($Json) { $jb | ConvertTo-Json -Depth 4; exit 0 }
        Write-Host (Job-Line $jb)
        if ($jb.why) { Write-Host "  why: $($jb.why)" -ForegroundColor Yellow }
        Write-Host "  cmd: $($jb.exe) $($jb.args)   (in $($jb.cwd))"
        foreach ($lf in @($jb.out, $jb.err, $jb.log)) {
            if ($lf -and (Test-Path -LiteralPath $lf) -and (Get-Item -LiteralPath $lf).Length) { Write-Host "  -- $lf (last 8 lines)" -ForegroundColor DarkGray; Get-Content -LiteralPath $lf -Tail 8 | ForEach-Object { Write-Host "  $_" } }
        }
        exit 0
    }
}
