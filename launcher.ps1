# Species: Unknown mod launcher.
# Keeps the mod loader and mods in sync with the pack published on GitHub, then starts the game through Steam.
# Plain ASCII on purpose: Windows PowerShell 5.1 reads scripts without a BOM as ANSI.
param(
    [ValidateSet('install', 'play', 'vanilla', 'uninstall', 'status')]
    [string]$Mode = 'play',
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/thetomtoro/species-mods/main/manifest.json',
    [string]$HomeDir = (Join-Path $env:LOCALAPPDATA 'SpeciesMods'),
    [string]$SteamLibrary = '',
    [string]$DesktopDir = '',
    [string]$ConfigDir = (Join-Path $env:LOCALAPPDATA 'SpeciesUnknown\Saved\Config\Windows'),
    [switch]$NoLaunch,
    [switch]$NoPause,
    [switch]$SelfUpdated
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$AppId = 2747330
$ExeName = 'SpeciesUnknown-Win64-Shipping'
$ModdedShortcut = 'Species Unknown (Modded).lnk'
$VanillaShortcut = 'Species Unknown (No Mods).lnk'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'Species Unknown Mods' } catch {}
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Say([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
    try {
        if (-not (Test-Path $HomeDir)) { New-Item -ItemType Directory -Force $HomeDir | Out-Null }
        Add-Content -Path (Join-Path $HomeDir 'launcher.log') -Value ("{0}  [{1}] {2}" -f (Get-Date -Format 's'), $Mode, $Text) -Encoding UTF8
    } catch {}
}
function Hold([int]$Seconds) { if (-not $NoPause) { Start-Sleep -Seconds $Seconds } }
function Wait-Key {
    if ($NoPause) { return }
    Write-Host ''
    Write-Host 'Press Enter to close this window.'
    try { [void][Console]::ReadLine() } catch {}
}

function Find-Game {
    $libraries = @()
    if ($SteamLibrary) {
        $libraries += $SteamLibrary
    } else {
        $steam = $null
        try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
        if (-not $steam) {
            try { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch {}
        }
        if (-not $steam) { return $null }
        $steam = $steam -replace '/', '\'
        $libraries += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($match in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += ($match.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $acf = Join-Path $library "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path $acf)) { continue }
        $text = Get-Content $acf -Raw
        $installDir = [regex]::Match($text, '"installdir"\s+"([^"]+)"').Groups[1].Value
        $buildId = [regex]::Match($text, '"buildid"\s+"([^"]+)"').Groups[1].Value
        if (-not $installDir) { continue }
        $win64 = Join-Path $library "steamapps\common\$installDir\SpeciesUnknown\Binaries\Win64"
        if (Test-Path $win64) {
            return @{ Win64 = $win64; BuildId = $buildId; Exe = (Join-Path $win64 "$ExeName.exe") }
        }
    }
    return $null
}

function Test-GameRunning($Game) {
    foreach ($process in @(Get-Process -Name $ExeName -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch {}
        if (-not $path -or $path -ieq $Game.Exe) { return $true }
    }
    return $false
}

function Get-Manifest {
    try {
        $separator = '?'
        if ($ManifestUrl -match '\?') { $separator = '&' }
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri ($ManifestUrl + $separator + 't=' + [DateTime]::UtcNow.Ticks)
        $manifest = $response.Content | ConvertFrom-Json
        if ($manifest.schema -ne 1) { throw "unsupported pack format $($manifest.schema)" }
        return $manifest
    } catch {
        Say "Could not reach the mod server ($($_.Exception.Message))." 'DarkYellow'
        return $null
    }
}

function Get-Download([string]$Url, [string]$Sha256, [string]$Name) {
    $cache = Join-Path $HomeDir 'cache'
    if (-not (Test-Path $cache)) { New-Item -ItemType Directory -Force $cache | Out-Null }
    $target = Join-Path $cache $Name
    if ((Test-Path $target) -and ((Get-FileHash $target -Algorithm SHA256).Hash -ieq $Sha256)) { return $target }
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $Url -OutFile $target
    $actual = (Get-FileHash $target -Algorithm SHA256).Hash
    if ($actual -ine $Sha256) {
        Remove-Item $target -Force
        throw "Download of $Name did not match its checksum."
    }
    return $target
}

function Expand-Pack([string]$Zip, [string]$Destination) {
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $root ($entry.FullName -replace '/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Bad path in pack: $($entry.FullName)" }
            # Never overwrite a mod's saved data.
            if (($entry.FullName -match '^ue4ss/Mods/[^/]+/Data/') -and (Test-Path $target)) { continue }
            $folder = Split-Path $target -Parent
            if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force $folder | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}

function Get-StatePath($Game) { Join-Path $Game.Win64 'ue4ss\speciesmods.json' }
function Get-State($Game) {
    $path = Get-StatePath $Game
    if (Test-Path $path) {
        try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch {}
    }
    return $null
}
function Set-State($Game, $Manifest, [string[]]$ModNames) {
    $old = Get-State $Game
    $state = [ordered]@{
        pack          = $Manifest.version
        loader        = $Manifest.loader.id
        mods          = $Manifest.mods.id
        mod_names     = @($ModNames)
        content       = $(if ($old) { $old.content } else { $null })
        content_files = $(if ($old -and $old.content_files) { @($old.content_files) } else { @() })
        engine_ini    = $(if ($old -and $old.engine_ini) { @($old.engine_ini) } else { @() })
        tested_builds = @($Manifest.game.tested_builds)
        updated       = (Get-Date -Format 's')
    }
    $state | ConvertTo-Json | Set-Content -Path (Get-StatePath $Game) -Encoding UTF8
}

# Mod content (new monsters and the like) lives in the game's Content\Paks\~mods folder, and the game is told to
# load it by one line in its Engine.ini. Both are switched together with the loader: content files are parked by
# adding ".off" to their names, and the line is added or taken out. The line must never be present without the
# content, or the game cannot start.
function Get-ContentDir($Game) { Join-Path (Split-Path (Split-Path $Game.Win64 -Parent) -Parent) 'Content\Paks\~mods' }
function Get-ContentFiles($Game) {
    $state = Get-State $Game
    if ($state -and $state.content_files) { return @($state.content_files) }
    return @()
}
function Get-EngineLines($Game) {
    $state = Get-State $Game
    if ($state -and $state.engine_ini) { return @($state.engine_ini) }
    return @()
}
function Set-EngineIni($Lines, [bool]$On) {
    if (-not $Lines -or @($Lines).Count -eq 0) { return }
    $path = Join-Path $ConfigDir 'Engine.ini'
    $text = ''
    $unicode = $false
    if (Test-Path $path) {
        $item = Get-Item $path -Force
        if ($item.IsReadOnly) { $item.IsReadOnly = $false }
        $bytes = [IO.File]::ReadAllBytes($path)
        $unicode = ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
        if ($unicode) { $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
        else { $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes) }
    } elseif (-not $On) { return }
    $rows = New-Object System.Collections.Generic.List[string]
    if ($text.Trim() -ne '') { foreach ($row in ($text -split "`r?`n")) { $rows.Add($row) } }
    foreach ($line in @($Lines)) {
        $section = '[' + $line.section + ']'
        $entry = $line.key + '=' + $line.value
        # take out any earlier copy of this key in this section
        $inSection = $false
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $trimmed = $rows[$i].Trim()
            if ($trimmed.StartsWith('[')) { $inSection = ($trimmed -ieq $section) }
            elseif ($inSection -and $trimmed.StartsWith($line.key + '=', [StringComparison]::OrdinalIgnoreCase)) { $rows.RemoveAt($i); $i-- }
        }
        if ($On) {
            $at = -1
            for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Trim() -ieq $section) { $at = $i; break } }
            if ($at -ge 0) { $rows.Insert($at + 1, $entry) }
            else {
                if ($rows.Count -gt 0 -and $rows[$rows.Count - 1].Trim() -ne '') { $rows.Add('') }
                $rows.Add('; Added by the Species: Unknown mod pack. Read-only on purpose: the game deletes this file on exit otherwise.')
                $rows.Add($section)
                $rows.Add($entry)
            }
        } else {
            # drop the section header and our comment if nothing is left under it
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ($rows[$i].Trim() -ieq $section) {
                    $next = $i + 1
                    while ($next -lt $rows.Count -and $rows[$next].Trim() -eq '') { $next++ }
                    if ($next -ge $rows.Count -or $rows[$next].Trim().StartsWith('[')) {
                        $rows.RemoveAt($i)
                        while ($i -gt 0 -and $rows[$i - 1].Trim().StartsWith(';') -and $rows[$i - 1] -match 'mod') { $rows.RemoveAt($i - 1); $i-- }
                    }
                    break
                }
            }
        }
    }
    $out = (($rows.ToArray()) -join "`r`n").TrimEnd() + "`r`n"
    if (-not $On -and $out.Trim() -eq '') {
        if (Test-Path $path) { Remove-Item $path -Force }
        return
    }
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Force $ConfigDir | Out-Null }
    if ($unicode) { [IO.File]::WriteAllText($path, $out, [Text.Encoding]::Unicode) }
    else { [IO.File]::WriteAllText($path, $out, (New-Object Text.UTF8Encoding($false))) }
    if ($On) { (Get-Item $path -Force).IsReadOnly = $true }
}
function Set-Content-State($Game, [bool]$On) {
    $dir = Get-ContentDir $Game
    $files = Get-ContentFiles $Game
    $ready = (@($files).Count -gt 0)
    foreach ($name in $files) {
        if ($name -notmatch '^[A-Za-z0-9_\-\.]+$') { continue }
        $live = Join-Path $dir $name
        $parked = "$live.off"
        if ($On) {
            if ((Test-Path $parked) -and -not (Test-Path $live)) { Rename-Item $parked $name }
            elseif ((Test-Path $parked) -and (Test-Path $live)) { Remove-Item $parked -Force }
            if (-not (Test-Path $live)) { $ready = $false }
        } else {
            if (Test-Path $live) {
                if (Test-Path $parked) { Remove-Item $parked -Force }
                Rename-Item $live "$name.off"
            }
        }
    }
    # the line goes in only when every content file is really there
    Set-EngineIni (Get-EngineLines $Game) ($On -and $ready)
}

function Set-Loader($Game, [bool]$On) {
    $live = Join-Path $Game.Win64 'dwmapi.dll'
    $parked = Join-Path $Game.Win64 'dwmapi.dll.off'
    if ($On) {
        if ((Test-Path $parked) -and -not (Test-Path $live)) { Rename-Item $parked 'dwmapi.dll' }
        elseif ((Test-Path $parked) -and (Test-Path $live)) { Remove-Item $parked -Force }
    } else {
        if (Test-Path $live) {
            if (Test-Path $parked) { Remove-Item $parked -Force }
            Rename-Item $live 'dwmapi.dll.off'
        }
    }
    try { Set-Content-State $Game $On } catch { Say "Mod content could not be switched ($($_.Exception.Message))." 'DarkYellow' }
}
function Test-LoaderOn($Game) { Test-Path (Join-Path $Game.Win64 'dwmapi.dll') }

function Update-Loader($Game, $Manifest) {
    $zip = Get-Download $Manifest.loader.url $Manifest.loader.sha256 ("loader-" + $Manifest.loader.id + ".zip")
    $ue4ss = Join-Path $Game.Win64 'ue4ss'
    $state = Get-State $Game
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ((Test-Path $ue4ss) -and -not $state) {
        # A mod loader someone else installed. Move it aside instead of mixing files.
        Say 'Found an existing mod loader; moving it aside as a backup.' 'DarkYellow'
        Rename-Item $ue4ss "ue4ss.backup-$stamp"
        foreach ($name in 'dwmapi.dll', 'dwmapi.dll.off') {
            $file = Join-Path $Game.Win64 $name
            if (Test-Path $file) { Rename-Item $file "$name.backup-$stamp" }
        }
    } elseif (Test-Path $ue4ss) {
        Get-ChildItem $ue4ss -Force | Where-Object { $_.Name -ne 'Mods' -and $_.Name -ne 'speciesmods.json' } | Remove-Item -Recurse -Force
        foreach ($name in 'dwmapi.dll', 'dwmapi.dll.off') {
            $file = Join-Path $Game.Win64 $name
            if (Test-Path $file) { Remove-Item $file -Force }
        }
    } else {
        foreach ($name in 'dwmapi.dll', 'dwmapi.dll.off') {
            $file = Join-Path $Game.Win64 $name
            if (Test-Path $file) { Rename-Item $file "$name.backup-$stamp" }
        }
    }
    Expand-Pack $zip $Game.Win64
}

function Update-Mods($Game, $Manifest) {
    $zip = Get-Download $Manifest.mods.url $Manifest.mods.sha256 ("mods-" + $Manifest.mods.id + ".zip")
    $modsDir = Join-Path $Game.Win64 'ue4ss\Mods'
    $new = @($Manifest.mods.list | ForEach-Object { $_.name })
    $old = @()
    $state = Get-State $Game
    if ($state -and $state.mod_names) { $old = @($state.mod_names) }
    foreach ($name in (@($old) + @($new) | Select-Object -Unique)) {
        if ($name -notmatch '^[A-Za-z0-9_\-]+$') { throw "Bad mod name in pack: $name" }
        $dir = Join-Path $modsDir $name
        if (-not (Test-Path $dir)) { continue }
        if ($new -contains $name) {
            Get-ChildItem $dir -Force | Where-Object { $_.Name -ne 'Data' } | Remove-Item -Recurse -Force
        } else {
            Remove-Item $dir -Recurse -Force
        }
    }
    foreach ($name in 'mods.txt', 'mods.json') {
        $file = Join-Path $modsDir $name
        if (Test-Path $file) { Remove-Item $file -Force }
    }
    Expand-Pack $zip $Game.Win64
    return $new
}

# Download the content pack if it changed, replace the files in the game's ~mods folder, and remember what was
# put there (so it can be parked, replaced or removed later).
function Update-Content($Game, $Manifest) {
    $want = $Manifest.content
    $state = Get-State $Game
    $have = $null
    if ($state) { $have = $state.content }
    $wantId = $null
    if ($want) { $wantId = $want.id }
    if ($have -eq $wantId) { return $false }
    $dir = Get-ContentDir $Game
    # out with the old: the line first, then the files
    Set-EngineIni (Get-EngineLines $Game) $false
    foreach ($name in (Get-ContentFiles $Game)) {
        if ($name -notmatch '^[A-Za-z0-9_\-\.]+$') { continue }
        foreach ($file in (Join-Path $dir $name), (Join-Path $dir "$name.off")) {
            if (Test-Path $file) { Remove-Item $file -Force }
        }
    }
    $files = @()
    $lines = @()
    if ($want) {
        $zip = Get-Download $want.url $want.sha256 ("content-" + $want.id + ".zip")
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $root = [IO.Path]::GetFullPath($dir).TrimEnd('\') + '\'
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName -notmatch '^[A-Za-z0-9_\-\.]+$') { throw "Bad file name in content pack: $($entry.FullName)" }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $root $entry.FullName), $true)
                $files += $entry.FullName
            }
        } finally { $archive.Dispose() }
        foreach ($line in @($want.engine_ini)) {
            if ($line.section -notmatch '^/Script/[A-Za-z0-9_\.]+$' -or $line.key -notmatch '^[A-Za-z0-9_]+$' -or $line.value -notmatch '^/Game/Mods/[A-Za-z0-9_/\.]+$') { throw 'Bad settings line in content pack.' }
            $lines += [ordered]@{ section = $line.section; key = $line.key; value = $line.value }
        }
    }
    $path = Get-StatePath $Game
    $state = Get-State $Game
    $table = [ordered]@{}
    if ($state) { foreach ($p in $state.PSObject.Properties) { $table[$p.Name] = $p.Value } }
    $table['content'] = $wantId
    $table['content_files'] = @($files)
    $table['engine_ini'] = @($lines)
    $table | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
    return $true
}

function Update-Self($Manifest) {
    if ($SelfUpdated -or -not $Manifest.launcher -or -not $PSCommandPath) { return }
    $homeFull = [IO.Path]::GetFullPath($HomeDir).TrimEnd('\') + '\'
    if (-not [IO.Path]::GetFullPath($PSCommandPath).StartsWith($homeFull, [StringComparison]::OrdinalIgnoreCase)) { return }
    if ((Get-FileHash $PSCommandPath -Algorithm SHA256).Hash -ieq $Manifest.launcher.sha256) { return }
    try {
        $new = Get-Download $Manifest.launcher.url $Manifest.launcher.sha256 ("launcher-" + $Manifest.launcher.id + ".ps1")
        Copy-Item $new $PSCommandPath -Force
    } catch {
        Say "Launcher update skipped ($($_.Exception.Message))." 'DarkYellow'
        return
    }
    Say 'Launcher updated.' 'DarkGray'
    $arguments = @{}
    foreach ($key in $script:Bound.Keys) { $arguments[$key] = $script:Bound[$key] }
    $arguments['SelfUpdated'] = $true
    & $PSCommandPath @arguments
    exit $LASTEXITCODE
}

function Get-Desktop { if ($DesktopDir) { return $DesktopDir }; return [Environment]::GetFolderPath('Desktop') }
function New-Shortcuts($Game) {
    $shell = New-Object -ComObject WScript.Shell
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcher = Join-Path $HomeDir 'launcher.ps1'
    foreach ($item in @(@($ModdedShortcut, 'play', 'Play Species: Unknown with the latest mods'), @($VanillaShortcut, 'vanilla', 'Play Species: Unknown with mods turned off'))) {
        $shortcut = $shell.CreateShortcut((Join-Path (Get-Desktop) $item[0]))
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -Mode $($item[1])"
        $shortcut.WorkingDirectory = $HomeDir
        $shortcut.Description = $item[2]
        if (Test-Path $Game.Exe) { $shortcut.IconLocation = "$($Game.Exe),0" }
        $shortcut.Save()
    }
    $uninstall = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0launcher.ps1`" -Mode uninstall`r`n"
    Set-Content -Path (Join-Path $HomeDir 'Uninstall Species Mods.bat') -Value $uninstall -Encoding ASCII -NoNewline
}

function Start-Game {
    if ($NoLaunch) { Say '(launch skipped)' 'DarkGray'; return }
    Start-Process "steam://rungameid/$AppId"
}

# Decide whether mods should be on, bring files up to date, and return a short status line.
function Sync-Mods($Game, $Manifest) {
    $state = Get-State $Game
    if (-not $Manifest) {
        if (-not $state) {
            Say 'Mods are not installed yet and the mod server is unreachable. Starting without mods.' 'Yellow'
            return $false
        }
        if ($state.tested_builds -and (@($state.tested_builds) -notcontains $Game.BuildId)) {
            Set-Loader $Game $false
            Say "The game updated (build $($Game.BuildId)) and the mods could not be checked against it. Mods are off for this session." 'Yellow'
            return $false
        }
        Say "Using the mods already installed (pack $($state.pack))." 'DarkYellow'
        return (Test-LoaderOn $Game)
    }
    if (-not $Manifest.enabled) {
        Set-Loader $Game $false
        $note = 'Mods are switched off for everyone right now.'
        if ($Manifest.message) { $note = "$note $($Manifest.message)" }
        Say $note 'Yellow'
        return $false
    }
    if (@($Manifest.game.tested_builds) -notcontains $Game.BuildId) {
        Set-Loader $Game $false
        Say "Your game is build $($Game.BuildId); the mods were tested on build $(@($Manifest.game.tested_builds) -join ', ')." 'Yellow'
        Say 'Mods are off until they are confirmed on your version. If Steam has a game update waiting, install it.' 'Yellow'
        return $false
    }
    $changed = $false
    try {
        if (-not $state -or $state.loader -ne $Manifest.loader.id) {
            Say 'Updating the mod loader...' 'Cyan'
            Update-Loader $Game $Manifest
            $state = $null
            $changed = $true
        }
        if (-not $state -or $state.mods -ne $Manifest.mods.id) {
            Say 'Updating mods...' 'Cyan'
            $names = Update-Mods $Game $Manifest
            Set-State $Game $Manifest $names
            $changed = $true
        } elseif ($state.pack -ne $Manifest.version -or (@($state.tested_builds) -join ',') -ne (@($Manifest.game.tested_builds) -join ',')) {
            Set-State $Game $Manifest @($state.mod_names)
        }
        $wantContent = $null
        if ($Manifest.content) { $wantContent = $Manifest.content.id }
        if ((Get-State $Game).content -ne $wantContent) {
            if ($wantContent) { Say 'Updating mod content...' 'Cyan' }
            if (Update-Content $Game $Manifest) { $changed = $true }
        }
    } catch {
        Say "Update failed: $($_.Exception.Message)" 'Red'
        if (-not (Get-State $Game)) {
            Set-Loader $Game $false
            Say 'Starting without mods.' 'Yellow'
            return $false
        }
        Set-Loader $Game $true
        Say "Keeping the mods you already have (pack $((Get-State $Game).pack))." 'Yellow'
        return $true
    }
    Set-Loader $Game $true
    $list = (@($Manifest.mods.list | ForEach-Object { $_.name }) -join ', ')
    if ($changed) { Say "Mods updated to pack $($Manifest.version): $list" 'Green' }
    else { Say "Mods are up to date (pack $($Manifest.version): $list)." 'Green' }
    if ($Manifest.message) { Say $Manifest.message 'Cyan' }
    return $true
}

$script:Bound = $PSBoundParameters
$exitCode = 0
try {
    $game = Find-Game
    if (-not $game) {
        Say 'Could not find Species: Unknown in your Steam library. Install it through Steam, run it once, then try again.' 'Red'
        Wait-Key
        exit 1
    }

    if ($Mode -eq 'status') {
        $state = Get-State $game
        $manifest = Get-Manifest
        Say "Game folder : $($game.Win64)"
        Say "Game build  : $($game.BuildId)"
        Say "Game running: $(Test-GameRunning $game)"
        if ($state) { Say "Installed   : pack $($state.pack), mods [$(@($state.mod_names) -join ', ')], content [$(@($state.content_files) -join ', ')], loader on = $(Test-LoaderOn $game)" }
        else { Say 'Installed   : nothing from this launcher' }
        if ($manifest) { Say "Published   : pack $($manifest.version), enabled = $($manifest.enabled), tested builds [$(@($manifest.game.tested_builds) -join ', ')]" }
        exit 0
    }

    if (Test-GameRunning $game) {
        Say 'Species: Unknown is already running. Close the game first, then try again.' 'Yellow'
        Hold 6
        exit 0
    }

    switch ($Mode) {
        'install' {
            Say 'Setting up Species: Unknown mods...' 'Cyan'
            $manifest = Get-Manifest
            if (-not $manifest) { throw 'The mod server could not be reached. Check your internet connection and run the installer again.' }
            Update-Self $manifest
            New-Shortcuts $game
            $on = Sync-Mods $game $manifest
            Write-Host ''
            Say 'Setup finished.' 'Green'
            Say "To play with mods, use the '$($ModdedShortcut -replace '\.lnk$', '')' shortcut on your desktop. It checks for updates every time."
            Say "To play without mods, use '$($VanillaShortcut -replace '\.lnk$', '')'."
            Wait-Key
        }
        'play' {
            $manifest = Get-Manifest
            if ($manifest) { Update-Self $manifest }
            $on = Sync-Mods $game $manifest
            Say 'Starting Species: Unknown...'
            Start-Game
            if ($on) { Hold 2 } else { Hold 8 }
        }
        'vanilla' {
            Set-Loader $game $false
            Say 'Mods are off. Starting Species: Unknown...' 'Green'
            Start-Game
            Hold 2
        }
        'uninstall' {
            $state = Get-State $game
            if ($state) {
                Set-EngineIni (Get-EngineLines $game) $false
                foreach ($name in (Get-ContentFiles $game)) {
                    if ($name -notmatch '^[A-Za-z0-9_\-\.]+$') { continue }
                    foreach ($file in (Join-Path (Get-ContentDir $game) $name), (Join-Path (Get-ContentDir $game) "$name.off")) {
                        if (Test-Path $file) { Remove-Item $file -Force }
                    }
                }
                Remove-Item (Join-Path $game.Win64 'ue4ss') -Recurse -Force
                foreach ($name in 'dwmapi.dll', 'dwmapi.dll.off') {
                    $file = Join-Path $game.Win64 $name
                    if (Test-Path $file) { Remove-Item $file -Force }
                }
            }
            foreach ($name in $ModdedShortcut, $VanillaShortcut) {
                $file = Join-Path (Get-Desktop) $name
                if (Test-Path $file) { Remove-Item $file -Force }
            }
            $cache = Join-Path $HomeDir 'cache'
            if (Test-Path $cache) { Remove-Item $cache -Recurse -Force }
            Say 'Mods, mod content, the mod loader and the desktop shortcuts have been removed. The game itself was not touched.' 'Green'
            Say "You can delete this folder too: $HomeDir"
            Wait-Key
        }
    }
} catch {
    $exitCode = 1
    Say "Something went wrong: $($_.Exception.Message)" 'Red'
    if ($Mode -eq 'play') {
        Say 'Starting the game anyway.' 'Yellow'
        try { Start-Game } catch {}
        Hold 8
    } else {
        Say 'Send a screenshot of this window to whoever gave you this file.' 'Yellow'
        Wait-Key
    }
}
exit $exitCode
