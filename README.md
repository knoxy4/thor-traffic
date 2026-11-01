<p align="center"><img src="docs/img/banner.png" alt="Thor Traffic Control" width="100%"></p>

<p align="center">
  <img alt="PowerShell 7" src="https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white">
  <img alt="Unreal Engine 5" src="https://img.shields.io/badge/Unreal%20Engine-5-313131?logo=unrealengine&logoColor=white">
  <a href="https://github.com/knoxy4/thor-traffic/actions/workflows/test.yml"><img alt="tests" src="https://github.com/knoxy4/thor-traffic/actions/workflows/test.yml/badge.svg"></a>
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-66d48a">
</p>

**Thor is air-traffic control for a game-dev workstation that AI agents share.** Point three or four coding agents —
Claude Code, Codex, Cursor, your own scripts — at one Unreal Engine project on one machine and they will happily launch
two `-game` runs at once (every fps number is now garbage), close the editor you were working in, and kick off a C++
build while another one is linking. Thor gives the contended resources — **the GPU, the editor, the C++ build** — real
leases with a fair queue, starts queued jobs the moment their lease frees, enforces the rules with a cop, and puts the
whole thing on a live terminal board so the human can see who's doing what.

One PowerShell file. No server, no service account, no database: state is a folder of JSON files guarded by a named mutex.

<p align="center"><img src="docs/img/board.png" alt="The Thor board: GPU load, leases with countdowns, the queue, a 90-minute timeline, running processes tagged by the lease that covers them, and the event log" width="100%"></p>

## What you get

| | |
|---|---|
| 🔒 **Leases** | `editor`, `gpu`, `build`. Advisory, file-backed, with an expiry and an estimate. Tie one to a process and it ends when the process dies — a crashed agent never strands the GPU. |
| 🧾 **A fair queue** | A take that finds the lease held joins its waitlist and gets told its place, its expected start, and when to check back. A freed lease is *kept* for the first in line who can use it now — no barging past anyone ready, and nobody blocked by a waiter who isn't. |
| 🚀 **A dispatcher** | `submit` queues the *launch command itself*. When the lease frees, Thor starts it — no polling, no dead air between jobs. Exit code and stdout/stderr are kept for the agent to read later. |
| ⏱️ **Re-estimates** | Running long? `renew -EstMin <minutes left>` moves your estimate, and everyone queued behind you gets the new time. |
| 🤫 **Quiet-GPU gate** | Timed runs (fps, load times, frame costs) wait until the card is actually idle: no other lease, VRAM and load under a threshold, no editor, no shader compiles, no local LLM. They wait from the queue holding nothing, so a noisy card never blocks work that doesn't need it quiet. `run` and `hold` wait by default; a `gpu` job asks with `-Quiet`. |
| 👮 **The cop** | Stops agent `-game`/packaged runs the gpu lease doesn't cover (after a 45 s grace) and tells the agent why in its own log. C++ builds without the build lease are logged as strikes, never killed. A lease left past its estimate with nothing running goes back once someone's waiting. Your own launches are never touched. |
| 📺 **The board** | Live, colour terminal view with a 90-minute timeline, strikes, and Windows toast alerts when leases change hands, jobs finish or the GPU goes quiet. |

## Quick start

```powershell
git clone https://github.com/knoxy4/thor-traffic
cd thor-traffic

.\thor.ps1 status                                                  # who holds what, what's running, is the GPU quiet
.\thor.ps1 take gpu -By me -For 'profiling pass' -EstMin 20         # take a lease
.\thor.ps1 release gpu -By me

.\install-board.ps1                                                # desktop shortcut: the live board in its own window
.\install-cop.ps1 -StartNow                                        # the cop + dispatcher, always on (logon task)
```

Then tell your agents the rules — paste [`examples/AGENT_RULES.md`](examples/AGENT_RULES.md) into their `CLAUDE.md` /
`AGENTS.md` / system prompt. That block is the whole integration; there is no SDK.

Want to see the board without touching your machine? It ships with a replayable demo:

```powershell
.\demo\seed.ps1 -Dir $env:TEMP\thor-demo
.\thor.ps1 watch -Dir $env:TEMP\thor-demo -Fixture .\demo\fixture.json
```

## What an agent sees

<p align="center"><img src="docs/img/cli.png" alt="An agent session: take, a queued take (exit 2) with its check-back time, submit, a re-estimate, and the job list" width="100%"></p>

Every message is written for an agent to act on: what's held, by whom, until when, your place in line, exactly when to
come back. Exit codes are machine-readable (`0` ok, `2` held — you're queued, `3` GPU not quiet) and every read verb has `-Json`.
A job that's waiting says on what: `job` prints `[waits: ...]`, and `job -Json` has it in `waiting`.

## How it works

```mermaid
flowchart LR
    A1[Agent A] -- take gpu --> L{{gpu lease}}
    A2[Agent B] -- take gpu --> Q[(queue)]
    A3[Agent C] -- submit gpu --> Q
    L -- release / process exits --> D[dispatcher]
    Q --> D
    D -- first ready in line is a job --> R["runner: waits for a quiet GPU if asked, holding nothing, takes the lease, starts the command"]
    D -- first ready in line is a waiter --> K["kept for them until check-back"]
    R -. noisy card so it stands aside .-> Q
    R -- "exit code + logs" --> J[("jobs/id.json")]
    C[cop] -. every 5 s .-> P[processes]
    C -. uncovered -game run .-> X["stop + note in its -abslog"]
    C -. idle lease, someone waiting .-> F["release + note to its holder"]
    C -. runs .-> D
```

- **State** is a folder (`$env:THOR_DIR`, default `%ProgramData%\ThorTraffic`): `leases\*.json`, `queue\*.json`,
  `jobs\*.json` and an append-only `lease.log`. Every read-modify-write happens under one named mutex, so two takes can
  never both win — and nothing blocks while holding it.
- **Leases are files, not mutexes**, because an agent's tool call lives a few seconds and can't hold a handle. A lease has
  an expiry and, optionally, a process: `run`, `hold` and dispatched jobs tie the lease to themselves, so it ends when they do.
- **Coverage** follows the process tree: the cop and the board treat the lease's process, its child, and every descendant
  as covered. One launcher can hold `build` + `gpu` at once.
- **Jobs run detached** (WMI-created, headless console, no inherited handles), so `submit` returns immediately even when
  the job starts on the spot, and a cancelled job takes its whole process tree with it.
- **A wait for quiet holds nothing.** `run`, `hold` and jobs wait from the queue and take the lease after the settle, so its
  estimate starts with the work. While the card is noisy the waiter stands aside: it keeps its place, but the lease isn't
  kept for it, and a plain `take` or a job that isn't waiting for quiet can go past. Once quiet it takes its place back and
  the lease is kept for it through the settle. So a stream of untimed work can delay a timed run while the card stays noisy,
  up to its timeout. `status`, the board and `job` all show who's standing aside and why, and a wait past 15 minutes logs
  `park-long` and raises a toast.
- **A busy lock costs one look, not the job.** A waiter retries when the mutex stays busy or a process listing fails, and a
  job that ends during a busy lock still records its exit code.
- **Abandoned leases go back.** Past its estimate with nothing of its kind running, a lease starts an idle clock (`status`
  shows it). After 10 minutes with someone in its queue, the cop releases it, logs `reap`, raises a toast and leaves a note
  for the holder. A running job is never released, and neither is a lease whose kind of work is running anywhere on the box.

## Leases at a glance

| lease | take it for | default expiry |
|---|---|---|
| `gpu` | `-game` and packaged runs, image generation, loading a local model — anything that wants the card (even while you hold `editor`) | 30 min |
| `editor` | having the Unreal editor open, PIE | 120 min |
| `build` | C++ builds (UBT/UAT), cooks | 60 min |

Two rules keep the queue honest:

- **A lease covers the work, not the session.** Release it the moment that step ends, before you wait on anything else
  (another lease, a job, a build, a human), and take it again when the next step is ready. Don't renew through idle time.
  A step that really is still going says so with `renew -EstMin`, or the cop can release the lease once someone's waiting.
- **A launcher handed to `run` or `submit` must wait for everything it starts.** The lease ends when the launcher exits, so
  anything still running is uncovered, and the cop stops an agent's uncovered game. In a `.cmd`, `start "" /wait` a program
  rather than leaving it in the background.

Agent markers the cop understands out of the box: `-ExecCmds=`, `-abslog=`, `-log=`, `-ResX=`, `bRemoteExecution=False`,
or a known agent host (`claude`, `codex`, `cursor-agent`, `aider`) up the process tree. Add yours with `$env:THOR_AGENT_MARKERS`.

## Command reference

| verb | what it does |
|---|---|
| `status [-Json]` | Leases, queues with expected starts, what's running, quiet-GPU verdict. |
| `take <lease> -By <who> [-For] [-EstMin] [-Minutes] [-HolderPid] [-Wait] [-NoQueue]` | Take a lease or join its queue (exit 2). `-Wait` blocks in the queue. |
| `renew <lease> -By <who> [-EstMin] [-Minutes]` | Extend; `-EstMin` re-estimates and moves the queue's times. Never shortens. |
| `release <lease> -By <who> [-Force]` | Give it back; it's kept for the first in line who can use it. `-Force` only for a holder that's gone. |
| `unqueue <lease> -By <who>` | Leave a queue. |
| `submit [lease] -By <who> -Exe <path> [-ArgList] [-WorkDir] [-EstMin] [-Quiet] [-NoQuiet] [-TimeoutMin] [-Json]` | Queue a launch command; Thor starts it when the lease is yours. A `gpu` job waits for quiet only with `-Quiet` or one of `quiet`'s switches, and the job keeps them. An `editor` or `build` job waits unless `-NoQuiet`. |
| `job [-JobId <id>] [-By <who>] [-Json] [-Cancel]` | A job's state, exit code and output tail, or the job list. `-Cancel` kills the tree. |
| `run -By <who> -Exe <path> [-ArgList] [-Lease gpu] [-NoQuiet]` | Wait in line, wait for quiet, take the lease, run, release, return the exit code. Waits for quiet on any lease unless `-NoQuiet`. |
| `& hold [lease] -By <who> [-NoQuiet]` | For launcher scripts: take the lease tied to the calling process. Waits for quiet on `gpu` only. |
| `quiet [-Wait] [-MaxVramGB 3.5] [-MaxUtil 50] [-SettleSec 20] [-AllowEditor] [-AllowBuild]` | Is the GPU quiet? Exit 3 if not. `run`, `hold` and `submit` take the same switches. |
| `watch [-Every 5] [-NoCop] [-NoToast] [-Plain] [-Frame -Cols -Rows] [-Fixture]` | The live board (and the cop). `-Frame` prints one frame and exits. |
| `cop [-Once] [-CopDryRun] [-CopLenient] [-CopWait] [-ReapAfterMin 10]` | The enforcer + dispatcher without the board. `-CopDryRun` only says what it would stop or release; `-ReapAfterMin 0` keeps abandoned leases. |

### Job states

| state | means |
|---|---|
| `queued` | In the queue, no runner yet. |
| `starting` | Its runner is up. It may be waiting for a quiet GPU, holding nothing; `waiting` says why. |
| `running` | It holds the lease and its command is running. |
| `done` | The command exited 0. |
| `failed` | The command exited non-zero, it never got quiet or the lease within `-TimeoutMin`, or it couldn't start. `why` says which. |
| `cancelled` | `job -Cancel`. Its whole process tree goes with it. |
| `expired` | It left the queue unstarted, past `-TimeoutMin` or unqueued. |
| `lost` | Its runner died without reporting: killed, or the box restarted. |

## Configuration

| variable / flag | default | |
|---|---|---|
| `THOR_DIR` / `-Dir` | `%ProgramData%\ThorTraffic` | where leases, queues, jobs and the log live |
| `THOR_GAME_EXE` / `-GameExe` | `-Win64-(Shipping\|Development\|Test\|DebugGame).exe$` | regex for your packaged game's process name |
| `THOR_AGENT_MARKERS` | — | extra regex that marks a command line as an agent's |
| `THOR_SCRATCH` / `-ScratchDir` | — | per-agent folders; the cop drops `THOR_COP.txt` in `<dir>\<who>\` when it stops a run or releases a lease |
| `-ReapAfterMin` | `10` | minutes a lease stays idle past its estimate, with someone waiting, before the cop releases it; `0` turns that off |
| `-ParkWarnMin` | `15` | minutes a wait for quiet runs before it logs `park-long`; then hourly |

## Honest limits

- **Advisory.** Leases only hold if every agent takes them. The cop enforces the GPU rule for `-game`/packaged runs; the
  rest relies on your agents following the rules block (they do, if it's in their prompt).
- **Windows + PowerShell 7**, NVIDIA for the GPU gate (`nvidia-smi`). Without it the gate reports "no reading", timed runs
  wait, and the cop never releases a `gpu` lease.
- **A timed `gpu` job without `-Quiet` runs on whatever the card is doing.** The only guard is the reminder `submit` prints,
  so put `-Quiet` in your perf scripts.
- **The cop can release a lease you still meant to use.** It errs toward keeping one, but a holder between steps, past its
  estimate with someone waiting, can lose it.
- **A build job's only guard against an open editor is the quiet wait.** With an editor open, `submit build` waits; `-NoQuiet`
  skips that, and the link can then fail on a DLL the editor has loaded.
- **VRAM is a card total** — Windows (WDDM) doesn't report video memory per process.
- **One user.** Agents and the human run as the same Windows user; the state folder isn't an ACL boundary.

## Tests

```powershell
pwsh .\tests\run-tests.ps1     # 128 end-to-end checks in a throwaway state folder, about 9 min; no GPU needed
```

CI runs the same suite on `windows-latest`. It includes `tests\quiet-wait-tests.ps1`, which stubs the GPU reading and the
process list in a copy of `thor.ps1`, on its own mutexes, so it can move the card from noisy to quiet under a waiter that's
already running, hold the lock on purpose and never stall a live queue.
Run that one alone with `-Shell powershell` to check it under Windows PowerShell 5.1.

---

<sub>Built by KNX × SPC — a human and an AI — to keep a pack of agents from trampling one RTX card on a box called THOR.
MIT licensed.</sub>
