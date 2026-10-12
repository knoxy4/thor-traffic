# install-board.ps1 - a desktop shortcut that opens the Thor board in its own sized Windows Terminal window, plus a
# "Thor Traffic" profile in Windows Terminal's dropdown (a settings fragment; your settings.json is never touched).
# Clicking the shortcut again while the board is open just says so and closes the extra tab: one board at a time.
# Usage: .\install-board.ps1 [-Uninstall] [-Cols 150] [-Rows 58]
param([switch]$Uninstall, [int]$Cols = 150, [int]$Rows = 58)
$ErrorActionPreference = 'Stop'
$board = Join-Path $PSScriptRoot 'thor.ps1'
$fragDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\ThorTraffic'
$frag = Join-Path $fragDir 'thor_traffic.json'
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Thor Traffic.lnk'
if ($Uninstall) {
    Remove-Item $frag, $lnk -Force -ErrorAction SilentlyContinue
    Write-Host 'thor board: profile and shortcut removed' -ForegroundColor Green; exit 0
}
$pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pw) { throw 'PowerShell 7 (pwsh) not found: winget install Microsoft.PowerShell' }
$wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
New-Item -ItemType Directory -Force $fragDir | Out-Null
$prof = [ordered]@{
    guid = '{8a4f2c1e-3b7d-4e9a-9c51-2f6d0b8e7a13}'; name = 'Thor Traffic'
    commandline = "`"$pw`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$board`" watch"
    startingDirectory = $PSScriptRoot; tabTitle = 'Thor Traffic'; suppressApplicationTitle = $true
    icon = [string][char]::ConvertFromUtf32(0x1F4E1); closeOnExit = 'always'
    font = [ordered]@{ face = 'Cascadia Mono'; size = 10 }; padding = '6'; background = '#14161A'; cursorShape = 'vintage'
    scrollbarState = 'hidden'; snapOnInput = $false
}
[IO.File]::WriteAllText($frag, (@{ profiles = @($prof) } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
if ($wt) {
    # The command line rides in the shortcut itself: a running Terminal only reads new fragments after a restart.
    $s.TargetPath = $wt
    $s.Arguments = "-w thor-traffic --size $Cols,$Rows --title `"Thor Traffic`" --suppressApplicationTitle --tabColor `"#3A6EB2`" -d `"$PSScriptRoot`" `"$pw`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$board`" watch"
} else {
    $s.TargetPath = $pw; $s.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$board`" watch"
}
$s.WorkingDirectory = $PSScriptRoot
$s.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',143'
$s.Description = 'Thor Traffic Control: leases, queue, next 90 min, running, alerts'
$s.Save()
Write-Host "thor board: shortcut $lnk ($(if ($wt) { 'Windows Terminal' } else { 'pwsh window' })), Terminal profile 'Thor Traffic'" -ForegroundColor Green
exit 0
