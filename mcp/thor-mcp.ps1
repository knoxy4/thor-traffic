# thor-mcp.ps1 - Thor as an MCP server on stdio, so an agent's harness calls it as tools instead of through a shell. Each tool runs
# thor.ps1 with the arguments it was given and returns what thor printed, with the exit code on the first line. stdio only: no
# port and no listener, so the only thing that can reach it is the process that started it. Register it in the agent's MCP
# config as a command, for example:  pwsh -NoProfile -File <repo>\mcp\thor-mcp.ps1   (-Dir and -ProfilePath, when given, go to
# every call). thor_submit runs whatever command line it is handed, the same as thor.ps1 submit does: give it only to agents you
# already let run commands. Run it under PowerShell 7: Windows PowerShell 5.1 mangles quotes inside an argList it passes on.
param([string]$Dir = '', [string]$ProfilePath = '', [string]$Thor = (Join-Path (Split-Path -Parent $PSScriptRoot) 'thor.ps1'))
$ErrorActionPreference = 'Stop'
$Shell = (Get-Process -Id $PID).Path
$S = @{ type = 'string' }; $N = @{ type = 'number' }; $B = @{ type = 'boolean' }
function Schema($Props, [string[]]$Req = @()) { $o = [ordered]@{ type = 'object'; properties = $Props }; if ($Req.Count) { $o.required = $Req }; return $o }
$Tools = [ordered]@{
    thor_status  = @{ verb = 'status'; fixed = @('-Json'); schema = (Schema ([ordered]@{}))
        desc = 'Who holds each lease, each queue with expected starts, what is running and whether the GPU is quiet, as JSON.' }
    thor_take    = @{ verb = 'take'; schema = (Schema ([ordered]@{ lease = $S; by = $S; for = $S; estMin = $N; minutes = $N; noQueue = $B }) @('lease', 'by'))
        desc = 'Take a lease, or join its queue. Exit 2 means queued or kept for someone else: come back at the time it gives and take again, which keeps your place.' }
    thor_renew   = @{ verb = 'renew'; schema = (Schema ([ordered]@{ lease = $S; by = $S; estMin = $N; minutes = $N }) @('lease', 'by'))
        desc = 'Extend a lease you hold. estMin re-estimates the minutes still needed, which moves the queue and the cap.' }
    thor_release = @{ verb = 'release'; schema = (Schema ([ordered]@{ lease = $S; by = $S }) @('lease', 'by'))
        desc = 'Give a lease back the moment the step that needed it ends.' }
    thor_unqueue = @{ verb = 'unqueue'; schema = (Schema ([ordered]@{ lease = $S; by = $S }) @('lease', 'by'))
        desc = 'Leave a queue.' }
    thor_submit  = @{ verb = 'submit'; fixed = @('-Json'); schema = (Schema ([ordered]@{ lease = $S; by = $S; exe = $S; argList = $S; workDir = $S; for = $S; estMin = $N; quiet = $B; noQuiet = $B; timeoutMin = $N; notBefore = $S; priority = $N; preemptible = $B; noGate = $B }) @('by', 'exe'))
        desc = 'Queue a launch command as a job; Thor starts it when the lease is free. Returns the job as JSON; read it back with thor_job.' }
    thor_job     = @{ verb = 'job'; fixed = @('-Json'); schema = (Schema ([ordered]@{ jobId = $S; by = $S; cancel = $B }))
        desc = 'A job by id (state, exit code, output files), or the jobs of one -By. cancel stops it and its whole process tree.' }
    thor_check   = @{ verb = 'check'; fixed = @('-Json'); schema = (Schema ([ordered]@{ exe = $S; argList = $S; by = $S }) @('exe'))
        desc = 'Before launching something: what kind Thor sees it as, which lease it needs, and whether you hold it. verdict go, take first, or no kind.' }
    thor_quiet   = @{ verb = 'quiet'; schema = (Schema ([ordered]@{ by = $S; allowEditor = $B; allowBuild = $B }))
        desc = 'Is the GPU quiet enough for a timed run? Exit 3 and the reasons if not.' }
    thor_stats   = @{ verb = 'stats'; fixed = @('-Json'); schema = (Schema ([ordered]@{ days = $N; by = $S }))
        desc = 'What jobs took against what they said they would, per kind of job.' }
}
# UTF-8 first, then the writer: a writer taken before keeps the console's old code page. THOR_UTF8 makes each thor.ps1 child
# write UTF-8 too, since a hidden console would hand it the OEM code page.
try { [Console]::InputEncoding = New-Object Text.UTF8Encoding $false; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
$Out = [Console]::Out
$env:THOR_UTF8 = '1'
function Send($Msg) { $Out.WriteLine(($Msg | ConvertTo-Json -Depth 12 -Compress)); $Out.Flush() }
function Reply($Id, $Result) { Send ([ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result }) }
function Refuse($Id, [int]$Code, [string]$Text) { Send ([ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $Text } }) }
function Call-Thor([string]$Name, $Arguments) {
    $t = $Tools[$Name]
    $given = @{}; if ($Arguments) { foreach ($pr in $Arguments.PSObject.Properties) { $given[$pr.Name] = $pr.Value } }
    foreach ($r in @($t.schema.required)) { if ($r -and ($null -eq $given[$r] -or "$($given[$r])" -eq '')) { return @{ text = "missing argument: $r"; bad = $true } } }
    $al = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Thor, $t.verb)
    if ($given.ContainsKey('lease') -and "$($given.lease)") {
        if ("$($given.lease)" -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,15}$') { return @{ text = "lease '$($given.lease)' is not a lease name"; bad = $true } }
        $al += [string]$given.lease
    }
    foreach ($k in $t.schema.properties.Keys) {
        if ($k -eq 'lease' -or -not $given.ContainsKey($k) -or $null -eq $given[$k]) { continue }
        $v = $given[$k]
        if ($t.schema.properties[$k].type -eq 'boolean') {
            # A real JSON boolean, or the words true/false: a string "false" is truthy to PowerShell, and here it could cancel a job.
            if ($v -is [bool]) { $on = $v }
            elseif ("$v" -match '^(?i:true|false)$') { $on = "$v" -ieq 'true' }
            else { return @{ text = "$k must be true or false, not '$v'"; bad = $true } }
            if ($on) { $al += "-$k" }
            continue
        }
        # ConvertFrom-Json turns an ISO time into a DateTime, whose plain [string] has no zone: hand it on as ISO, in UTC.
        if ($v -is [datetime]) { $v = $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.FFFFFFFZ', [Globalization.CultureInfo]::InvariantCulture) }
        elseif ($v -is [double] -or $v -is [decimal] -or $v -is [single]) { $v = ([double]$v).ToString([Globalization.CultureInfo]::InvariantCulture) }
        if ("$v" -eq '') { continue }
        # -name:value as one argument, so a value that starts with a dash (argList "-game") stays a value.
        $al += "-$k`:$v"
    }
    $al += @($t.fixed | Where-Object { $_ })
    if ($Dir) { $al += @('-Dir', $Dir) }
    if ($ProfilePath) { $al += @('-ProfilePath', $ProfilePath) }
    $o = & $Shell @al 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    return @{ text = "exit $code`n$(($o -join "`n").Trim())"; bad = ($code -eq 1) }
}
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $line = $line.TrimStart([char]0xFEFF)
    if (-not $line.Trim()) { continue }
    try { $m = $line | ConvertFrom-Json } catch { Refuse $null -32700 'parse error'; continue }
    $hasId = @($m.PSObject.Properties.Name) -contains 'id'; $id = $m.id
    switch ([string]$m.method) {
        'initialize' {
            $pv = if ($m.params -and $m.params.protocolVersion) { [string]$m.params.protocolVersion } else { '2025-06-18' }
            Reply $id ([ordered]@{ protocolVersion = $pv; capabilities = [ordered]@{ tools = @{} }; serverInfo = [ordered]@{ name = 'thor-traffic'; version = '1.0' } })
        }
        'ping' { Reply $id @{} }
        'tools/list' {
            $list = @(foreach ($k in $Tools.Keys) { [ordered]@{ name = $k; description = $Tools[$k].desc; inputSchema = $Tools[$k].schema } })
            Reply $id ([ordered]@{ tools = $list })
        }
        'tools/call' {
            $nm = [string]$m.params.name
            if (-not $Tools.Contains($nm)) { Refuse $id -32602 "unknown tool: $nm"; break }
            try { $r = Call-Thor $nm $m.params.arguments } catch { $r = @{ text = "thor-mcp: $($_.Exception.Message)"; bad = $true } }
            Reply $id ([ordered]@{ content = @([ordered]@{ type = 'text'; text = $r.text }); isError = [bool]$r.bad })
        }
        default { if ($hasId -and -not ([string]$m.method).StartsWith('notifications/')) { Refuse $id -32601 "method not found: $($m.method)" } }
    }
}
