@echo off
rem ============================================================
rem  Yt-dlp Downloader - one-time setup / updater
rem  Double-click on a fresh PC. Downloads the app and every
rem  helper it needs (yt-dlp, Node.js, FFmpeg, gallery-dl),
rem  makes shortcuts, and launches it. No admin required.
rem  This .cmd carries its own PowerShell body after the
rem  "# POWERSHELL START" marker; cmd.exe never reads that far.
rem ============================================================
setlocal
title Install Yt-dlp Downloader
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
    [string]$InstallDir,
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [ValidatePattern('^[a-f0-9]{40}$')][string]$AppRevision
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Reuse existing installations; explicit paths always take precedence.
if (-not $InstallDir) {
    $current = Join-Path $env:LOCALAPPDATA 'Yt-dlp Downloader'
    $legacy = Join-Path $env:LOCALAPPDATA 'Seen Downloader'
    if (Test-Path -LiteralPath (Join-Path $current 'smart-downloader.ps1')) { $InstallDir = $current }
    elseif (Test-Path -LiteralPath (Join-Path $legacy 'smart-downloader.ps1')) { $InstallDir = $legacy }
    else { $InstallDir = $current }
}

# Plain-text setup UI works in both Windows PowerShell and PowerShell 7.
$script:TotalStages = 6

# BEGIN GENERATED UPDATE CORE - edit lib/update-core.ps1, then run scripts/Sync-UpdateCore.ps1
# Shared installation/update workers. Embedded in both deliverables for legacy upgrades.

function Write-Step {
    param([string]$Marker, [string]$Message)
    Write-Host ('  [{0}] {1}' -f $Marker, $Message)
}

function Invoke-SetupTransfer {
    param([string]$Url, [string]$Destination, [hashtable]$Headers = @{},
        [int]$IdleTimeoutSec = 45, [int]$TimeoutSec = 1800)
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $Url)
    $cancel = New-Object Threading.CancellationTokenSource
    $response = $null; $inputStream = $null; $outputStream = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $idle = [Diagnostics.Stopwatch]::StartNew()
    $display = [Diagnostics.Stopwatch]::StartNew()
    [long]$received = 0
    [long]$total = 0
    $label = Split-Path -Leaf $Destination
    $wait = {
        param($Task)
        do {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSec) { throw "Download exceeded $TimeoutSec seconds." }
            if ($idle.Elapsed.TotalSeconds -ge $IdleTimeoutSec) { throw "No download data received for $IdleTimeoutSec seconds." }
            if ($display.Elapsed.TotalSeconds -ge 2) {
                $size = '{0:N1} MB' -f ($received / 1MB)
                if ($total -gt 0) { $size += ' / {0:N1} MB ({1:N0}%)' -f ($total / 1MB), (100 * $received / $total) }
                Write-Step '*' ('{0}: {1}, {2:N0}s elapsed' -f $label, $size, $clock.Elapsed.TotalSeconds)
                $display.Restart()
            }
            if ($Task.IsCompleted) { break }
            [void]$Task.Wait(100)
        } while ($true)
    }
    try {
        foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key]) }
        if (-not $request.Headers.UserAgent.ToString()) { [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'Seen-Downloader-Setup') }
        Write-Step '*' ("Connecting to {0} for {1}..." -f ([uri]$Url).Host, $label)
        $task = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token)
        & $wait $task
        $response = $task.GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        if ($null -ne $response.Content.Headers.ContentLength) { $total = $response.Content.Headers.ContentLength }
        $task = $response.Content.ReadAsStreamAsync()
        & $wait $task
        $inputStream = $task.GetAwaiter().GetResult()
        $outputStream = [IO.File]::Create($Destination)
        $buffer = New-Object byte[] 65536
        while ($true) {
            $task = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token)
            & $wait $task
            $count = $task.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            $outputStream.Write($buffer, 0, $count)
            $received += $count
            $idle.Restart()
        }
        if ($received -eq 0) { throw 'The server returned an empty file.' }
        if ($total -gt 0 -and $received -ne $total) { throw 'The download ended before the complete file arrived.' }
        Write-Step 'ok' ('{0}: {1:N1} MB downloaded.' -f $label, ($received / 1MB))
    } finally {
        $cancel.Cancel()
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
        $cancel.Dispose()
    }
}

function Get-SetupFile {
    param([string]$Url, [string]$Destination, [hashtable]$Headers = @{},
        [int]$Attempts = 3, [int]$IdleTimeoutSec = 45, [int]$TimeoutSec = 1800)
    $partial = $Destination + '.part'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Invoke-SetupTransfer $Url $partial $Headers -IdleTimeoutSec $IdleTimeoutSec -TimeoutSec $TimeoutSec
            if ((Get-Item -LiteralPath $partial).Length -eq 0) { throw 'The server returned an empty file.' }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        } catch {
            if ($attempt -eq $Attempts) { throw "Could not download $([IO.Path]::GetFileName($Destination)) from $(([uri]$Url).Host): $($_.Exception.Message)" }
            Write-Step '!' ("Download attempt $attempt/$Attempts failed: $($_.Exception.Message) Retrying...")
            Start-Sleep -Seconds 2
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    }
}

function Get-SetupFfmpeg {
    param([string]$Stage, [string]$Target = '')
    $zip = Join-Path $Stage 'ffmpeg.zip'
    try {
        Write-Step '*' 'Trying FFmpeg publisher on GitHub...'
        $metadata = Join-Path $Stage 'ffmpeg-release.json'
        Get-SetupFile 'https://api.github.com/repos/GyanD/codexffmpeg/releases/latest' $metadata -Attempts 1
        $release = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
        $assets = @($release.assets | Where-Object { $_.name -match '^ffmpeg-[0-9.]+-essentials_build\.zip$' })
        if ($assets.Count -ne 1) { throw 'No unique FFmpeg essentials ZIP was published.' }
        $asset = $assets[0]
        if ($asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'The FFmpeg release has no SHA256 digest.' }
        $hash = $Matches[1]
        if ($Target -and (Copy-SetupCachedGroup $Target $Stage 'ffmpeg' $hash @('ffmpeg.exe', 'ffprobe.exe', 'FFmpeg-LICENSE.txt'))) {
            Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
            return $true
        }
        if ($asset.browser_download_url -notlike 'https://github.com/GyanD/codexffmpeg/releases/download/*') { throw 'Unexpected FFmpeg release URL.' }
        Get-SetupFile $asset.browser_download_url $zip -Attempts 1
        Assert-SetupHash $zip "$hash  ffmpeg.zip" 'ffmpeg.zip'
        Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
        return $false
    } catch {
        Write-Step '!' ("FFmpeg GitHub source failed: $($_.Exception.Message)")
        Write-Step '*' 'Switching to the FFmpeg publisher at gyan.dev...'
    }
    $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    Get-SetupFile "$url.sha256" (Join-Path $Stage 'ffmpeg-checksum.txt') -Attempts 1
    $hash = ((Get-Content -LiteralPath (Join-Path $Stage 'ffmpeg-checksum.txt') -Raw).Trim() -split '\s+')[0]
    if ($hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid FFmpeg checksum from gyan.dev.' }
    if ($Target -and (Copy-SetupCachedGroup $Target $Stage 'ffmpeg' $hash @('ffmpeg.exe', 'ffprobe.exe', 'FFmpeg-LICENSE.txt'))) {
        Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
        return $true
    }
    Get-SetupFile $url $zip -Attempts 1
    Assert-SetupHash $zip "$hash  ffmpeg.zip" 'ffmpeg.zip'
    Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
    return $false
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

function Test-SetupHelper {
    param([string]$Path, [string]$Arguments = '--version', [int]$TimeoutSec = 30)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Path
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) { throw "$(Split-Path -Leaf $Path) did not respond within $TimeoutSec seconds. Close the app and rerun setup." }
        if ($process.ExitCode -ne 0) { throw "$(Split-Path -Leaf $Path) could not run on this PC: $($stderr.GetAwaiter().GetResult())" }
        $reported = $stdout.GetAwaiter().GetResult()
        if (-not $reported.Trim()) { throw "$(Split-Path -Leaf $Path) returned no version information." }
        Write-Step 'ok' ('{0}: {1}' -f (Split-Path -Leaf $Path), ($reported -split '\r?\n')[0])
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
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
            } catch { Write-Step '!' "Could not restore $destination. Close the downloader and rerun setup." }
        }
        throw $originalError
    }
}

# Reuse only the exact published package already installed, with every local file
# still matching the recorded hash. Executables are run-tested again before commit.
function Copy-SetupCachedGroup {
    param([string]$Target, [string]$Stage, [string]$Group, [string]$Key, [string[]]$Files)
    try {
        $record = Get-Content -LiteralPath (Join-Path $Target 'installed-helpers.json') -Raw | ConvertFrom-Json
        $entry = $record.PSObject.Properties[$Group].Value
        if ($entry.Key -ne $Key) { return $false }
        foreach ($name in $Files) {
            $expected = $entry.Hashes.PSObject.Properties[$name].Value
            if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $Target $name) -Algorithm SHA256).Hash -ne $expected) { return $false }
        }
        foreach ($name in $Files) { Copy-Item -LiteralPath (Join-Path $Target $name) -Destination (Join-Path $Stage $name) -Force }
        Write-Step 'ok' "$Group is current; reusing verified installed files."
        return $true
    } catch { return $false }
}

function New-SetupHelperRecord {
    param([string]$Stage, [string]$Key, [string[]]$Files)
    $hashes = [ordered]@{}
    foreach ($name in $Files) { $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $Stage $name) -Algorithm SHA256).Hash }
    return [pscustomobject]@{ Key = $Key; Hashes = $hashes }
}

function Get-SetupGalleryRelease {
    # Digest pinned from the HTTPS-distributed binary, run-tested on Windows.
    return [pscustomobject]@{
        Version = '1.32.13'
        Url = 'https://codeberg.org/mikf/gallery-dl/releases/download/v1.32.13/gallery-dl.exe'
        Sha256 = 'f9a810132003701af4115a0ee07e84c3f9dd3e59d91bd4a82949f32e6c4318e7'
    }
}
# END GENERATED UPDATE CORE

# --- UI primitives ---------------------------------------------------------
function New-Rule { param([int]$Width = 60, [char]$Char = '=') return ([string]$Char * $Width) }

function Write-Banner {
    Write-Host (New-Rule)
    Write-Host '    (=^.^=)    Yt-dlp Downloader'
    Write-Host '                 by MaybeSeen' -ForegroundColor DarkGray
    Write-Host '    /  >  <    Fresh install & updater'
    Write-Host (New-Rule)
}

# Status line. Marker: '*' info/running, 'ok' success, '!' warning, 'x' error.


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

# Completed setup stages, distinct from the current file's byte progress. Unicode block
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
    Write-Host ('  [{0}] Step {1}/{2} complete: {3}' -f $bar, $Stage, $script:TotalStages, $Label)
}

# Closing face: happy on success, low-key on failure. Used once per run.
function Write-Face { param([switch]$Ok) if ($Ok) { Write-Host '  \(^_^)/' } else { Write-Host '  (._.)' } }

# --- Main flow -------------------------------------------------------------
$stage = $null
$installLock = $null
$transcriptStarted = $false
$logPath = $null
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
        'Time / size    : several minutes; allow ~250 MB of downloads.',
        'Progress       : downloaded MB shown every 2 seconds; slow connections take longer.',
        'Admin needed   : no. Existing Downloads and settings are kept.'
    )
    Write-Host ''

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    try {
        $installLock = [IO.File]::Open((Join-Path $InstallDir '.setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { throw 'Another setup is running, or this install folder is not writable.' }
    $logFolder = Join-Path $InstallDir 'logs'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    $logPath = Join-Path $logFolder ('setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID + '.log')
    try {
        Start-Transcript -LiteralPath $logPath -Force | Out-Null
        $transcriptStarted = $true
        Write-Step '*' "Setup log: $logPath"
    } catch { Write-Step '!' 'Could not save a setup log; error details will still appear here.' }
    $stage = Join-Path $InstallDir ('.setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null

    # [1/6] App source, pinned to one GitHub commit so every file matches.
    Write-Step '*' 'Fetching the latest app from GitHub...'
    $repoOwnerName = 'MightBeSeen/yt-dlp-downlodersushi'
    $repoBranch    = 'stable'
    $apiHeaders = @{ 'User-Agent' = 'Seen-Downloader-Setup'; Accept = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $apiHeaders.Authorization = 'Bearer ' + $env:GITHUB_TOKEN }
    if (-not $AppRevision) { try {
        Get-SetupFile ('https://api.github.com/repos/{0}/commits/{1}' -f $repoOwnerName, $repoBranch) (Join-Path $stage 'commit.json') $apiHeaders
    } catch {
        throw 'Cannot reach the GitHub repository. Check your internet connection and try again. Private repositories need a GITHUB_TOKEN environment variable with Contents read access.'
    }
    $commit = (Get-Content -LiteralPath (Join-Path $stage 'commit.json') -Raw | ConvertFrom-Json).sha
    } else { $commit = $AppRevision }
    if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'GitHub returned an invalid revision.' }
    $appFiles = @('smart-downloader.ps1', "Yt-dlp Downloader.cmd", 'README.md', 'READ ME FIRST.txt', 'Install Yt-dlp Downloader.cmd', "Seen's yt-dlp Downloader.cmd", 'Install Seen Downloader.cmd')
    $helperRecords = [ordered]@{}
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
    Write-Step '*' 'Checking the latest yt-dlp...'
    $ytRelease = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download'
    Get-SetupFile "$ytRelease/SHA2-256SUMS" (Join-Path $stage 'yt-checksums.txt')
    $ytSums = Get-Content (Join-Path $stage 'yt-checksums.txt') -Raw
    $ytCurrent = $false
    try {
        Assert-SetupHash (Join-Path $InstallDir 'yt-dlp.exe') $ytSums 'yt-dlp.exe'
        Copy-Item -LiteralPath (Join-Path $InstallDir 'yt-dlp.exe') -Destination $stage
        $ytCurrent = $true
        Write-Step 'ok' 'yt-dlp is current; reusing verified installed file.'
    } catch { }
    if (-not $ytCurrent) { Get-SetupFile "$ytRelease/yt-dlp.exe" (Join-Path $stage 'yt-dlp.exe') }
    Assert-SetupHash (Join-Path $stage 'yt-dlp.exe') (Get-Content (Join-Path $stage 'yt-checksums.txt') -Raw) 'yt-dlp.exe'
    Write-Step 'ok' 'yt-dlp verified.'
    Write-Progress-Bar 2 'yt-dlp'

    # [3/6] Node.js LTS (portable) - needed for the YouTube path.
    Write-Step '*' 'Checking the latest Node.js LTS...'
    Get-SetupFile 'https://nodejs.org/dist/index.json' (Join-Path $stage 'node-index.json')
    $node = (Get-Content -LiteralPath (Join-Path $stage 'node-index.json') -Raw | ConvertFrom-Json) |
        Where-Object { $_.lts -and ($_.files -contains 'win-x64-zip') } | Select-Object -First 1
    if (-not $node -or $node.version -notmatch '^v\d+\.\d+\.\d+$') { throw 'No supported Node.js LTS release was found.' }
    $nodeName = 'node-' + $node.version + '-win-x64.zip'
    $nodeBase = 'https://nodejs.org/dist/' + $node.version
    if (-not (Copy-SetupCachedGroup $InstallDir $stage 'node' $node.version @('node.exe', 'Node-LICENSE.txt'))) {
    Get-SetupFile "$nodeBase/$nodeName" (Join-Path $stage 'node.zip')
    Get-SetupFile "$nodeBase/SHASUMS256.txt" (Join-Path $stage 'node-checksums.txt')
    Assert-SetupHash (Join-Path $stage 'node.zip') (Get-Content (Join-Path $stage 'node-checksums.txt') -Raw) $nodeName
    Write-Step '*' 'Unpacking Node.js...'
    Expand-Archive -LiteralPath (Join-Path $stage 'node.zip') -DestinationPath (Join-Path $stage 'node')
    $nodeRoot = Join-Path (Join-Path $stage 'node') ($nodeName -replace '\.zip$', '')
    Copy-Item -LiteralPath (Join-Path $nodeRoot 'node.exe') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $nodeRoot 'LICENSE') -Destination (Join-Path $stage 'Node-LICENSE.txt')
    }
    $helperRecords.node = New-SetupHelperRecord $stage $node.version @('node.exe', 'Node-LICENSE.txt')
    Write-Step 'ok' ('Node.js {0} verified.' -f $node.version)
    Write-Progress-Bar 3 'node.js'

    # [4/6] FFmpeg + ffprobe - audio conversion and best-quality merges.
    Write-Step '*' 'Checking FFmpeg (the largest download when needed)...'
    if (-not (Get-SetupFfmpeg $stage $InstallDir)) {
    Write-Step '*' 'Unpacking FFmpeg (this can take a minute)...'
    Expand-Archive -LiteralPath (Join-Path $stage 'ffmpeg.zip') -DestinationPath (Join-Path $stage 'ffmpeg')
    foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
        $found = @(Get-ChildItem -LiteralPath (Join-Path $stage 'ffmpeg') -Filter $name -Recurse -File)
        if ($found.Count -ne 1) { throw "The FFmpeg archive does not contain exactly one $name." }
        Copy-Item -LiteralPath $found[0].FullName -Destination $stage
    }
    $ffmpegLicense = Get-ChildItem -LiteralPath (Join-Path $stage 'ffmpeg') -Filter 'LICENSE' -Recurse -File | Select-Object -First 1
    if (-not $ffmpegLicense) { throw 'The FFmpeg license is missing from the archive.' }
    Copy-Item -LiteralPath $ffmpegLicense.FullName -Destination (Join-Path $stage 'FFmpeg-LICENSE.txt')
    }
    $helperRecords.ffmpeg = New-SetupHelperRecord $stage (Get-Content (Join-Path $stage 'ffmpeg-key.txt') -Raw).Trim() @('ffmpeg.exe', 'ffprobe.exe', 'FFmpeg-LICENSE.txt')
    Write-Step 'ok' 'FFmpeg verified.'
    Write-Progress-Bar 4 'ffmpeg'

    # [5/6] gallery-dl - Instagram / TikTok / X / Facebook photos and posts.
    # The shared core pins the tested binary's version and SHA256.
    Write-Step '*' 'Checking gallery-dl (photos and social posts)...'
    $gdl = Get-SetupGalleryRelease
    $gdlVersion = 'v' + $gdl.Version
    $gdlCurrent = $false
    try {
        Assert-SetupHash (Join-Path $InstallDir 'gallery-dl.exe') "$($gdl.Sha256)  gallery-dl.exe" 'gallery-dl.exe'
        Copy-Item -LiteralPath (Join-Path $InstallDir 'gallery-dl.exe') -Destination $stage
        $gdlCurrent = $true
        Write-Step 'ok' 'gallery-dl is current; reusing verified installed file.'
    } catch { }
    if (-not $gdlCurrent) { Get-SetupFile $gdl.Url (Join-Path $stage 'gallery-dl.exe') }
    Assert-SetupHash (Join-Path $stage 'gallery-dl.exe') "$($gdl.Sha256)  gallery-dl.exe" 'gallery-dl.exe'
    Set-Content -LiteralPath (Join-Path $stage 'GalleryDl-LICENSE.txt') -Value @(
        "gallery-dl $gdlVersion is distributed under the GNU General Public License v2.0.",
        'Source and license: https://codeberg.org/mikf/gallery-dl'
    ) -Encoding ASCII
    Write-Step 'ok' 'gallery-dl verified.'
    Write-Progress-Bar 5 'gallery-dl'

    # [6/6] Prove each helper runs, then install everything atomically.
    Write-Step '*' 'Testing helpers and finishing setup...'
    foreach ($name in @('yt-dlp.exe', 'node.exe', 'ffmpeg.exe', 'ffprobe.exe', 'gallery-dl.exe')) {
        $versionArg = '--version'
        if ($name -like 'ff*') { $versionArg = '-version' }
        Test-SetupHelper (Join-Path $stage $name) $versionArg
    }
    $names = $appFiles + @('yt-dlp.exe', 'node.exe', 'ffmpeg.exe', 'ffprobe.exe', 'gallery-dl.exe', 'Node-LICENSE.txt', 'FFmpeg-LICENSE.txt', 'GalleryDl-LICENSE.txt', 'installed-version.txt', 'installed-helpers.json')
    $helperRecords | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'installed-helpers.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $stage 'installed-version.txt') -Value $commit -Encoding ASCII
    Install-SetupFiles $stage $InstallDir $names
    Write-Progress-Bar 6 'done'

    if (-not $NoShortcuts) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
                if (-not $folder) { continue }
                $shortcut = $shell.CreateShortcut((Join-Path $folder "Yt-dlp Downloader.lnk"))
                $shortcut.TargetPath = Join-Path $InstallDir "Yt-dlp Downloader.cmd"
                $shortcut.WorkingDirectory = $InstallDir
                $shortcut.Save()
                $oldShortcutPath = Join-Path $folder "Seen's yt-dlp Downloader.lnk"
                if (Test-Path -LiteralPath $oldShortcutPath) {
                    $oldShortcut = $shell.CreateShortcut($oldShortcutPath)
                    if ($oldShortcut.TargetPath -in @((Join-Path $InstallDir "Seen's yt-dlp Downloader.cmd"), (Join-Path $InstallDir 'Yt-dlp Downloader.cmd'))) {
                        Remove-Item -LiteralPath $oldShortcutPath -Force
                    }
                }
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

} catch {
    Write-Host ''
    Write-Step 'x' ('Setup failed: {0}' -f $_.Exception.Message)
    Write-Step '!' 'Check your internet connection, then double-click this installer again. Existing app files and downloads are kept.'
    if ($transcriptStarted) { Write-Step '!' "If it fails again, share this setup log: $logPath" }
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
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}

# Release the setup lock and staging files before opening the interactive app.
if (-not $NoLaunch) {
    & (Join-Path $InstallDir "Yt-dlp Downloader.cmd")
}
