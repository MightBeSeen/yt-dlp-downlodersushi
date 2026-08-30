[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:YtDlp = Join-Path $script:Root 'yt-dlp.exe'

# Make helpers that live beside the script (e.g. a downloaded ffmpeg.exe) discoverable to
# both this process and the yt-dlp child process, without touching the system PATH.
if (($env:PATH -split ';') -notcontains $script:Root) {
    $env:PATH = $script:Root + ';' + $env:PATH
}

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)

    return ($null -ne (Get-Command ('{0}.exe' -f $Name) -ErrorAction SilentlyContinue)) -or
           ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

# YouTube extraction needs a JavaScript runtime. Detect Node.js or Deno (both work) and
# tell yt-dlp which one to use. Prefer whichever is present so the tool keeps working when
# handed to a machine that only has one of them.
function Update-JsRuntimeState {
    $script:JsRuntime = $null
    foreach ($candidate in @('node', 'deno')) {
        if (Test-CommandAvailable -Name $candidate) {
            $script:JsRuntime = $candidate
            break
        }
    }
    if ($null -ne $script:JsRuntime) {
        $script:YtDlpBaseArguments = @('--js-runtimes', $script:JsRuntime)
    } else {
        $script:YtDlpBaseArguments = @()
    }
}

Update-JsRuntimeState
$script:FfmpegAvailable = Test-CommandAvailable -Name 'ffmpeg'
$script:DownloadsRoot = Join-Path $script:Root 'Downloads'
$script:LogsRoot = Join-Path $script:Root 'logs'
$script:HistoryPath = Join-Path $script:LogsRoot 'download-history.csv'
$script:SettingsPath = Join-Path $script:LogsRoot 'settings.json'
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

function Clear-Terminal {
    try {
        Clear-Host
    } catch {
        # Redirected/non-interactive consoles may not expose a valid cursor handle.
    }
}

function ConvertTo-PageCommand {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$InputValue)

    switch ($InputValue.Trim().ToUpperInvariant()) {
        'LEFTARROW'  { return 'Previous' }
        'P'          { return 'Previous' }
        'RIGHTARROW' { return 'Next' }
        'N'          { return 'Next' }
        'ENTER'      { return 'Exit' }
        'ESCAPE'     { return 'Exit' }
        'Q'          { return 'Exit' }
        ''           { return 'Exit' }
        default      { return 'Unknown' }
    }
}

function Read-PageCommand {
    while ($true) {
        try {
            $key = [Console]::ReadKey($true)
            $command = ConvertTo-PageCommand -InputValue ([string]$key.Key)
            if ($command -ne 'Unknown') {
                return $command
            }
        } catch {
            while ($true) {
                $answer = Read-Host 'Page command: N next, P previous, Q back [Q]'
                $command = ConvertTo-PageCommand -InputValue $answer
                if ($command -ne 'Unknown') {
                    return $command
                }
                Write-Host 'Use N, P, Q, or press Enter.' -ForegroundColor Yellow
            }
        }
    }
}

function Get-PageInfo {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][int]$PageIndex,
        [int]$PageSize = 5
    )

    if ($PageSize -lt 1) {
        throw 'Page size must be at least 1.'
    }

    $pageCount = [Math]::Max(1, [int][Math]::Ceiling($Items.Count / [double]$PageSize))
    $clampedPageIndex = [Math]::Max(0, [Math]::Min($PageIndex, $pageCount - 1))
    $startIndex = $clampedPageIndex * $PageSize
    $pageItems = @()
    if ($startIndex -lt $Items.Count) {
        $endIndex = [Math]::Min($startIndex + $PageSize - 1, $Items.Count - 1)
        $pageItems = @($Items[$startIndex..$endIndex])
    }

    return [pscustomobject]@{
        PageIndex  = $clampedPageIndex
        PageNumber = $clampedPageIndex + 1
        PageCount  = $pageCount
        StartIndex = $startIndex
        Items      = @($pageItems)
    }
}

function Write-PageFooter {
    param(
        [Parameter(Mandatory = $true)][int]$PageNumber,
        [Parameter(Mandatory = $true)][int]$PageCount
    )

    Write-Host ''
    Write-Host ('Page {0} of {1} | Left/P: Previous | Right/N: Next | Enter/Esc/Q: Back' -f $PageNumber, $PageCount) -ForegroundColor Cyan
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

function Write-FileRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [int]$StartIndex = 0
    )

    Write-Host ('{0,4}  {1,12}  {2,-19}  {3}' -f '#', 'Size', 'Downloaded/modified', 'File') -ForegroundColor DarkGray
    $index = $StartIndex + 1
    foreach ($file in $Files) {
        $size = ConvertTo-HumanSize -Bytes ([long]$file.Length)
        $when = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $displayPath = Get-RelativeDisplayPath -Path $file.FullName
        Write-Host ('{0,4}  {1,12}  {2,-19}  {3}' -f $index, $size, $when, $displayPath)
        $index++
    }
}

function Show-FileList {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [switch]$IncludeTotal
    )

    $sorted = @($Files | Sort-Object Length -Descending)
    if ($sorted.Count -eq 0) {
        Write-Host 'No completed media files found.' -ForegroundColor Yellow
        return
    }

    Write-FileRows -Files $sorted

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

    $probeArguments = @($script:YtDlpBaseArguments) + @(
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

function Read-MenuChoice {
    # A single reusable picker. In a real console it draws an arrow-key menu that
    # highlights the current row and redraws in place; when input is redirected (the
    # test harness, or any piped run) it falls back to a numbered Read-Host prompt so
    # existing automation keeps working. Returns the chosen option's Value, the string
    # 'BACK' (when -AllowBack and the user steps back), or $null (cancel).
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][object[]]$Options,
        [string[]]$Notes = @(),
        [switch]$AllowBack
    )

    # Normalise each option to a consistent shape and precompute the default (first
    # selectable) index so Enter keeps yielding the historical default in both modes.
    $items = @()
    foreach ($option in $Options) {
        $items += [pscustomobject]@{
            Key      = [string](Get-PropertyValue -InputObject $option -Name 'Key')
            Label    = [string](Get-PropertyValue -InputObject $option -Name 'Label')
            Value    = (Get-PropertyValue -InputObject $option -Name 'Value')
            Disabled = [bool](Get-PropertyValue -InputObject $option -Name 'Disabled')
        }
    }
    $defaultIndex = 0
    for ($i = 0; $i -lt $items.Count; $i++) {
        if (-not $items[$i].Disabled) { $defaultIndex = $i; break }
    }

    $canDrawArrows = $false
    try { $canDrawArrows = -not [Console]::IsInputRedirected } catch { $canDrawArrows = $false }

    if (-not $canDrawArrows) {
        return (Read-MenuChoiceText -Title $Title -Items $items -Notes $Notes -AllowBack:$AllowBack -DefaultIndex $defaultIndex)
    }

    return (Read-MenuChoiceArrows -Title $Title -Items $items -Notes $Notes -AllowBack:$AllowBack -DefaultIndex $defaultIndex)
}

function Read-MenuChoiceText {
    param(
        [string]$Title,
        [object[]]$Items,
        [string[]]$Notes,
        [switch]$AllowBack,
        [int]$DefaultIndex
    )

    $keyList = ($Items | Where-Object { -not $_.Disabled } | ForEach-Object { $_.Key })
    $hint = ($keyList -join ', ')
    if ($AllowBack) { $hint = "$hint, B" }
    $hint = "$hint, C"
    $defaultKey = $Items[$DefaultIndex].Key

    while ($true) {
        Write-Host ''
        Write-Host ("{0}:" -f $Title) -ForegroundColor Cyan
        foreach ($note in $Notes) { Write-Host ("  {0}" -f $note) -ForegroundColor Yellow }
        foreach ($item in $Items) {
            $line = ("  {0}. {1}" -f $item.Key, $item.Label)
            if ($item.Disabled) { Write-Host $line -ForegroundColor DarkGray } else { Write-Host $line }
        }
        if ($AllowBack) { Write-Host '  B. Back' }
        Write-Host '  C. Cancel'

        $choice = (Read-Host ("Choose [{0}]" -f $defaultKey)).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $defaultKey.ToUpperInvariant() }
        if ($choice -eq 'C') { return $null }
        if ($AllowBack -and $choice -eq 'B') { return 'BACK' }

        $match = $Items | Where-Object { $_.Key.ToUpperInvariant() -eq $choice } | Select-Object -First 1
        if ($null -ne $match) {
            if ($match.Disabled) {
                Write-Host 'That option is unavailable right now. Pick another.' -ForegroundColor Yellow
            } else {
                return $match.Value
            }
        } else {
            Write-Host ("Please choose one of: {0}." -f $hint) -ForegroundColor Yellow
        }
    }
}

function Read-MenuChoiceArrows {
    param(
        [string]$Title,
        [object[]]$Items,
        [string[]]$Notes,
        [switch]$AllowBack,
        [int]$DefaultIndex
    )

    $selected = $DefaultIndex
    $footer = if ($AllowBack) {
        [char]0x2191 + [char]0x2193 + ' move  ' + [char]0x00B7 + '  Enter select  ' + [char]0x00B7 + '  ' + [char]0x2190 + ' Back  ' + [char]0x00B7 + '  Esc cancel'
    } else {
        [char]0x2191 + [char]0x2193 + ' move  ' + [char]0x00B7 + '  Enter select  ' + [char]0x00B7 + '  Esc cancel'
    }

    $linesDrawn = 0
    $startTop = [Console]::CursorTop
    $firstPaint = $true
    $cursorWasVisible = $true
    try { $cursorWasVisible = [Console]::CursorVisible } catch { $cursorWasVisible = $true }

    $moveTo = {
        param([int]$Index, [int]$Step)
        $count = $Items.Count
        $i = $Index
        for ($n = 0; $n -lt $count; $n++) {
            $i = (($i + $Step) % $count + $count) % $count
            if (-not $Items[$i].Disabled) { return $i }
        }
        return $Index
    }

    try {
        try { [Console]::CursorVisible = $false } catch {}
        # If the very first item is disabled the default already skipped it; ensure the
        # starting selection is landable.
        if ($Items[$selected].Disabled) { $selected = (& $moveTo $selected 1) }

        while ($true) {
            # Repaint in place: rewind to the row where the menu began.
            if (-not $firstPaint) {
                try { [Console]::SetCursorPosition(0, $startTop) } catch {}
            }

            $width = 0
            try { $width = [Console]::BufferWidth } catch { $width = 80 }

            # Draw header lines, then the option rows with color.
            Write-Host ''
            Write-Host ("  {0}" -f $Title) -ForegroundColor Cyan
            foreach ($note in $Notes) { Write-Host ("    {0}" -f $note) -ForegroundColor Yellow }
            Write-Host ''

            for ($idx = 0; $idx -lt $Items.Count; $idx++) {
                $item = $Items[$idx]
                $marker = if ($idx -eq $selected) { '> ' } else { '  ' }
                $text = ("{0}{1}  {2}" -f $marker, $item.Key, $item.Label)
                if ($text.Length -lt ($width - 1)) { $text = $text.PadRight($width - 1) }
                if ($item.Disabled) {
                    Write-Host $text -ForegroundColor DarkGray
                } elseif ($idx -eq $selected) {
                    Write-Host $text -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host $text
                }
            }
            Write-Host ''
            $footerLine = ("  {0}" -f $footer)
            if ($footerLine.Length -lt ($width - 1)) { $footerLine = $footerLine.PadRight($width - 1) }
            Write-Host $footerLine -ForegroundColor DarkGray

            if ($firstPaint) {
                # Header(3 or more) + options + blank + footer. Compute from where we are.
                $linesDrawn = [Console]::CursorTop - $startTop
                if ($linesDrawn -lt 1) { $linesDrawn = 1 }
                $startTop = [Console]::CursorTop - $linesDrawn
                $firstPaint = $false
            }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'    { $selected = (& $moveTo $selected -1) }
                'DownArrow'  { $selected = (& $moveTo $selected 1) }
                'Enter'      { if (-not $Items[$selected].Disabled) { return $Items[$selected].Value } }
                'Escape'     { return $null }
                'LeftArrow'  { if ($AllowBack) { return 'BACK' } }
                'Backspace'  { if ($AllowBack) { return 'BACK' } }
                default {
                    $ch = ([string]$key.KeyChar).ToUpperInvariant()
                    if ($ch -eq 'C') { return $null }
                    if ($AllowBack -and $ch -eq 'B') { return 'BACK' }
                    $matchIndex = -1
                    for ($m = 0; $m -lt $Items.Count; $m++) {
                        if ($Items[$m].Key.ToUpperInvariant() -eq $ch) { $matchIndex = $m; break }
                    }
                    if ($matchIndex -ge 0 -and -not $Items[$matchIndex].Disabled) {
                        return $Items[$matchIndex].Value
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch {}
    }
}

function Read-FormatPreset {
    $audioEnabled = $script:FfmpegAvailable
    $notes = @()
    if (-not $audioEnabled) {
        $notes = @(
            'FFmpeg was not found on PATH, so MP3/AAC audio extraction is disabled.',
            'Install it from https://ffmpeg.org/ and add it to PATH to enable them.'
        )
    }
    $options = @(
        [pscustomobject]@{ Key = '1'; Label = 'MP4 video (compatible H.264/AAC)'; Value = 'mp4'; Disabled = $false }
        [pscustomobject]@{ Key = '2'; Label = 'MP3 audio' + $(if (-not $audioEnabled) { ' (needs FFmpeg)' } else { '' }); Value = 'mp3'; Disabled = (-not $audioEnabled) }
        [pscustomobject]@{ Key = '3'; Label = 'MKV video (best available codecs)'; Value = 'mkv'; Disabled = $false }
        [pscustomobject]@{ Key = '4'; Label = 'AAC audio' + $(if (-not $audioEnabled) { ' (needs FFmpeg)' } else { '' }); Value = 'aac'; Disabled = (-not $audioEnabled) }
    )
    return (Read-MenuChoice -Title 'Choose a format' -Options $options -Notes $notes)
}

function Read-VideoQuality {
    $options = @(
        [pscustomobject]@{ Key = '1'; Label = 'Best available (recommended)'; Value = 'best' }
        [pscustomobject]@{ Key = '2'; Label = 'Up to 1080p'; Value = '1080' }
        [pscustomobject]@{ Key = '3'; Label = 'Up to 720p'; Value = '720' }
    )
    return (Read-MenuChoice -Title 'Choose a maximum video quality' -Options $options -AllowBack)
}

function Read-LiveMode {
    $options = @(
        [pscustomobject]@{ Key = 'A'; Label = 'Auto-detect an active live (recommended)'; Value = 'Auto' }
        [pscustomobject]@{ Key = 'Y'; Label = 'Force download from the start'; Value = 'Force' }
        [pscustomobject]@{ Key = 'N'; Label = 'Normal download without live-from-start'; Value = 'Normal' }
    )
    return (Read-MenuChoice -Title 'Livestream handling' -Options $options -AllowBack)
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
        $options = @(
            [pscustomobject]@{ Key = 'Y'; Label = 'Yes, download the full playlist'; Value = 'Playlist' }
        )
        return (Read-MenuChoice -Title 'This looks like a playlist URL without a selected video' -Options $options -AllowBack)
    }

    $notes = if ($ProbeSucceeded) {
        @('This link can download a whole playlist.')
    } else {
        @('Playlist detection was unavailable. Pick the safe single-video mode, or allow a playlist.')
    }
    $options = @(
        [pscustomobject]@{ Key = '1'; Label = 'Single/current video only'; Value = 'Single' }
        [pscustomobject]@{ Key = '2'; Label = 'Full playlist'; Value = 'Playlist' }
    )
    return (Read-MenuChoice -Title 'Playlist handling' -Options $options -Notes $notes -AllowBack)
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

function Get-DownloaderSettings {
    $settings = [ordered]@{ OpenFolderAfterDownload = $false }
    if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            $value = Get-PropertyValue -InputObject $saved -Name 'OpenFolderAfterDownload'
            if ($value -is [bool]) {
                $settings.OpenFolderAfterDownload = $value
            }
        } catch {
            # A missing or corrupt settings file falls back to the defaults above.
        }
    }
    return [pscustomobject]$settings
}

function Save-DownloaderSettings {
    param([Parameter(Mandatory = $true)][object]$Settings)

    if (-not (Test-Path -LiteralPath $script:LogsRoot)) {
        [void](New-Item -ItemType Directory -Path $script:LogsRoot -Force)
    }
    $Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

# Decide what to hand explorer.exe after a download. A single file is highlighted with
# /select so the user lands right on it; anything else (a playlist, or nothing tracked)
# just opens the folder. Kept side-effect free so it can be unit-tested.
function Get-ExplorerLaunch {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$TargetFolder
    )

    if ($Files.Count -eq 1) {
        return ('/select,"{0}"' -f $Files[0].FullName)
    }
    return ('"{0}"' -f $TargetFolder)
}

function Open-DownloadLocation {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$TargetFolder
    )

    try {
        $argument = Get-ExplorerLaunch -Files $Files -TargetFolder $TargetFolder
        Start-Process -FilePath 'explorer.exe' -ArgumentList $argument
    } catch {
        Write-Host ('Could not open the download folder: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
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
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$ReportedPaths,
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

function Show-DownloadHeader {
    # Clears the screen and paints the fixed top block for the download setup flow:
    # the clip title (if known) with the link underneath, then a boxed "Your choices"
    # panel summarising what has been picked so far. Fields not yet chosen show as em-dash.
    param(
        [string]$Title = '',
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Preset = '',
        [string]$Quality = '',
        [string]$Live = '',
        [string]$Playlist = ''
    )

    $dash = [char]0x2014  # em dash for empty fields
    $labelFor = {
        param([string]$Value, [string]$Kind)
        if ([string]::IsNullOrEmpty($Value)) { return [string]$dash }
        switch ($Kind) {
            'quality' { if ($Value -eq 'best') { return 'Best' } elseif ($Value -eq 'n/a') { return 'n/a' } else { return ('{0}p' -f $Value) } }
            'live'    { switch ($Value) { 'Auto' { return 'Auto-detect' } 'Force' { return 'Force live' } 'Normal' { return 'Normal' } default { return $Value } } }
            'play'    { switch ($Value) { 'Single' { return 'Single video' } 'Playlist' { return 'Full playlist' } default { return $Value } } }
            default   { return $Value.ToUpperInvariant() }
        }
    }

    Clear-Terminal
    Write-Heading -Text 'New download'

    $width = 80
    try { $width = [Console]::BufferWidth } catch { $width = 80 }

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $titleLine = $Title.Trim()
        if ($titleLine.Length -gt ($width - 2)) { $titleLine = $titleLine.Substring(0, [Math]::Max(0, $width - 3)) + [char]0x2026 }
        Write-Host $titleLine -ForegroundColor Cyan
    }
    $linkLine = $Url
    if ($linkLine.Length -gt ($width - 2)) { $linkLine = $linkLine.Substring(0, [Math]::Max(0, $width - 3)) + [char]0x2026 }
    Write-Host $linkLine -ForegroundColor DarkGray

    # Boxed "Your choices" panel.
    $inner = 28
    $rows = @(
        @('Format',   (& $labelFor $Preset 'format')),
        @('Quality',  (& $labelFor $Quality 'quality')),
        @('Live',     (& $labelFor $Live 'live')),
        @('Playlist', (& $labelFor $Playlist 'play'))
    )
    $titleTag = ' Your choices '
    $top = [string][char]0x250C + $titleTag + ([string][char]0x2500 * ($inner - $titleTag.Length)) + [char]0x2510
    $bottom = [string][char]0x2514 + ([string][char]0x2500 * $inner) + [char]0x2518

    Write-Host ''
    Write-Host $top -ForegroundColor DarkCyan
    foreach ($row in $rows) {
        $value = [string]$row[1]
        $maxValue = $inner - 12
        if ($value.Length -gt $maxValue) { $value = $value.Substring(0, [Math]::Max(0, $maxValue - 1)) + [char]0x2026 }
        $content = (' {0} {1}' -f ($row[0]).PadRight(9), $value)
        if ($content.Length -lt $inner) { $content = $content.PadRight($inner) }
        Write-Host ([string][char]0x2502) -NoNewline -ForegroundColor DarkCyan
        Write-Host $content -NoNewline
        Write-Host ([string][char]0x2502) -ForegroundColor DarkCyan
    }
    Write-Host $bottom -ForegroundColor DarkCyan
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

    # Probe once, upfront, so the setup screens can show the clip title and so the
    # playlist step never re-hits the network when you step back and forth.
    Write-Host ''
    Write-Host 'Fetching video details...' -ForegroundColor DarkGray
    $probe = Get-MetadataProbe -Url $url
    $clipTitle = ''
    if ($probe.Success) {
        $clipTitle = [string](Get-PropertyValue -InputObject $probe.Metadata -Name 'title')
    }

    # The questions run as a small step machine so a mis-click is recoverable: each
    # prompt offers "B. Back", which steps back exactly one question while keeping the
    # earlier answers intact, instead of only cancelling out to the main menu.
    # Steps: 0 Format, 1 Quality (video only), 2 Live mode, 3 Playlist.
    $preset = $null
    $quality = 'best'
    $requestedLiveMode = $null
    $playlistMode = $null
    $step = 0
    while ($step -le 3) {
        # Show only choices confirmed by an *earlier* step; the field being asked now
        # (and any later ones) stays blank, so stepping Back visibly clears it.
        $presetDisplay  = if ($step -gt 0) { [string]$preset } else { '' }
        $qualityDisplay = if ($step -gt 1) { if ($preset -in @('mp4', 'mkv')) { [string]$quality } else { 'n/a' } } else { '' }
        $liveDisplay    = if ($step -gt 2) { [string]$requestedLiveMode } else { '' }
        Show-DownloadHeader -Title $clipTitle -Url $url `
            -Preset $presetDisplay `
            -Quality $qualityDisplay `
            -Live $liveDisplay `
            -Playlist ''
        switch ($step) {
            0 {
                $preset = Read-FormatPreset
                if ($null -eq $preset) { return }  # Back on the first question cancels.
                $step = 1
            }
            1 {
                if ($preset -in @('mp4', 'mkv')) {
                    $quality = Read-VideoQuality
                    if ($null -eq $quality) { return }
                    if ($quality -eq 'BACK') { $step = 0; break }
                } else {
                    $quality = 'best'  # Audio presets have no quality step.
                }
                $step = 2
            }
            2 {
                $requestedLiveMode = Read-LiveMode
                if ($null -eq $requestedLiveMode) { return }
                if ($requestedLiveMode -eq 'BACK') {
                    # Back skips the quality step for audio presets.
                    $step = if ($preset -in @('mp4', 'mkv')) { 1 } else { 0 }
                    break
                }
                $step = 3
            }
            3 {
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
                if ($playlistMode -eq 'BACK') { $step = 2; break }
                $step = 4  # All questions answered; leave the loop.
            }
        }
    }

    $liveDecision = Resolve-LiveDecision -RequestedMode $requestedLiveMode -ProbeSucceeded $probe.Success -Metadata $probe.Metadata
    if ($liveDecision.Cancelled) { return }

    $startedAt = Get-Date
    $targetFolder = Join-Path $script:DownloadsRoot $startedAt.ToString('yyyy-MM-dd')
    if (-not (Test-Path -LiteralPath $targetFolder)) {
        [void](New-Item -ItemType Directory -Path $targetFolder -Force)
    }
    $before = Get-FileSnapshot -Path $targetFolder

    # --print enables yt-dlp's quiet mode implicitly, so restore progress explicitly.
    # The output is consumed by a line-oriented PowerShell pipeline; --newline makes
    # percentage, speed, downloaded size, and ETA updates visible as they arrive.
    $arguments = @($script:YtDlpBaseArguments) + @('-t', $preset, '-P', $targetFolder, '--progress', '--newline')
    # The mp4/mkv presets only set container remux + a sort key, so an explicit -f
    # height ceiling composes cleanly to cap resolution without a hard failure when
    # the requested height is unavailable (it falls back to the best that fits).
    if ($preset -in @('mp4', 'mkv') -and $quality -ne 'best') {
        $arguments += @('-f', ('bv*[height<={0}]+ba/b[height<={0}]' -f $quality))
    }
    if ($liveDecision.Enabled) {
        $arguments += '--live-from-start'
    }
    if ($playlistMode -eq 'Single') {
        $arguments += '--no-playlist'
    }
    $arguments += @('--print', ('after_move:{0}%(filepath)s' -f $script:OutputMarker), '--', $url)

    $qualityLabel = if ($preset -in @('mp4', 'mkv')) {
        if ($quality -eq 'best') { 'Best' } else { ('{0}p' -f $quality) }
    } else {
        'n/a'
    }
    $presetRecord = if ($preset -in @('mp4', 'mkv') -and $quality -ne 'best') {
        '{0}/{1}p' -f $preset, $quality
    } else {
        $preset
    }

    Write-Heading -Text 'Downloading'
    Write-Host ('Format: {0} | Quality: {1} | Live: {2} | Playlist: {3}' -f $preset.ToUpperInvariant(), $qualityLabel, $liveDecision.Description, $playlistMode)
    Write-Host ('Destination: {0}' -f (Get-RelativeDisplayPath -Path $targetFolder))
    Write-Host 'Press Ctrl+C once if you need to interrupt the download.' -ForegroundColor DarkGray
    Write-Host ''

    $reportedPaths = New-Object System.Collections.Generic.List[string]
    $interrupted = $false
    $exitCode = 1
    $progressLineActive = $false
    $progressLineWidth = 0
    try {
        & $script:YtDlp @arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($line -match '^\[download\]\s+\d+(?:\.\d+)?%') {
                $progressLineWidth = [Math]::Max($progressLineWidth, $line.Length)
                $padding = ' ' * ($progressLineWidth - $line.Length)
                [Console]::Write(("`r{0}{1}" -f $line, $padding))
                $progressLineActive = $true
            } else {
                if ($progressLineActive) {
                    [Console]::WriteLine()
                    $progressLineActive = $false
                    $progressLineWidth = 0
                }
            }

            if ($line.StartsWith($script:OutputMarker, [System.StringComparison]::Ordinal)) {
                $reportedPaths.Add($line.Substring($script:OutputMarker.Length))
                Write-Host ('Saved: {0}' -f $line.Substring($script:OutputMarker.Length)) -ForegroundColor Green
            } elseif ($line -notmatch '^\[download\]\s+\d+(?:\.\d+)?%') {
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
    } finally {
        if ($progressLineActive) {
            [Console]::WriteLine()
        }
    }

    $completedFiles = @(Resolve-CompletedFiles -ReportedPaths $reportedPaths -TargetFolder $targetFolder -Before $before)
    $historyRows = New-Object System.Collections.Generic.List[object]

    if ($exitCode -eq 0) {
        foreach ($file in $completedFiles) {
            $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $presetRecord -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status 'Completed' -File $file))
        }
        if ($completedFiles.Count -eq 0) {
            $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $presetRecord -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status 'No new file' -File $null))
        }
    } else {
        $partialStatus = if ($interrupted) { 'Completed before interruption' } else { 'Completed before failure' }
        foreach ($file in $completedFiles) {
            $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $presetRecord -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status $partialStatus -File $file))
        }
        $attemptStatus = if ($interrupted) { 'Interrupted' } else { 'Failed (exit {0})' -f $exitCode }
        $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset $presetRecord -LiveMode $liveDecision.Description -PlaylistMode $playlistMode -Status $attemptStatus -File $null))
    }

    try {
        Add-HistoryRows -Rows $historyRows.ToArray()
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
    if ($exitCode -eq 0 -and $script:Settings.OpenFolderAfterDownload -and $completedFiles.Count -gt 0) {
        Open-DownloadLocation -Files $completedFiles -TargetFolder $targetFolder
    }
    Pause-Terminal
}

function Show-LibraryReport {
    $files = @(Get-MediaFiles -Path $script:Root | Sort-Object Length -Descending)
    if ($files.Count -eq 0) {
        Clear-Terminal
        Write-Heading -Text 'Media library - biggest to smallest'
        Write-Host 'Temporary .part/.ytdl files, scripts, logs, cookies, and executables are excluded.' -ForegroundColor DarkGray
        Write-Host ''
        Show-FileList -Files @()
        Pause-Terminal
        return
    }

    $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    $pageIndex = 0
    while ($true) {
        $page = Get-PageInfo -Items $files -PageIndex $pageIndex -PageSize 5
        Clear-Terminal
        Write-Heading -Text 'Media library - biggest to smallest'
        Write-Host 'Temporary .part/.ytdl files, scripts, logs, cookies, and executables are excluded.' -ForegroundColor DarkGray
        Write-Host ''
        Write-FileRows -Files $page.Items -StartIndex $page.StartIndex
        Write-Host ''
        Write-Host ('Total: {0} files, {1} ({2:N0} bytes)' -f $files.Count, (ConvertTo-HumanSize -Bytes $totalBytes), $totalBytes) -ForegroundColor Green
        Write-PageFooter -PageNumber $page.PageNumber -PageCount $page.PageCount

        while ($true) {
            $command = Read-PageCommand
            if ($command -eq 'Exit') { return }
            if ($command -eq 'Previous' -and $pageIndex -gt 0) {
                $pageIndex--
                break
            }
            if ($command -eq 'Next' -and $pageIndex -lt ($page.PageCount - 1)) {
                $pageIndex++
                break
            }
        }
    }
}

function Show-DownloadHistory {
    if (-not (Test-Path -LiteralPath $script:HistoryPath)) {
        Clear-Terminal
        Write-Heading -Text 'Download history - biggest to smallest'
        Write-Host "No downloads have been recorded by Seen's yt-dlp Downloader yet." -ForegroundColor Yellow
        Pause-Terminal
        return
    }

    try {
        $rows = @(Import-Csv -LiteralPath $script:HistoryPath)
    } catch {
        Clear-Terminal
        Write-Heading -Text 'Download history - biggest to smallest'
        Write-Host ('Could not read the history CSV: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Pause-Terminal
        return
    }

    $sorted = @($rows | Sort-Object { [long]$_.SizeBytes } -Descending)
    if ($sorted.Count -eq 0) {
        Clear-Terminal
        Write-Heading -Text 'Download history - biggest to smallest'
        Write-Host 'The history file is empty.' -ForegroundColor Yellow
        Pause-Terminal
        return
    }

    $recordedFiles = @($rows | Where-Object { [long]$_.SizeBytes -gt 0 })
    $totalBytes = [long](($recordedFiles | ForEach-Object { [long]$_.SizeBytes } | Measure-Object -Sum).Sum)
    $pageIndex = 0
    while ($true) {
        $page = Get-PageInfo -Items $sorted -PageIndex $pageIndex -PageSize 5
        Clear-Terminal
        Write-Heading -Text 'Download history - biggest to smallest'
        $index = $page.StartIndex + 1
        foreach ($row in $page.Items) {
            $size = ConvertTo-HumanSize -Bytes ([long]$row.SizeBytes)
            Write-Host ('{0,4}. {1,12}  {2,-28}  {3}  {4}' -f $index, $size, $row.Status, $row.TimestampLocal, $row.Preset.ToUpperInvariant())
            if (-not [string]::IsNullOrWhiteSpace($row.FilePath)) {
                Write-Host ('      File: {0}' -f (Get-RelativeDisplayPath -Path $row.FilePath)) -ForegroundColor DarkGray
            }
            Write-Host ('      URL:  {0}' -f $row.Url) -ForegroundColor DarkGray
            $index++
        }

        Write-Host ''
        Write-Host ('Recorded outputs: {0} files, {1} ({2:N0} bytes)' -f $recordedFiles.Count, (ConvertTo-HumanSize -Bytes $totalBytes), $totalBytes) -ForegroundColor Green
        Write-Host ('CSV: {0}' -f (Get-RelativeDisplayPath -Path $script:HistoryPath)) -ForegroundColor DarkGray
        Write-PageFooter -PageNumber $page.PageNumber -PageCount $page.PageCount

        while ($true) {
            $command = Read-PageCommand
            if ($command -eq 'Exit') { return }
            if ($command -eq 'Previous' -and $pageIndex -gt 0) {
                $pageIndex--
                break
            }
            if ($command -eq 'Next' -and $pageIndex -lt ($page.PageCount - 1)) {
                $pageIndex++
                break
            }
        }
    }
}

function Update-DownloaderEngine {
    Write-Heading -Text 'Update downloader engine'
    Write-Host 'Checking for a newer yt-dlp.exe...' -ForegroundColor DarkGray
    Write-Host ''
    try {
        & $script:YtDlp @($script:YtDlpBaseArguments) -U 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        $exitCode = $LASTEXITCODE
        Write-Host ''
        if ($exitCode -eq 0) {
            Write-Host 'yt-dlp is up to date (or was updated successfully).' -ForegroundColor Green
        } else {
            Write-Host ('The update command finished with exit code {0}.' -f $exitCode) -ForegroundColor Yellow
        }
    } catch {
        Write-Host ('Could not update yt-dlp: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    Pause-Terminal
}

function Show-SettingsMenu {
    while ($true) {
        Clear-Terminal
        Write-Heading -Text 'Settings'
        $state = if ($script:Settings.OpenFolderAfterDownload) { 'On' } else { 'Off' }
        Write-Host ('  1. Open the download folder when a download finishes: {0}' -f $state)
        Write-Host '  B. Back'
        Write-Host ''
        $choice = (Read-Host 'Choose an option to toggle [B]').Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'B' }
        switch ($choice) {
            '1' {
                $script:Settings.OpenFolderAfterDownload = -not $script:Settings.OpenFolderAfterDownload
                try {
                    Save-DownloaderSettings -Settings $script:Settings
                    $newState = if ($script:Settings.OpenFolderAfterDownload) { 'On' } else { 'Off' }
                    Write-Host ('Auto-open is now {0}.' -f $newState) -ForegroundColor Green
                } catch {
                    Write-Host ('Could not save settings: {0}' -f $_.Exception.Message) -ForegroundColor Red
                }
                Start-Sleep -Seconds 1
            }
            'B' { return }
            default {
                Write-Host 'Please choose 1 or B.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Install-NodeRuntime {
    Write-Host ''
    Write-Host 'Node.js can be installed automatically with winget (Windows Package Manager).' -ForegroundColor Cyan
    $answer = (Read-Host 'Install Node.js now? [Y]es / [N]o').Trim().ToUpperInvariant()
    if ($answer -notin @('', 'Y', 'YES')) {
        return $false
    }

    if (-not (Test-CommandAvailable -Name 'winget')) {
        Write-Host 'winget is not available on this PC.' -ForegroundColor Yellow
        Write-Host 'Install Node.js manually from https://nodejs.org/ (get the LTS installer), then run this again.' -ForegroundColor Yellow
        return $false
    }

    Write-Host 'Installing Node.js LTS. You may see a Windows security (UAC) prompt - choose Yes.' -ForegroundColor DarkGray
    Write-Host ''
    try {
        & winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements 2>&1 |
            ForEach-Object { Write-Host ([string]$_) }
    } catch {
        Write-Host ('Node.js installation failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }

    # winget installs Node to its default location, but the new PATH entry is not visible to
    # this already-running process. Add the default folder so we can use it immediately.
    $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
    if ((Test-Path -LiteralPath (Join-Path $nodeDir 'node.exe')) -and (($env:PATH -split ';') -notcontains $nodeDir)) {
        $env:PATH = $nodeDir + ';' + $env:PATH
    }
    return (Test-CommandAvailable -Name 'node')
}

function Install-FfmpegLocal {
    Write-Host ''
    Write-Host 'FFmpeg can be downloaded (about 80 MB) straight into this folder - no install needed.' -ForegroundColor Cyan
    $answer = (Read-Host 'Download FFmpeg now? [Y]es / [N]o').Trim().ToUpperInvariant()
    if ($answer -notin @('', 'Y', 'YES')) {
        return $false
    }

    $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ('ffmpeg-{0}.zip' -f ([guid]::NewGuid().ToString('N')))
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ffmpeg-{0}' -f ([guid]::NewGuid().ToString('N')))
    $succeeded = $false
    try {
        Write-Host 'Downloading FFmpeg...' -ForegroundColor DarkGray
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $tempZip -UseBasicParsing
        $ProgressPreference = $previousProgress
        Write-Host 'Extracting FFmpeg...' -ForegroundColor DarkGray
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempDir -Force
        foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
            $found = Get-ChildItem -LiteralPath $tempDir -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $found) {
                Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $script:Root $name) -Force
            }
        }
        $succeeded = Test-Path -LiteralPath (Join-Path $script:Root 'ffmpeg.exe')
    } catch {
        Write-Host ('FFmpeg download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    } finally {
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $succeeded
}

function Show-MainMenu {
    Clear-Terminal
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host "          SEEN'S yt-dlp DOWNLOADER" -ForegroundColor White
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host '  1. Download a video, audio, live, or playlist'
    Write-Host '  2. View media library sizes'
    Write-Host '  3. View recorded download history'
    Write-Host '  4. Update downloader engine (yt-dlp)'
    Write-Host '  5. Settings'
    Write-Host '  6. Exit'
    Write-Host ''
}

if (-not (Test-Path -LiteralPath $script:YtDlp -PathType Leaf)) {
    Write-Host ('yt-dlp.exe was not found beside this script: {0}' -f $script:YtDlp) -ForegroundColor Red
    exit 1
}

if ($null -eq $script:JsRuntime) {
    Write-Host 'No JavaScript runtime was found on PATH.' -ForegroundColor Red
    Write-Host 'yt-dlp needs Node.js (or Deno) to extract YouTube and many other sites.' -ForegroundColor Red
    if (Install-NodeRuntime) {
        Update-JsRuntimeState
    }
    if ($null -eq $script:JsRuntime) {
        Write-Host ''
        Write-Host 'A JavaScript runtime is still not available.' -ForegroundColor Red
        Write-Host 'Install Node.js from https://nodejs.org/, reopen a terminal, then run this again.' -ForegroundColor Yellow
        Pause-Terminal
        exit 1
    }
    Write-Host 'Node.js is ready.' -ForegroundColor Green
}

if (-not $script:FfmpegAvailable) {
    Write-Host 'FFmpeg was not found on PATH.' -ForegroundColor Yellow
    Write-Host 'It is needed for MP3/AAC audio and some high-quality video merges.' -ForegroundColor Yellow
    if (Install-FfmpegLocal) {
        $script:FfmpegAvailable = $true
        Write-Host 'FFmpeg is ready.' -ForegroundColor Green
    } else {
        Write-Host 'Continuing without FFmpeg. Audio presets are disabled; video-only still works.' -ForegroundColor Yellow
        Write-Host 'You can also install it yourself from https://ffmpeg.org/ and add it to PATH.' -ForegroundColor Yellow
        Pause-Terminal
    }
}

$script:Settings = Get-DownloaderSettings

while ($true) {
    Show-MainMenu
    $menuChoice = (Read-Host 'Choose an option [1]').Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($menuChoice)) { $menuChoice = '1' }
    switch ($menuChoice) {
        '1' { Start-SmartDownload }
        '2' { Show-LibraryReport }
        '3' { Show-DownloadHistory }
        '4' { Update-DownloaderEngine }
        '5' { Show-SettingsMenu }
        '6' { break }
        'Q' { break }
        default {
            Write-Host 'Please choose 1, 2, 3, 4, 5, or 6.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
    if ($menuChoice -in @('6', 'Q')) { break }
}

Write-Host 'Goodbye.' -ForegroundColor Cyan
