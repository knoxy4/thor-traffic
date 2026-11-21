# install-wallpaper.ps1 - builds the three Thor Night web wallpapers into Wallpaper Engine's myprojects folder and, with
# -Apply, puts them on your monitors. The Sky scene carries the clock and the HUD panel fed by thor_hud.py.
#   .\wallpaper\install-wallpaper.ps1                                   # build thor_sky, thor_valley, thor_tower
#   .\wallpaper\install-wallpaper.ps1 -Apply -Monitor @{ sky = 0 }      # build, then apply Sky to monitor 0
#   .\wallpaper\install-wallpaper.ps1 -StartHud -HudArgs '--services OLLAMA=11434 --disks C,D'   # + HUD feed at logon
# Wallpaper Engine is found through Steam's library folders; pass -WallpaperEngine if it lives somewhere unusual.
param(
    [string]$WallpaperEngine,
    [switch]$Apply,
    [hashtable]$Monitor = @{ sky = 0 },
    [string[]]$Leases = @('gpu', 'editor', 'build'),
    [int]$Port = 47823,
    [switch]$StartHud,
    [string]$HudArgs = '',
    [string]$Python
)
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

function Find-WallpaperEngine {
    $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $libs = @($steam -replace '/', '\')
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $we = Join-Path $l 'steamapps\common\wallpaper_engine'
        if (Test-Path (Join-Path $we 'wallpaper64.exe')) { return $we }
    }
    return $null
}

if (-not $WallpaperEngine) { $WallpaperEngine = Find-WallpaperEngine }
if (-not $WallpaperEngine -or -not (Test-Path $WallpaperEngine)) { throw 'Wallpaper Engine not found. Pass -WallpaperEngine <folder that holds wallpaper64.exe>.' }
$Proj = Join-Path $WallpaperEngine 'projects\myprojects'

# The HUD token: thor_hud.py makes the same file on first run; whoever gets there first writes it.
$tokFile = Join-Path $Here 'hud_token.txt'
if (-not (Test-Path $tokFile) -or -not (Get-Content $tokFile -Raw).Trim()) {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [IO.File]::WriteAllText($tokFile, (($bytes | ForEach-Object { $_.ToString('x2') }) -join ''))
}
$token = (Get-Content $tokFile -Raw).Trim()

$walls = [ordered]@{
    sky    = @{ title = 'Thor Night - Sky'; audio = $false
        cfg = [ordered]@{ mode = 'sky'; clock = [ordered]@{ pos = [ordered]@{ left = '4%'; top = '7%' }; align = 'left' }
            meteor = [ordered]@{ min = 20; max = 60; band = 0.45; x0 = 0.06; x1 = 0.45 }; beacon = [ordered]@{ x = 0.677; y = 0.95 }
            hud = [ordered]@{ url = "http://127.0.0.1:$Port"; key = $token; leases = $Leases } } }
    valley = @{ title = 'Thor Night - Valley'; audio = $false
        cfg = [ordered]@{ mode = 'road'; haze = [ordered]@{ y = 0.55; h = 0.2; op = 0.12 } } }
    tower  = @{ title = 'Thor Night - Tower'; audio = $true
        cfg = [ordered]@{ mode = 'portrait'; lamp = [ordered]@{ x = 0.5; y = 0.78; r = 0.5; min = 25; max = 80 }; viz = [ordered]@{ bottom = 3.5 } } }
}

$Utf8 = New-Object Text.UTF8Encoding $false
foreach ($name in $walls.Keys) {
    $w = $walls[$name]
    $dst = Join-Path $Proj "thor_$name"
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item (Join-Path $Here 'index.html') $dst -Force
    Copy-Item (Join-Path $Here "img\$name.jpg") (Join-Path $dst 'wall.jpg') -Force
    Copy-Item (Join-Path $Here "img\${name}_preview.jpg") (Join-Path $dst 'preview.jpg') -Force
    [IO.File]::WriteAllText((Join-Path $dst 'cfg.js'), 'window.CFG=' + ($w.cfg | ConvertTo-Json -Depth 6 -Compress) + ';', $Utf8)
    $pj = [ordered]@{
        contentrating = 'Everyone'
        description   = 'Thor Night: a night-station wallpaper with a live Thor Traffic status panel.'
        file          = 'index.html'
        general       = [ordered]@{
            supportsaudioprocessing = $w.audio
            properties = [ordered]@{ schemecolor = [ordered]@{ order = 0; text = 'ui_browse_properties_scheme_color'; type = 'color'; value = '0.71 0.40 0.11' } }
        }
        preview       = 'preview.jpg'
        tags          = @('Landscape')
        title         = $w.title
        type          = 'web'
        visibility    = 'private'
    }
    [IO.File]::WriteAllText((Join-Path $dst 'project.json'), ($pj | ConvertTo-Json -Depth 6), $Utf8)
    "built $dst"
}

if ($StartHud) {
    if (-not $Python) {
        $Python = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
        if (-not $Python) { $Python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
    }
    if (-not $Python) { throw 'Python 3 not found. Pass -Python <path to pythonw.exe>.' }
    $script = Join-Path $Here 'thor_hud.py'
    $arg = "`"$script`" --port $Port --leases $($Leases -join ',') $HudArgs".Trim()
    $act = New-ScheduledTaskAction -Execute $Python -Argument $arg -WorkingDirectory $Here
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'Thor HUD feed' -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    Start-ScheduledTask -TaskName 'Thor HUD feed'
    "HUD feed registered as the 'Thor HUD feed' logon task and started on 127.0.0.1:$Port"
}

if ($Apply) {
    $exe = Join-Path $WallpaperEngine 'wallpaper64.exe'
    foreach ($name in $Monitor.Keys) {
        if (-not $walls.Contains($name)) { Write-Warning "no scene called $name (sky, valley, tower)"; continue }
        & $exe -control openWallpaper -file (Join-Path $Proj "thor_$name\project.json") -monitor $Monitor[$name]
        Start-Sleep 3
        "applied $name -> monitor $($Monitor[$name])"
    }
}
