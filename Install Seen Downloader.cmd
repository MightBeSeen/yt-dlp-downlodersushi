@echo off
rem ============================================================
rem  Seen's yt-dlp Downloader - one-time setup / updater
rem  Double-click on a fresh PC. Downloads the app and every
rem  helper it needs (yt-dlp, Node.js, FFmpeg, gallery-dl),
rem  makes shortcuts, and launches it. No admin required.
rem  This .cmd carries its own PowerShell body after the
rem  "# POWERSHELL START" marker; cmd.exe never reads that far.
rem ============================================================
setlocal
title Install Seen's yt-dlp Downloader
set "SEEN_SETUP_FILE=%~f0"

rem Prefer PowerShell 7 (pwsh) like the app's own launcher; fall
rem back to the Windows PowerShell that ships with Windows 10/11.
where pwsh.exe >nul 2>&1
if errorlevel 1 goto windows_powershell
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$body = [IO.File]::ReadAllText($env:SEEN_SETUP_FILE); & ([scriptblock]::Create(($body -split '(?m)^# POWERSHELL START\r?$', 2)[1]))"
set "setup_result=%errorlevel%"
goto finished

:windows_powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$body = [IO.File]::ReadAllText($env:SEEN_SETUP_FILE); & ([scriptblock]::Create(($body -split '(?m)^# POWERSHELL START\r?$', 2)[1]))"
set "setup_result=%errorlevel%"

:finished
if not "%setup_result%"=="0" (
    echo.
    echo Setup could not finish. Read the message above, then run this file again.
    pause
)
exit /b %setup_result%
# POWERSHELL START
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Seen Downloader'),
    [switch]$NoLaunch,
    [switch]$NoShortcuts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Monochrome plain-text UI. USE_COLOR is a future switch; unused for now.
$script:UseColor = $false
$script:TotalStages = 6

# --- UI primitives ---------------------------------------------------------
function New-Rule { param([int]$Width = 60, [char]$Char = '=') return ([string]$Char * $Width) }

function Write-Banner {
    Write-Host (New-Rule)
    Write-Host '    (=^.^=)    Seen''s yt-dlp Downloader'
    Write-Host '    /  >  <    Fresh install & updater'
    Write-Host (New-Rule)
}

# Status line. Marker: '*' info/running, 'ok' success, '!' warning, 'x' error.
function Write-Step {
    param([string]$Marker, [string]$Message)
    Write-Host ('  [{0}] {1}' -f $Marker, $Message)
}

# Grouped output framed by rules, with an optional underlined title.
function Write-Box {
    param([string]$Title, [string[]]$Lines)
    Write-Host (New-Rule)
    if ($Title) {
        Write-Host ('  ' + $Title)
        Write-Host ('  ' + (New-Rule -Char '-'))
    }
    foreach ($line in $Lines) { Write-Host ('  ' + $line) }
    Write-Host (New-Rule)
}

# Single \r-overwritten progress bar across the setup stages. Unicode block
# glyphs with an ASCII fallback when the console encoding can't encode them.
function Write-Progress-Bar {
    param([int]$Stage, [string]$Label, [int]$Width = 24)
    $filled = [char]0x2588
    $empty  = [char]0x2591
    try {
        $enc = [Console]::OutputEncoding
        if ($enc.GetString($enc.GetBytes([string]$filled)) -ne [string]$filled) { throw 'lossy' }
    } catch { $filled = '#'; $empty = '-' }
    $done = [int][Math]::Round(($Stage / $script:TotalStages) * $Width)
    if ($done -gt $Width) { $done = $Width }
    $bar = ([string]$filled * $done) + ([string]$empty * ($Width - $done))
    $pct = [int][Math]::Round(($Stage / $script:TotalStages) * 100)
    Write-Host ("`r  [{0}] {1,3}%  {2}" -f $bar, $pct, $Label) -NoNewline
    if ($Stage -ge $script:TotalStages) { Write-Host '' }
}

# Closing face: happy on success, low-key on failure. Used once per run.
function Write-Face { param([switch]$Ok) if ($Ok) { Write-Host '  \(^_^)/' } else { Write-Host '  (._.)' } }

# --- Download / install workers -------------------------------------------
# Download with three attempts; treats an empty file as a failed download.
function Get-SetupFile {
    param([string]$Url, [string]$Destination, [hashtable]$Headers = @{})
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -Headers $Headers -TimeoutSec 300
            if ((Get-Item -LiteralPath $Destination).Length -eq 0) { throw 'The server returned an empty file.' }
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Step '!' 'Download interrupted; retrying...'
            Start-Sleep -Seconds 2
        }
    }
}

# Verify a file against a published SHA256SUMS-style list (optional '*' prefix).
function Assert-SetupHash {
    param([string]$Path, [string]$Checksums, [string]$Name)
    $pattern = '(?im)^([a-f0-9]{64})\s+\*?' + [regex]::Escape($Name) + '\s*$'
    $match = [regex]::Match($Checksums, $pattern)
    if (-not $match.Success) { throw "No SHA256 checksum was published for $Name." }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $match.Groups[1].Value) {
        throw "Checksum mismatch for $Name. Run setup again to download a fresh copy."
    }
}

# Copy a staged set into the target atomically: back up what exists, and on any
# failure restore originals and remove partial additions so a half-written
# install can never be left behind.
function Install-SetupFiles {
    param([string]$Stage, [string]$Target, [string[]]$Names)
    $backup = Join-Path $Stage 'backup'
    New-Item -ItemType Directory -Path $backup | Out-Null
    $changed = @()
    try {
        foreach ($name in $Names) {
            $destination = Join-Path $Target $name
            $existed = Test-Path -LiteralPath $destination
            if ($existed) { Copy-Item -LiteralPath $destination -Destination (Join-Path $backup $name) }
            $changed += [pscustomobject]@{ Name = $name; Existed = $existed }
            Copy-Item -LiteralPath (Join-Path $Stage $name) -Destination $destination -Force
        }
    } catch {
        $originalError = $_
        foreach ($item in $changed) {
            $destination = Join-Path $Target $item.Name
            try {
                if ($item.Existed) {
                    Copy-Item -LiteralPath (Join-Path $backup $item.Name) -Destination $destination -Force
                } elseif (Test-Path -LiteralPath $destination) {
                    Remove-Item -LiteralPath $destination -Force
                }
            } catch { Write-Step '!' "Could not restore $destination. Close the downloader and rerun setup." }
        }
        throw $originalError
    }
}

# --- Main flow -------------------------------------------------------------
$stage = $null
$installLock = $null
try {
    Write-Banner
    Write-Host ''

    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    if ($architecture -ne 'AMD64' -or [Environment]::OSVersion.Version.Major -lt 10) {
        throw 'This installer supports Windows 10/11 on Intel or AMD 64-bit PCs.'
    }

    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    Write-Box 'Setup plan' @(
        "Install folder : $InstallDir",
        'Downloading    : app + yt-dlp + Node.js LTS + FFmpeg + gallery-dl',
        'Time / size    : a few minutes, ~150 MB (FFmpeg is the big one)',
        'Admin needed   : no. Existing Downloads and settings are kept.'
    )
    Write-Host ''

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    try {
        $installLock = [IO.File]::Open((Join-Path $InstallDir '.setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { throw 'Another setup is running, or this install folder is not writable.' }
    $stage = Join-Path $InstallDir ('.setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null

    # [1/6] App source, pinned to one GitHub commit so every file matches.
    Write-Step '*' 'Fetching the latest app from GitHub...'
    $repoOwnerName = 'MightBeSeen/yt-dlp-downlodersushi'
    $repoBranch    = 'main'
    $apiHeaders = @{ 'User-Agent' = 'Seen-Downloader-Setup'; Accept = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $apiHeaders.Authorization = 'Bearer ' + $env:GITHUB_TOKEN }
    try {
        Get-SetupFile ('https://api.github.com/repos/{0}/commits/{1}' -f $repoOwnerName, $repoBranch) (Join-Path $stage 'commit.json') $apiHeaders
    } catch {
        throw 'Cannot reach the GitHub repository. Check your internet connection and try again. Private repositories need a GITHUB_TOKEN environment variable with Contents read access.'
    }
    $commit = (Get-Content -LiteralPath (Join-Path $stage 'commit.json') -Raw | ConvertFrom-Json).sha
    if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'GitHub returned an invalid revision.' }
    $appFiles = @('smart-downloader.ps1', "Seen's yt-dlp Downloader.cmd", 'README.md', 'READ ME FIRST.txt')
    foreach ($name in $appFiles) {
        $encoded = ($name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        Get-SetupFile ('https://raw.githubusercontent.com/{0}/{1}/{2}' -f $repoOwnerName, $commit, $encoded) (Join-Path $stage $name)
    }
    $parseTokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $stage 'smart-downloader.ps1'), [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'The downloaded app contains PowerShell syntax errors.' }
    Write-Step 'ok' ('App revision {0} fetched.' -f $commit.Substring(0, 7))
    Write-Progress-Bar 1 'app'

    # [2/6] yt-dlp - the core downloader, SHA256-verified.
    Write-Step '*' 'Downloading the latest yt-dlp...'
    $ytRelease = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download'
    Get-SetupFile "$ytRelease/yt-dlp.exe" (Join-Path $stage 'yt-dlp.exe')
    Get-SetupFile "$ytRelease/SHA2-256SUMS" (Join-Path $stage 'yt-checksums.txt')
    Assert-SetupHash (Join-Path $stage 'yt-dlp.exe') (Get-Content (Join-Path $stage 'yt-checksums.txt') -Raw) 'yt-dlp.exe'
    Write-Step 'ok' 'yt-dlp verified.'
    Write-Progress-Bar 2 'yt-dlp'

    # [3/6] Node.js LTS (portable) - needed for the YouTube path.
    Write-Step '*' 'Downloading the latest Node.js LTS...'
    Get-SetupFile 'https://nodejs.org/dist/index.json' (Join-Path $stage 'node-index.json')
    $node = (Get-Content -LiteralPath (Join-Path $stage 'node-index.json') -Raw | ConvertFrom-Json) |
        Where-Object { $_.lts -and ($_.files -contains 'win-x64-zip') } | Select-Object -First 1
    if (-not $node -or $node.version -notmatch '^v\d+\.\d+\.\d+$') { throw 'No supported Node.js LTS release was found.' }
    $nodeName = 'node-' + $node.version + '-win-x64.zip'
    $nodeBase = 'https://nodejs.org/dist/' + $node.version
    Get-SetupFile "$nodeBase/$nodeName" (Join-Path $stage 'node.zip')
    Get-SetupFile "$nodeBase/SHASUMS256.txt" (Join-Path $stage 'node-checksums.txt')
    Assert-SetupHash (Join-Path $stage 'node.zip') (Get-Content (Join-Path $stage 'node-checksums.txt') -Raw) $nodeName
    Expand-Archive -LiteralPath (Join-Path $stage 'node.zip') -DestinationPath (Join-Path $stage 'node')
    $nodeRoot = Join-Path (Join-Path $stage 'node') ($nodeName -replace '\.zip$', '')
    Copy-Item -LiteralPath (Join-Path $nodeRoot 'node.exe') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $nodeRoot 'LICENSE') -Destination (Join-Path $stage 'Node-LICENSE.txt')
    Write-Step 'ok' ('Node.js {0} verified.' -f $node.version)
    Write-Progress-Bar 3 'node.js'

    # [4/6] FFmpeg + ffprobe - audio conversion and best-quality merges.
    Write-Step '*' 'Downloading FFmpeg (the largest download)...'
    $ffmpegUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    Get-SetupFile $ffmpegUrl (Join-Path $stage 'ffmpeg.zip')
    Get-SetupFile "$ffmpegUrl.sha256" (Join-Path $stage 'ffmpeg-checksum.txt')
    $ffmpegHash = (Get-Content (Join-Path $stage 'ffmpeg-checksum.txt') -Raw).Trim().Split(' ')[0]
    Assert-SetupHash (Join-Path $stage 'ffmpeg.zip') "$ffmpegHash  ffmpeg.zip" 'ffmpeg.zip'
    Expand-Archive -LiteralPath (Join-Path $stage 'ffmpeg.zip') -DestinationPath (Join-Path $stage 'ffmpeg')
    foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
        $found = @(Get-ChildItem -LiteralPath (Join-Path $stage 'ffmpeg') -Filter $name -Recurse -File)
        if ($found.Count -ne 1) { throw "The FFmpeg archive does not contain exactly one $name." }
        Copy-Item -LiteralPath $found[0].FullName -Destination $stage
    }
    $ffmpegLicense = Get-ChildItem -LiteralPath (Join-Path $stage 'ffmpeg') -Filter 'LICENSE' -Recurse -File | Select-Object -First 1
    if (-not $ffmpegLicense) { throw 'The FFmpeg license is missing from the archive.' }
    Copy-Item -LiteralPath $ffmpegLicense.FullName -Destination (Join-Path $stage 'FFmpeg-LICENSE.txt')
    Write-Step 'ok' 'FFmpeg verified.'
    Write-Progress-Bar 4 'ffmpeg'

    # [5/6] gallery-dl - Instagram / TikTok / X / Facebook photos and posts.
    # Codeberg publishes no checksum file, so this pinned build is run-tested in
    # stage 6 instead. Keep this in sync with Get-GalleryDlRelease in
    # smart-downloader.ps1 (currently 1.32.13).
    Write-Step '*' 'Downloading gallery-dl (photos and social posts)...'
    $gdlVersion = 'v1.32.13'
    Get-SetupFile "https://codeberg.org/mikf/gallery-dl/releases/download/$gdlVersion/gallery-dl.exe" (Join-Path $stage 'gallery-dl.exe')
    Set-Content -LiteralPath (Join-Path $stage 'GalleryDl-LICENSE.txt') -Value @(
        "gallery-dl $gdlVersion is distributed under the GNU General Public License v2.0.",
        'Source and license: https://codeberg.org/mikf/gallery-dl'
    ) -Encoding ASCII
    Write-Step 'ok' 'gallery-dl downloaded.'
    Write-Progress-Bar 5 'gallery-dl'

    # [6/6] Prove each helper runs, then install everything atomically.
    Write-Step '*' 'Testing helpers and finishing setup...'
    foreach ($name in @('yt-dlp.exe', 'node.exe', 'ffmpeg.exe', 'ffprobe.exe', 'gallery-dl.exe')) {
        $versionArg = '--version'
        if ($name -like 'ff*') { $versionArg = '-version' }
        $reported = & (Join-Path $stage $name) $versionArg 2>&1
        if ($LASTEXITCODE -ne 0) { throw "$name could not run on this PC." }
        Write-Step 'ok' ('{0}: {1}' -f $name, ($reported | Select-Object -First 1))
    }
    $names = $appFiles + @('yt-dlp.exe', 'node.exe', 'ffmpeg.exe', 'ffprobe.exe', 'gallery-dl.exe', 'Node-LICENSE.txt', 'FFmpeg-LICENSE.txt', 'GalleryDl-LICENSE.txt', 'installed-version.txt')
    Set-Content -LiteralPath (Join-Path $stage 'installed-version.txt') -Value $commit -Encoding ASCII
    Install-SetupFiles $stage $InstallDir $names
    Write-Progress-Bar 6 'done'

    if (-not $NoShortcuts) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
                if (-not $folder) { continue }
                $shortcut = $shell.CreateShortcut((Join-Path $folder "Seen's yt-dlp Downloader.lnk"))
                $shortcut.TargetPath = Join-Path $InstallDir "Seen's yt-dlp Downloader.cmd"
                $shortcut.WorkingDirectory = $InstallDir
                $shortcut.Save()
            }
        } catch { Write-Step '!' "Shortcut creation failed. Open the downloader from $InstallDir." }
    }

    Write-Host ''
    Write-Box 'All set' @(
        "Installed GitHub revision $($commit.Substring(0, 7)).",
        "Your downloads: $InstallDir\Downloads",
        'Keep this installer - run it again anytime to update the app and helpers.'
    )
    Write-Face -Ok

    if (-not $NoLaunch) {
        & (Join-Path $InstallDir "Seen's yt-dlp Downloader.cmd")
    }
} catch {
    Write-Host ''
    Write-Step 'x' ('Setup failed: {0}' -f $_.Exception.Message)
    Write-Face
    exit 1
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        # Only remove the unique staging folder created inside this installation.
        if ((Split-Path -Parent $stage) -eq $InstallDir -and (Split-Path -Leaf $stage) -match '^\.setup-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($installLock) { $installLock.Dispose() }
}
