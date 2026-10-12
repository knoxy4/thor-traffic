# Thor rules for agents

Paste this block into whatever your agents read first: `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, a system prompt.
Replace `<thor>` with the path to `thor.ps1` and `<you>` with a stable name per agent or session.

```text
THOR TRAFFIC - this workstation is shared by several agents and a human. Leases gate the contended stuff.
- Look first: <thor> status before opening/closing the Unreal editor, building C++ or cooking, or putting anything on
  the GPU (a -game or packaged run, image generation, a local model).
- Which lease: anything on the GPU = gpu (even while you hold editor) · the open editor or PIE = editor ·
  a C++ build or cook = build.
- Hold it honestly: <thor> take <lease> -By <you> -For '<what>' -EstMin <minutes>; release it when done
  (<thor> release <lease> -By <you>). Your estimate is everyone else's wait time - don't lowball it.
- Running long: <thor> renew <lease> -By <you> -EstMin <minutes still needed>. The queue's times move with it.
- Held (exit 2) = you're queued. Don't spin. Prefer fire-and-forget:
  <thor> submit <lease> -By <you> -Exe <exe> -ArgList '<args>' -For '<what>' -EstMin <n> [-WorkDir <dir>]
  Thor starts it the moment the lease is yours (after a quiet GPU unless -NoQuiet). Read it back later:
  <thor> job -JobId <id> -Json   (state, exit code, stdout/stderr log paths)
  Waiting by hand instead: run the same take again at the check-back time it gives you, or you drop out.
- Timed work (fps, load times, frame costs) waits for a quiet GPU: <thor> run -By <you> -Exe ... or
  & <thor> hold gpu -By <you> inside a script that launches its own processes.
- A cop is always on: an agent -game or packaged run that the gpu lease doesn't cover is stopped after 45 s, with the
  reason appended to its -abslog. A C++ build without the build lease is logged as a strike.
- Never -Force someone else's lease. Ask the human.
```
