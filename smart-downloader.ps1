[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:YtDlp = Join-Path $script:Root 'yt-dlp.exe'
$script:DownloadsRoot = Join-Path $script:Root 'Downloads'
$script:LogsRoot = Join-Path $script:Root 'logs'
$script:HistoryPath = Join-Path $script:LogsRoot 'download-history.csv'
$script:OutputMarker = '__SMART_DOWNLOADER_FILE__:'
$script:MediaExtensions = @(
    '.mp4', '.mkv', '.webm', '.mov', '.avi', '.flv',
    '.mp3', '.m4a', '.aac', '.wav', '.opus', '.ogg', '.flac'
)

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
    $Host.UI.RawUI.WindowTitle = "Seen's yt-dlp Downloader"
} catch {
    # Some redirected/non-interactive hosts do not expose console settings.
}

function Write-Heading {
    param([Parameter(Mandatory = $true)][string]$Text)

    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkCyan
}

function Pause-Terminal {
    Write-Host ''
    [void](Read-Host 'Press Enter to return to the main menu')
}

function ConvertTo-HumanSize {
    param([Parameter(Mandatory = $true)][long]$Bytes)

    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value /= 1024
        $unitIndex++
    }

    if ($unitIndex -eq 0) {
        return ('{0:N0} {1}' -f $value, $units[$unitIndex])
    }
    return ('{0:N2} {1}' -f $value, $units[$unitIndex])
}

function Get-RelativeDisplayPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rootWithSeparator = $script:Root.TrimEnd('\') + '\'
    if ($Path.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($rootWithSeparator.Length)
    }
    return $Path
}

function Test-IsMediaFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    return $script:MediaExtensions -contains $File.Extension.ToLowerInvariant()
}

function Get-MediaFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { Test-IsMediaFile -File $_ }
    )
}

function Get-FileSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $snapshot = @{}
    foreach ($file in (Get-MediaFiles -Path $Path)) {
        $snapshot[$file.FullName] = '{0}:{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
    }
    return $snapshot
}

function Get-NewOrChangedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Before
    )

    $changed = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($file in (Get-MediaFiles -Path $Path)) {
        $signature = '{0}:{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        if (-not $Before.ContainsKey($file.FullName) -or $Before[$file.FullName] -ne $signature) {
            $changed.Add($file)
        }
    }
    return @($changed)
}

function Show-FileList {
    param(
        [Parameter(Mandatory = $true)][object[]]$Files,
        [switch]$IncludeTotal
    )

    $sorted = @($Files | Sort-Object Length -Descending)
    if ($sorted.Count -eq 0) {
        Write-Host 'No completed media files found.' -ForegroundColor Yellow
        return
    }

    Write-Host ('{0,4}  {1,12}  {2,-19}  {3}' -f '#', 'Size', 'Downloaded/modified', 'File') -ForegroundColor DarkGray
    $index = 1
    foreach ($file in $sorted) {
        $size = ConvertTo-HumanSize -Bytes ([long]$file.Length)
        $when = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $displayPath = Get-RelativeDisplayPath -Path $file.FullName
        Write-Host ('{0,4}  {1,12}  {2,-19}  {3}' -f $index, $size, $when, $displayPath)
        $index++
    }

    if ($IncludeTotal) {
        $totalBytes = [long](($sorted | Measure-Object -Property Length -Sum).Sum)
        Write-Host ''
        Write-Host ('Total: {0} files, {1} ({2:N0} bytes)' -f $sorted.Count, (ConvertTo-HumanSize -Bytes $totalBytes), $totalBytes) -ForegroundColor Green
    }
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-MetadataIsPlaylist {
    param([AllowNull()][object]$Metadata)

    $type = Get-PropertyValue -InputObject $Metadata -Name '_type'
    if ($type -in @('playlist', 'multi_video')) {
        return $true
    }
    return $null -ne (Get-PropertyValue -InputObject $Metadata -Name 'entries')
}

function Test-MetadataIsLive {
    param([AllowNull()][object]$Metadata)

    if ($null -eq $Metadata) {
        return $false
    }

    $liveStatus = Get-PropertyValue -InputObject $Metadata -Name 'live_status'
    $isLive = Get-PropertyValue -InputObject $Metadata -Name 'is_live'
    if ($liveStatus -eq 'is_live' -or $isLive -eq $true) {
        return $true
    }

    $entries = Get-PropertyValue -InputObject $Metadata -Name 'entries'
    if ($null -ne $entries) {
        foreach ($entry in @($entries)) {
            $entryLiveStatus = Get-PropertyValue -InputObject $entry -Name 'live_status'
            $entryIsLive = Get-PropertyValue -InputObject $entry -Name 'is_live'
            if ($entryLiveStatus -eq 'is_live' -or $entryIsLive -eq $true) {
                return $true
            }
        }
    }
    return $false
}

function Test-UrlHasVideoItem {
    param([Parameter(Mandatory = $true)][string]$Url)

    return $Url -match '(?i)([?&]v=[^&]+|youtu\.be/[^/?&]+|youtube\.com/(shorts|live|embed)/[^/?&]+)'
}

function Get-MetadataProbe {
    param([Parameter(Mandatory = $true)][string]$Url)

    $probeArguments = @(
        '--dump-single-json',
        '--flat-playlist',
        '--skip-download',
        '--no-warnings',
        '--',
        $Url
    )

    try {
        $output = (& $script:YtDlp @probeArguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
            return [pscustomobject]@{
                Success  = $false
                Metadata = $null
                Error    = $output
            }
        }

        $metadata = $output | ConvertFrom-Json
        return [pscustomobject]@{
            Success  = $true
            Metadata = $metadata
            Error    = $null
        }
    } catch {
        return [pscustomobject]@{
            Success  = $false
            Metadata = $null
            Error    = $_.Exception.Message
        }
    }
}

function Read-FormatPreset {
    while ($true) {
        Write-Host ''
        Write-Host 'Choose a format:' -ForegroundColor Cyan
        Write-Host '  1. MP4 video (compatible H.264/AAC)'
        Write-Host '  2. MP3 audio'
        Write-Host '  3. MKV video (best available codecs)'
        Write-Host '  4. AAC audio'
        Write-Host '  C. Cancel'
        $choice = (Read-Host 'Format [1]').Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
        switch ($choice) {
            '1' { return 'mp4' }
            '2' { return 'mp3' }
            '3' { return 'mkv' }
            '4' { return 'aac' }
            'C' { return $null }
            default { Write-Host 'Please choose 1, 2, 3, 4, or C.' -ForegroundColor Yellow }
        }
    }
}

function Read-LiveMode {
    while ($true) {
        Write-Host ''
        Write-Host 'Livestream handling:' -ForegroundColor Cyan
        Write-Host '  A. Auto-detect an active live (recommended)'
        Write-Host '  Y. Force download from the start'
        Write-Host '  N. Normal download without live-from-start'
        Write-Host '  C. Cancel'
        $choice = (Read-Host 'Live mode [A]').Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'A' }
        switch ($choice) {
            'A' { return 'Auto' }
            'Y' { return 'Force' }
            'N' { return 'Normal' }
            'C' { return $null }
            default { Write-Host 'Please choose A, Y, N, or C.' -ForegroundColor Yellow }
        }
    }
}

function Read-PlaylistMode {
    param(
        [Parameter(Mandatory = $true)][bool]$ProbeSucceeded,
        [Parameter(Mandatory = $false)][bool]$IsPlaylist = $false,
        [Parameter(Mandatory = $true)][string]$Url
    )

    if ($ProbeSucceeded -and -not $IsPlaylist) {
        return 'Single'
    }

    if ($ProbeSucceeded -and $IsPlaylist -and -not (Test-UrlHasVideoItem -Url $Url)) {
        while ($true) {
            Write-Host ''
            Write-Host 'This appears to be a playlist URL without a selected video.' -ForegroundColor Yellow
            $choice = (Read-Host 'Download the full playlist? [Y]es / [C]ancel').Trim().ToUpperInvariant()
            if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'Y' }
            switch ($choice) {
                'Y' { return 'Playlist' }
                'C' { return $null }
                default { Write-Host 'Please choose Y or C.' -ForegroundColor Yellow }
            }
        }
    }

    while ($true) {
        Write-Host ''
        if ($ProbeSucceeded) {
            Write-Host 'This link can download a playlist.' -ForegroundColor Yellow
        } else {
            Write-Host 'Playlist detection was unavailable. Choose the safe single-video mode or allow a playlist.' -ForegroundColor Yellow
        }
        Write-Host '  1. Single/current video only'
        Write-Host '  2. Full playlist'
        Write-Host '  C. Cancel'
        $choice = (Read-Host 'Playlist mode [1]').Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
        switch ($choice) {
            '1' { return 'Single' }
            '2' { return 'Playlist' }
            'C' { return $null }
            default { Write-Host 'Please choose 1, 2, or C.' -ForegroundColor Yellow }
        }
    }
}

function Resolve-LiveDecision {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedMode,
        [Parameter(Mandatory = $true)][bool]$ProbeSucceeded,
        [AllowNull()][object]$Metadata
    )

    if ($RequestedMode -eq 'Force') {
        return [pscustomobject]@{ Cancelled = $false; Enabled = $true; Description = 'Forced' }
    }
    if ($RequestedMode -eq 'Normal') {
        return [pscustomobject]@{ Cancelled = $false; Enabled = $false; Description = 'Normal' }
    }
    if ($ProbeSucceeded) {
        $detectedLive = Test-MetadataIsLive -Metadata $Metadata
        if ($detectedLive) {
            Write-Host 'Active livestream detected; live-from-start will be enabled.' -ForegroundColor Green
            return [pscustomobject]@{ Cancelled = $false; Enabled = $true; Description = 'Auto (live detected)' }
        }
        Write-Host 'No active livestream detected; using normal download mode.' -ForegroundColor DarkGray
        return [pscustomobject]@{ Cancelled = $false; Enabled = $false; Description = 'Auto (not live)' }
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Automatic live detection failed.' -ForegroundColor Yellow
        Write-Host '  N. Continue as a normal download'
        Write-Host '  L. Force live-from-start'
        Write-Host '  C. Cancel'
        $choice = (Read-Host 'Continue [N]').Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'N' }
        switch ($choice) {
            'N' { return [pscustomobject]@{ Cancelled = $false; Enabled = $false; Description = 'Auto failed; normal chosen' } }
            'L' { return [pscustomobject]@{ Cancelled = $false; Enabled = $true; Description = 'Auto failed; live forced' } }
            'C' { return [pscustomobject]@{ Cancelled = $true; Enabled = $false; Description = 'Cancelled' } }
            default { Write-Host 'Please choose N, L, or C.' -ForegroundColor Yellow }
        }
    }
}

function Add-HistoryRows {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    if ($Rows.Count -eq 0) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:LogsRoot)) {
        [void](New-Item -ItemType Directory -Path $script:LogsRoot -Force)
    }

    if (Test-Path -LiteralPath $script:HistoryPath) {
        $Rows | Export-Csv -LiteralPath $script:HistoryPath -NoTypeInformation -Encoding UTF8 -Append
    } else {
        $Rows | Export-Csv -LiteralPath $script:HistoryPath -NoTypeInformation -Encoding UTF8
    }
}

function New-HistoryRow {
    param(
        [Parameter(Mandatory = $true)][datetime]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Preset,
        [Parameter(Mandatory = $true)][string]$LiveMode,
        [Parameter(Mandatory = $true)][string]$PlaylistMode,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][System.IO.FileInfo]$File
    )

    $filePath = ''
    $sizeBytes = [long]0
    if ($null -ne $File) {
        $filePath = $File.FullName
        $sizeBytes = [long]$File.Length
    }

    return [pscustomobject][ordered]@{
        TimestampLocal = $Timestamp.ToString('yyyy-MM-ddTHH:mm:sszzz')
        Url            = $Url
        Preset         = $Preset
        LiveMode       = $LiveMode
        PlaylistMode   = $PlaylistMode
        Status         = $Status
        FilePath       = $filePath
        SizeBytes      = $sizeBytes
    }
}

function Resolve-CompletedFiles {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$ReportedPaths,
        [Parameter(Mandatory = $true)][string]$TargetFolder,
        [Parameter(Mandatory = $true)][hashtable]$Before
    )

    $filesByPath = @{}
    foreach ($reportedPath in $ReportedPaths) {
        $candidate = $reportedPath.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $script:Root $candidate
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $file = Get-Item -LiteralPath $candidate
            if (Test-IsMediaFile -File $file) {
                $filesByPath[$file.FullName] = $file
            }
        }
    }

    foreach ($file in (Get-NewOrChangedFiles -Path $TargetFolder -Before $Before)) {
        $filesByPath[$file.FullName] = $file
    }
    return @($filesByPath.Values)
}

function Start-SmartDownload {
    Write-Heading -Text 'New download'

    $url = (Read-Host 'Paste the video or playlist link (blank to cancel)').Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        return
    }

    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -notin @('http', 'https')) {
        Write-Host 'Please enter a complete http:// or https:// link.' -ForegroundColor Red
        Pause-Terminal
        return
    }

    $preset = Read-FormatPreset
    if ($null -eq $preset) { return }
    $requestedLiveMode = Read-LiveMode
    if ($null -eq $requestedLiveMode) { return }

    Write-Host ''
    Write-Host 'Inspecting the link for livestream and playlist information...' -ForegroundColor DarkGray
    $probe = Get-MetadataProbe -Url $url
    if (-not $probe.Success) {
        Write-Host 'The metadata probe did not succeed. The download may still work.' -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace([string]$probe.Error)) {
            $errorPreview = ([string]$probe.Error -split "`r?`n" | Select-Object -Last 1)
            Write-Host $errorPreview -ForegroundColor DarkYellow
        }
    }

    $isPlaylist = $false
    if ($probe.Success) {
        $isPlaylist = Test-MetadataIsPlaylist -Metadata $probe.Metadata
    }
    $playlistMode = Read-PlaylistMode -ProbeSucceeded $probe.Success -IsPlaylist $isPlaylist -Url $url
    if ($null -eq $playlistMode) { return }

    $liveDecision = Resolve-LiveDecision -RequestedMode $requestedLiveMode -ProbeSucceeded $probe.Success -Metadata $probe.Metadata
    if ($liveDecision.Cancelled) { return }

    $startedAt = Get-Date
    $targetFolder = Join-Path $script:DownloadsRoot $startedAt.ToString('yyyy-MM-dd')
    if (-not (Test-Path -LiteralPath $targetFolder)) {
        [void](New-Item -ItemType Directory -Path $targetFolder -Force)
    }
    $before = Get-FileSnapshot -Path $targetFolder

    $arguments = @('-t', $preset, '-P', $targetFolder)
    if ($liveDecision.Enabled) {
        $arguments += '--live-from-start'
    }
    if ($playlistMode -eq 'Single') {
        $arguments += '--no-playlist'
    }
    $arguments += @('--print', ('after_move:{0}%(filepath)s' -f $script:OutputMarker), '--', $url)

    Write-Heading -Text 'Downloading'
    Write-Host ('Format: {0} | Live: {1} | Playlist: {2}' -f $preset.ToUpperInvariant(), $liveDecision.Description, $playlistMode)
    Write-Host ('Destination: {0}' -f (Get-RelativeDisplayPath -Path $targetFolder))
    Write-Host 'Press Ctrl+C once if you need to interrupt the download.' -ForegroundColor DarkGray
    Write-Host ''

    $reportedPaths = New-Object System.Collections.Generic.List[string]
    $interrupted = $false
    $exitCode = 1
    try {
        & $script:YtDlp @arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($line.StartsWith($script:OutputMarker, [System.StringComparison]::Ordinal)) {
                $reportedPaths.Add($line.Substring($script:OutputMarker.Length))
                Write-Host ('Saved: {0}' -f $line.Substring($script:OutputMarker.Length)) -ForegroundColor Green
            } else {
                Write-Host $line
            }
        }
        $exitCode = $LASTEXITCODE
    } catch [System.Management.Automation.PipelineStoppedException] {
        $interrupted = $true
        $exitCode = 130
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $exitCode = 1
    }

    $completedFiles = @(Resolve-CompletedFiles -ReportedPaths $reportedPaths -TargetFolder $targetFolder -Before $before)
    $historyRows = New-Object System.Collections.Generic.List[object]

    if ($exitCode -eq 0) {
        foreach ($file in $completedFiles) {
            $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $preset -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status 'Completed' -File $file))
        }
        if ($completedFiles.Count -eq 0) {
            $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $preset -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status 'No new file' -File $null))
        }
    } else {
        $partialStatus = if ($interrupted) { 'Completed before interruption' } else { 'Completed before failure' }
        foreach ($file in $completedFiles) {
            $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $preset -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status $partialStatus -File $file))
        }
        $attemptStatus = if ($interrupted) { 'Interrupted' } else { 'Failed (exit {0})' -f $exitCode }
        $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $preset -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status $attemptStatus -File $null))
    }

    try {
        Add-HistoryRows -Rows @($historyRows)
    } catch {
        Write-Host ('Could not update download history: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }

    Write-Heading -Text 'Download result'
    if ($exitCode -eq 0) {
        Write-Host 'yt-dlp finished successfully.' -ForegroundColor Green
    } elseif ($interrupted) {
        Write-Host 'The download was interrupted. Any .part file is kept so yt-dlp can resume it later.' -ForegroundColor Yellow
    } else {
        Write-Host ('yt-dlp failed with exit code {0}.' -f $exitCode) -ForegroundColor Red
    }
    Show-FileList -Files $completedFiles -IncludeTotal
    Pause-Terminal
}

function Show-LibraryReport {
    Write-Heading -Text 'Media library - biggest to smallest'
    Write-Host 'Temporary .part/.ytdl files, scripts, logs, cookies, and executables are excluded.' -ForegroundColor DarkGray
    Write-Host ''
    $files = @(Get-MediaFiles -Path $script:Root)
    Show-FileList -Files $files -IncludeTotal
    Pause-Terminal
}

function Show-DownloadHistory {
    Write-Heading -Text 'Download history - biggest to smallest'
    if (-not (Test-Path -LiteralPath $script:HistoryPath)) {
        Write-Host "No downloads have been recorded by Seen's yt-dlp Downloader yet." -ForegroundColor Yellow
        Pause-Terminal
        return
    }

    try {
        $rows = @(Import-Csv -LiteralPath $script:HistoryPath)
    } catch {
        Write-Host ('Could not read the history CSV: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Pause-Terminal
        return
    }

    $sorted = @($rows | Sort-Object { [long]$_.SizeBytes } -Descending)
    if ($sorted.Count -eq 0) {
        Write-Host 'The history file is empty.' -ForegroundColor Yellow
        Pause-Terminal
        return
    }

    $index = 1
    foreach ($row in $sorted) {
        $size = ConvertTo-HumanSize -Bytes ([long]$row.SizeBytes)
        Write-Host ('{0,4}. {1,12}  {2,-28}  {3}  {4}' -f $index, $size, $row.Status, $row.TimestampLocal, $row.Preset.ToUpperInvariant())
        if (-not [string]::IsNullOrWhiteSpace($row.FilePath)) {
            Write-Host ('      File: {0}' -f (Get-RelativeDisplayPath -Path $row.FilePath)) -ForegroundColor DarkGray
        }
        Write-Host ('      URL:  {0}' -f $row.Url) -ForegroundColor DarkGray
        $index++
    }

    $recordedFiles = @($rows | Where-Object { [long]$_.SizeBytes -gt 0 })
    $totalBytes = [long](($recordedFiles | Measure-Object -Property { [long]$_.SizeBytes } -Sum).Sum)
    Write-Host ''
    Write-Host ('Recorded outputs: {0} files, {1} ({2:N0} bytes)' -f $recordedFiles.Count, (ConvertTo-HumanSize -Bytes $totalBytes), $totalBytes) -ForegroundColor Green
    Write-Host ('CSV: {0}' -f (Get-RelativeDisplayPath -Path $script:HistoryPath)) -ForegroundColor DarkGray
    Pause-Terminal
}

function Show-MainMenu {
    Clear-Host
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host "          SEEN'S yt-dlp DOWNLOADER" -ForegroundColor White
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host '  1. Download a video, audio, live, or playlist'
    Write-Host '  2. View media library sizes'
    Write-Host '  3. View recorded download history'
    Write-Host '  4. Exit'
    Write-Host ''
}

if (-not (Test-Path -LiteralPath $script:YtDlp -PathType Leaf)) {
    Write-Host ('yt-dlp.exe was not found beside this script: {0}' -f $script:YtDlp) -ForegroundColor Red
    exit 1
}

if ($null -eq (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'Warning: ffmpeg was not found on PATH. MP3/AAC extraction and some video merges may fail.' -ForegroundColor Yellow
    Pause-Terminal
}

while ($true) {
    Show-MainMenu
    $menuChoice = (Read-Host 'Choose an option [1]').Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($menuChoice)) { $menuChoice = '1' }
    switch ($menuChoice) {
        '1' { Start-SmartDownload }
        '2' { Show-LibraryReport }
        '3' { Show-DownloadHistory }
        '4' { break }
        'Q' { break }
        default {
            Write-Host 'Please choose 1, 2, 3, or 4.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
    if ($menuChoice -in @('4', 'Q')) { break }
}

Write-Host 'Goodbye.' -ForegroundColor Cyan
