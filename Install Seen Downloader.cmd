@echo off
setlocal
title Install Seen's yt-dlp Downloader
set "SEEN_SETUP_FILE=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$text = [IO.File]::ReadAllText($env:SEEN_SETUP_FILE); & ([scriptblock]::Create(($text -split '(?m)^# POWERSHELL START\r?$', 2)[1]))"
set "setup_result=%errorlevel%"
if not "%setup_result%"=="0" (
    echo.
    echo Setup could not finish. Check the message above, then run this file again.
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

function Get-SetupFile {
    param([string]$Url, [string]$Destination, [hashtable]$Headers = @{})
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -Headers $Headers -TimeoutSec 300
            if ((Get-Item -LiteralPath $Destination).Length -eq 0) { throw 'The server returned an empty file.' }
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Host '  Download interrupted; retrying...' -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }
}

function Assert-SetupHash {
    param([string]$Path, [string]$Checksums, [string]$Name)
    $pattern = '(?im)^([a-f0-9]{64})\s+\*?' + [regex]::Escape($Name) + '\s*$'
    $match = [regex]::Match($Checksums, $pattern)
    if (-not $match.Success) { throw "No SHA256 checksum was published for $Name." }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $match.Groups[1].Value) {
        throw "Checksum mismatch for $Name. Run setup again to download a fresh copy."
    }
}

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
            } catch { Write-Warning "Could not restore $destination. Close the downloader and rerun setup." }
        }
        throw $originalError
    }
}

$stage = $null
$installLock = $null
try {
    Write-Host "`n  Seen's yt-dlp Downloader - Setup / Update`n" -ForegroundColor Cyan
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    if ($architecture -ne 'AMD64' -or [Environment]::OSVersion.Version.Major -lt 10) {
        throw 'This installer supports Windows 10/11 on Intel or AMD 64-bit PCs.'
    }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    Write-Host "Install location: $InstallDir"
    Write-Host 'Close the downloader before updating. Downloads and settings will be kept.'
    Write-Host 'Setup downloads the app, yt-dlp, Node.js LTS, FFmpeg, and gallery-dl. This may take a few minutes.'
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    try {
        $installLock = [IO.File]::Open((Join-Path $InstallDir '.setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { throw 'Another setup is running, or this install folder is not writable.' }
    $stage = Join-Path $InstallDir ('.setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null

    Write-Host "`n[1/6] Downloading the latest app from GitHub..."
    $headers = @{ 'User-Agent' = 'Seen-Downloader-Setup'; Accept = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = 'Bearer ' + $env:GITHUB_TOKEN }
    $repoApi = 'https://api.github.com/repos/MightBeSeen/yt-dlp-downlodersushi'
    try {
        Get-SetupFile "$repoApi/commits/main" (Join-Path $stage 'commit.json') $headers
    } catch {
        throw 'Cannot access the GitHub repository. Check your connection and repository visibility. Private repositories require a GITHUB_TOKEN environment variable with Contents read access.'
    }
    $commit = (Get-Content -LiteralPath (Join-Path $stage 'commit.json') -Raw | ConvertFrom-Json).sha
    if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'GitHub returned an invalid revision.' }
    $appFiles = @('smart-downloader.ps1', "Seen's yt-dlp Downloader.cmd", 'README.md', 'READ ME FIRST.txt')
    $headers.Accept = 'application/vnd.github.raw+json'
    foreach ($name in $appFiles) {
        $encodedName = [uri]::EscapeDataString($name)
        Get-SetupFile "$repoApi/contents/${encodedName}?ref=$commit" (Join-Path $stage $name) $headers
    }
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $stage 'smart-downloader.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'The downloaded app contains PowerShell syntax errors.' }

    Write-Host '[2/6] Downloading the latest stable yt-dlp...'
    $release = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download'
    Get-SetupFile "$release/yt-dlp.exe" (Join-Path $stage 'yt-dlp.exe')
    Get-SetupFile "$release/SHA2-256SUMS" (Join-Path $stage 'yt-checksums.txt')
    Assert-SetupHash (Join-Path $stage 'yt-dlp.exe') (Get-Content (Join-Path $stage 'yt-checksums.txt') -Raw) 'yt-dlp.exe'

    Write-Host '[3/6] Downloading the latest Node.js LTS...'
    Get-SetupFile 'https://nodejs.org/dist/index.json' (Join-Path $stage 'node-index.json')
    $node = (Get-Content (Join-Path $stage 'node-index.json') -Raw | ConvertFrom-Json) |
        Where-Object { $_.lts -and $_.files -contains 'win-x64-zip' } | Select-Object -First 1
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

    Write-Host '[4/6] Downloading FFmpeg (the largest download)...'
    $ffmpegUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    Get-SetupFile $ffmpegUrl (Join-Path $stage 'ffmpeg.zip')
    Get-SetupFile "$ffmpegUrl.sha256" (Join-Path $stage 'ffmpeg-checksum.txt')
    $ffmpegHash = (Get-Content (Join-Path $stage 'ffmpeg-checksum.txt') -Raw).Trim().Split(' ')[0]
    Assert-SetupHash (Join-Path $stage 'ffmpeg.zip') "$ffmpegHash  ffmpeg.zip" 'ffmpeg.zip'
    Expand-Archive -LiteralPath (Join-Path $stage 'ffmpeg.zip') -DestinationPath (Join-Path $stage 'ffmpeg')
    foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
        $matches = @(Get-ChildItem -LiteralPath (Join-Path $stage 'ffmpeg') -Filter $name -Recurse -File)
        if ($matches.Count -ne 1) { throw "The FFmpeg archive does not contain exactly one $name." }
        Copy-Item -LiteralPath $matches[0].FullName -Destination $stage
    }
    $license = Get-ChildItem -LiteralPath (Join-Path $stage 'ffmpeg') -Filter 'LICENSE' -Recurse -File | Select-Object -First 1
    if (-not $license) { throw 'The FFmpeg license is missing from the archive.' }
    Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $stage 'FFmpeg-LICENSE.txt')

    Write-Host '[5/6] Downloading gallery-dl (photos and social posts)...'
    # gallery-dl publishes no checksum file, so it is run-tested below rather than
    # hash-verified. Keep this pinned version in sync with Get-GalleryDlRelease in
    # smart-downloader.ps1.
    $gdlVersion = 'v1.32.13'
    Get-SetupFile "https://codeberg.org/mikf/gallery-dl/releases/download/$gdlVersion/gallery-dl.exe" (Join-Path $stage 'gallery-dl.exe')
    Set-Content -LiteralPath (Join-Path $stage 'GalleryDl-LICENSE.txt') -Value @(
        "gallery-dl $gdlVersion is distributed under the GNU General Public License v2.0.",
        'Source and license: https://codeberg.org/mikf/gallery-dl'
    ) -Encoding ASCII

    Write-Host '[6/6] Checking helpers and finishing setup...'
    foreach ($name in @('yt-dlp.exe', 'node.exe', 'ffmpeg.exe', 'ffprobe.exe', 'gallery-dl.exe')) {
        $versionArg = '--version'
        if ($name -like 'ff*') { $versionArg = '-version' }
        $version = & (Join-Path $stage $name) $versionArg 2>&1
        if ($LASTEXITCODE -ne 0) { throw "$name could not run on this PC." }
        Write-Host ('  ' + ($version | Select-Object -First 1))
    }
    $names = $appFiles + @('yt-dlp.exe', 'node.exe', 'ffmpeg.exe', 'ffprobe.exe', 'gallery-dl.exe', 'Node-LICENSE.txt', 'FFmpeg-LICENSE.txt', 'GalleryDl-LICENSE.txt', 'installed-version.txt')
    Set-Content -LiteralPath (Join-Path $stage 'installed-version.txt') -Value $commit -Encoding ASCII
    Install-SetupFiles $stage $InstallDir $names

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
        } catch { Write-Warning "Shortcut creation failed. Open the downloader from $InstallDir." }
    }
    Write-Host "`nReady! Installed GitHub revision $($commit.Substring(0, 7))." -ForegroundColor Green
    Write-Host "Your downloads: $InstallDir\Downloads"
    Write-Host 'Keep this installer. Double-click it again whenever you want to update the app and helpers.'
    if (-not $NoLaunch) {
        & (Join-Path $InstallDir "Seen's yt-dlp Downloader.cmd")
    }
} catch {
    Write-Host "`nSetup failed: $($_.Exception.Message)" -ForegroundColor Red
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
