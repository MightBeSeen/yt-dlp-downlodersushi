[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:YtDlp = Join-Path $script:Root 'yt-dlp.exe'
$script:GalleryDl = Join-Path $script:Root 'gallery-dl.exe'

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
$script:DownloadQueue = New-Object System.Collections.Generic.List[object]
$script:ExplorerFocusTypeReady = $false
# Image formats produced by gallery-dl social-post downloads. Kept separate so the
# social engine can target video+image explicitly, and folded into the media set
# below so the library report and completed-file detection see downloaded images.
$script:ImageExtensions = @(
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif'
)
$script:MediaExtensions = @(
    '.mp4', '.mkv', '.webm', '.mov', '.avi', '.flv',
    '.mp3', '.m4a', '.aac', '.wav', '.opus', '.ogg', '.flac'
) + $script:ImageExtensions

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

# Quote arguments using Windows native argv rules (including embedded quotes).
function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Start-MetadataProbe {
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutMilliseconds = 30000)
    $arguments = @($script:YtDlpBaseArguments) + @('--dump-single-json', '--flat-playlist', '--skip-download', '--no-warnings', '--', $Url)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:YtDlp
    $info.Arguments = ($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    # Batch executables are used only by the offline regression fixture.
    if ([IO.Path]::GetExtension($script:YtDlp) -eq '.cmd') {
        $info.FileName = $env:ComSpec
        $info.Arguments = '/d /s /c ""' + $script:YtDlp + '" ' + $info.Arguments + '"'
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try { [void]$process.Start() } catch { $process.Dispose(); throw }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $state = [hashtable]::Synchronized(@{ TimedOut = $false })
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($Process, $Stdout, $Stderr, $State, $Timeout, $Clock)
        if (-not $Process.WaitForExit([Math]::Max(0, $Timeout - [int]$Clock.ElapsedMilliseconds))) {
            $State.TimedOut = $true
            try { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $Process.Id /T /F *> $null } catch {}
        }
        $Process.WaitForExit()
        $output = $Stdout.GetAwaiter().GetResult()
        $errorText = $Stderr.GetAwaiter().GetResult()
        try {
            if ($State.TimedOut) { throw 'Video details timed out after 30 seconds. You can continue with manual choices.' }
            if ($Process.ExitCode -ne 0) { throw $errorText }
            [pscustomobject]@{ Success = $true; Metadata = ($output | ConvertFrom-Json); Error = $null; Cancelled = $false }
        } catch {
            [pscustomobject]@{ Success = $false; Metadata = $null; Error = $_.Exception.Message; Cancelled = $false }
        }
    }).AddArgument($process).AddArgument($stdout).AddArgument($stderr).AddArgument($state).AddArgument($TimeoutMilliseconds).AddArgument($clock)
    return [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Process = $process; Clock = $clock; Disposed = $false }
}

function Test-MetadataProbeCompleted {
    param([Parameter(Mandatory = $true)][object]$ProbeJob)
    return [bool]$ProbeJob.Handle.IsCompleted
}

function Stop-OwnedProcess {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $Process.Kill($true)
        } else {
            & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $Process.Id /T /F *> $null
            if (-not $Process.HasExited) { $Process.Kill() }
        }
    } catch {
        # A short-lived probe can exit between HasExited and the termination call.
        if (-not $Process.HasExited) { throw }
    }
}

function Stop-MetadataProbe {
    param([Parameter(Mandatory = $true)][object]$ProbeJob)
    if ($ProbeJob.Disposed) { return }
    try {
        Stop-OwnedProcess -Process $ProbeJob.Process
        [void]$ProbeJob.PowerShell.EndInvoke($ProbeJob.Handle)
    } finally {
        $ProbeJob.PowerShell.Dispose()
        $ProbeJob.Process.Dispose()
        $ProbeJob.Disposed = $true
    }
}

function Complete-MetadataProbe {
    param([Parameter(Mandatory = $true)][object]$ProbeJob)
    $lastSecond = -1
    while (-not (Test-MetadataProbeCompleted $ProbeJob)) {
        $second = [int][Math]::Floor($ProbeJob.Clock.Elapsed.TotalSeconds)
        if ($second -ne $lastSecond) {
            Write-Host ('Fetching video details: {0}s / 30s. Esc or C cancels.' -f $second) -ForegroundColor DarkGray
            $lastSecond = $second
        }
        if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -in @('Escape', 'C')) {
                Stop-MetadataProbe $ProbeJob
                return [pscustomobject]@{ Success = $false; Metadata = $null; Error = ''; Cancelled = $true }
            }
        }
        Start-Sleep -Milliseconds 50
    }
    try { return ($ProbeJob.PowerShell.EndInvoke($ProbeJob.Handle) | Select-Object -First 1) }
    finally {
        $ProbeJob.PowerShell.Dispose()
        $ProbeJob.Process.Dispose()
        $ProbeJob.Disposed = $true
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
        [string]$DefaultValue = '',
        [switch]$AllowBack,
        [scriptblock]$RedrawHeader
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

    for ($i = 0; $i -lt $items.Count; $i++) {
        if (-not $items[$i].Disabled -and $items[$i].Value -eq $DefaultValue) { $defaultIndex = $i; break }
    }
    $canDrawArrows = $false
    try { $canDrawArrows = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and [Console]::BufferWidth -ge 60 -and [Console]::WindowHeight -ge ($items.Count + $Notes.Count + 8) } catch { $canDrawArrows = $false }

    if (-not $canDrawArrows) {
        return (Read-MenuChoiceText -Title $Title -Items $items -Notes $Notes -AllowBack:$AllowBack -DefaultIndex $defaultIndex)
    }

    return (Read-MenuChoiceArrows -Title $Title -Items $items -Notes $Notes -AllowBack:$AllowBack -DefaultIndex $defaultIndex -RedrawHeader $RedrawHeader)
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
        [int]$DefaultIndex,
        [scriptblock]$RedrawHeader
    )

    $selected = $DefaultIndex
    $footer = if ($AllowBack) {
        [char]0x2191 + [char]0x2193 + ' move  ' + [char]0x00B7 + '  Enter select  ' + [char]0x00B7 + '  ' + [char]0x2190 + ' Back  ' + [char]0x00B7 + '  Esc cancel'
    } else {
        [char]0x2191 + [char]0x2193 + ' move  ' + [char]0x00B7 + '  Enter select  ' + [char]0x00B7 + '  Esc cancel'
    }

    $startTop = -1
    $lastWidth = 0
    $lastHeight = 0
    $frameHeight = $Items.Count + $Notes.Count + 5
    $foreground = [Console]::ForegroundColor
    $background = [Console]::BackgroundColor
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
            $width = [Console]::BufferWidth
            $height = [Console]::BufferHeight
            if ($width -lt 60 -or [Console]::WindowHeight -lt ($frameHeight + 1)) {
                [Console]::ForegroundColor = $foreground
                [Console]::BackgroundColor = $background
                [Console]::Clear()
                if ($null -ne $RedrawHeader) { & $RedrawHeader }
                return (Read-MenuChoiceText -Title $Title -Items $Items -Notes $Notes -AllowBack:$AllowBack -DefaultIndex $selected)
            }
            if ($startTop -lt 0 -or $width -ne $lastWidth -or $height -ne $lastHeight) {
                if ($startTop -ge 0) {
                    # Resize can reflow the old frame. Clear it before reserving a new one.
                    [Console]::Clear()
                    if ($null -ne $RedrawHeader) { & $RedrawHeader }
                }
                # Reserve first, then measure: writing newlines can scroll the buffer.
                for ($line = 0; $line -lt $frameHeight; $line++) { [Console]::WriteLine() }
                $startTop = [Console]::CursorTop - $frameHeight
                $lastWidth = $width
                $lastHeight = $height
            }
            $rows = @(
                [pscustomobject]@{ Text = ''; Color = $foreground; Highlight = $false }
                [pscustomobject]@{ Text = "  $Title"; Color = [ConsoleColor]::Cyan; Highlight = $false }
            )
            foreach ($note in $Notes) { $rows += [pscustomobject]@{ Text = "    $note"; Color = [ConsoleColor]::Yellow; Highlight = $false } }
            $rows += [pscustomobject]@{ Text = ''; Color = $foreground; Highlight = $false }
            for ($idx = 0; $idx -lt $Items.Count; $idx++) {
                $item = $Items[$idx]
                $marker = if ($idx -eq $selected) { '> ' } else { '  ' }
                $rows += [pscustomobject]@{
                    Text = ("{0}{1}  {2}" -f $marker, $item.Key, $item.Label)
                    Color = $(if ($item.Disabled) { [ConsoleColor]::DarkGray } elseif ($idx -eq $selected) { [ConsoleColor]::Black } else { $foreground })
                    Highlight = ($idx -eq $selected -and -not $item.Disabled)
                }
            }
            $rows += [pscustomobject]@{ Text = ''; Color = $foreground; Highlight = $false }
            $rows += [pscustomobject]@{ Text = "  $footer"; Color = [ConsoleColor]::DarkGray; Highlight = $false }
            for ($line = 0; $line -lt $rows.Count; $line++) {
                $row = $rows[$line]
                $text = [regex]::Replace([string]$row.Text, '[\x00-\x1f\x7f]', ' ')
                $elements = [Globalization.StringInfo]::GetTextElementEnumerator($text)
                $display = New-Object Text.StringBuilder
                $cells = 0
                while ($elements.MoveNext()) {
                    $element = $elements.GetTextElement()
                    # Reserve conservatively for non-ASCII text (wide glyphs/emoji).
                    # Clear the row separately so this estimate cannot leave stale text.
                    $cost = if ($element -cmatch '[^\x20-\x7e]') { 2 * $element.Length } else { $element.Length }
                    if ($cells + $cost -gt ($width - 4)) { [void]$display.Append('...'); break }
                    [void]$display.Append($element)
                    $cells += $cost
                }
                [Console]::SetCursorPosition(0, $startTop + $line)
                [Console]::ForegroundColor = $row.Color
                [Console]::BackgroundColor = $(if ($row.Highlight) { [ConsoleColor]::Cyan } else { $background })
                [Console]::Write((' ' * ($width - 1)))
                [Console]::SetCursorPosition(0, $startTop + $line)
                [Console]::Write($display.ToString())
            }
            [Console]::ForegroundColor = $foreground
            [Console]::BackgroundColor = $background
            [Console]::SetCursorPosition(0, $startTop + $frameHeight)
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
        [Console]::ForegroundColor = $foreground
        [Console]::BackgroundColor = $background
        try { [Console]::CursorVisible = $cursorWasVisible } catch {}
    }
}

function Read-FormatPreset {
    param([string]$DefaultValue = '')
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
    return (Read-MenuChoice -Title 'Choose a format' -Options $options -Notes $notes -DefaultValue $DefaultValue)
}

function Read-VideoQuality {
    param([string]$DefaultValue = '')
    $options = @(
        [pscustomobject]@{ Key = '1'; Label = 'Best available (recommended)'; Value = 'best' }
        [pscustomobject]@{ Key = '2'; Label = 'Up to 1080p'; Value = '1080' }
        [pscustomobject]@{ Key = '3'; Label = 'Up to 720p'; Value = '720' }
    )
    return (Read-MenuChoice -Title 'Choose a maximum video quality' -Options $options -AllowBack -DefaultValue $DefaultValue)
}

function Read-LiveMode {
    param([string]$DefaultValue = '', [switch]$Manual)
    if ($Manual) {
        return (Read-MenuChoice -Title 'Livestream handling' -Options @(
            [pscustomobject]@{ Key = 'N'; Label = 'Normal download'; Value = 'Normal' }
            [pscustomobject]@{ Key = 'Y'; Label = 'Live from the start'; Value = 'Force' }
        ) -AllowBack -DefaultValue $DefaultValue)
    }
    $options = @(
        [pscustomobject]@{ Key = 'A'; Label = 'Auto-detect an active live (recommended)'; Value = 'Auto' }
        [pscustomobject]@{ Key = 'Y'; Label = 'Force download from the start'; Value = 'Force' }
        [pscustomobject]@{ Key = 'N'; Label = 'Normal download without live-from-start'; Value = 'Normal' }
    )
    return (Read-MenuChoice -Title 'Livestream handling' -Options $options -AllowBack -DefaultValue $DefaultValue)
}

function Read-PlaylistMode {
    param(
        [string]$DefaultValue = '',
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
        @('Choose the scope for this link.')
    }
    $options = @(
        [pscustomobject]@{ Key = '1'; Label = 'Single/current video only'; Value = 'Single' }
        [pscustomobject]@{ Key = '2'; Label = 'Full playlist'; Value = 'Playlist' }
    )
    return (Read-MenuChoice -Title 'Playlist handling' -Options $options -Notes $notes -AllowBack -DefaultValue $DefaultValue)
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
            return [pscustomobject]@{ Cancelled = $false; Enabled = $true; Description = 'Auto (live detected)' }
        }
        return [pscustomobject]@{ Cancelled = $false; Enabled = $false; Description = 'Auto (not live)' }
    }

    $choice = Read-MenuChoice -Title 'Livestream handling' -Notes @('Details are unavailable. Choose manually.') -Options @(
        [pscustomobject]@{ Key = 'N'; Label = 'Normal download'; Value = 'Normal' }
        [pscustomobject]@{ Key = 'L'; Label = 'Live from the start'; Value = 'Force' }
    )
    if ($null -eq $choice) { return [pscustomobject]@{ Cancelled = $true; Enabled = $false; Description = 'Cancelled' } }
    return (Resolve-LiveDecision -RequestedMode $choice -ProbeSucceeded $false -Metadata $null)
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

# Does an open Explorer window's folder path point at the same folder we want to open?
# Windows paths are case-insensitive and may carry a trailing slash; normalising both is
# the only fiddly bit, so it lives here as a pure, unit-testable function.
function Test-ExplorerPathMatch {
    param(
        [string]$WindowPath,
        [string]$TargetFolder
    )

    if ([string]::IsNullOrWhiteSpace($WindowPath) -or [string]::IsNullOrWhiteSpace($TargetFolder)) {
        return $false
    }
    $a = $WindowPath.TrimEnd('\', '/')
    $b = $TargetFolder.TrimEnd('\', '/')
    return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
}

# If an Explorer window is already showing $TargetFolder, bring it to the front and return
# $true so the caller skips spawning a duplicate. Returns $false when no match is found.
# Any COM/interop failure degrades to $false so we fall back to opening a fresh window.
function Show-ExistingExplorerWindow {
    param(
        [Parameter(Mandatory = $true)][string]$TargetFolder
    )

    if (-not $script:ExplorerFocusTypeReady) {
        try {
            Add-Type -Namespace 'SeenDownloader' -Name 'NativeWindow' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        } catch {
            # Type may already be loaded from a previous call in this session; that's fine.
        }
        $script:ExplorerFocusTypeReady = $true
    }

    $shell = $null
    $windows = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()
        foreach ($w in $windows) {
            $windowPath = $null
            try {
                # File-browser windows expose their on-disk folder here; IE/Edge legacy
                # windows do not, so this throws and we skip them.
                $windowPath = $w.Document.Folder.Self.Path
            } catch {
                $windowPath = $null
            }

            if (Test-ExplorerPathMatch -WindowPath $windowPath -TargetFolder $TargetFolder) {
                $hwnd = [System.IntPtr]$w.HWND
                # SW_RESTORE (9) un-minimises the window before we pull it to the front.
                [void][SeenDownloader.NativeWindow]::ShowWindow($hwnd, 9)
                [void][SeenDownloader.NativeWindow]::SetForegroundWindow($hwnd)
                return $true
            }
        }
    } catch {
        return $false
    } finally {
        if ($null -ne $windows) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($windows) }
        if ($null -ne $shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    return $false
}

function Open-DownloadLocation {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$TargetFolder
    )

    try {
        # If a window for this folder is already open, focus it instead of spawning a duplicate.
        if (Show-ExistingExplorerWindow -TargetFolder $TargetFolder) { return }
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

function Show-DownloadReview {
    param([Parameter(Mandatory = $true)][object]$Request)
    Clear-Terminal
    Write-Heading -Text 'Review download'
    if ((Get-PropertyValue -InputObject $Request -Name 'Mode') -eq 'SocialPost') {
        Write-Host ('Platform: {0}' -f (Get-PlatformDisplayName -Platform $Request.Platform))
        Write-Host ('URL: {0}' -f $Request.Url)
        $scopeLabel = if (Get-PropertyValue -InputObject $Request -Name 'IncludeManifest') { 'Entire social post (include manifest)' } else { 'Media only (photos and videos)' }
        Write-Host ('Mode: {0}, source quality' -f $scopeLabel)
        $accountName = if ($null -ne $Request.Account) { $Request.Account.Name } else { 'Anonymous' }
        Write-Host ('Account: {0}' -f $accountName)
        Write-Host ('Destination: {0}' -f (Get-RelativeDisplayPath -Path $Request.TargetFolder))
        return
    }
    if ($Request.Title) { Write-Host $Request.Title }
    Write-Host ('URL: {0}' -f $Request.Url)
    Write-Host ('Format: {0}' -f $Request.Preset.ToUpperInvariant())
    $qualityDescription = if ($Request.Preset -in @('mp3','aac')) { 'n/a (audio)' } elseif ($Request.Quality -eq 'best') { 'Best available' } else { 'Up to {0}p' -f $Request.Quality }
    Write-Host ('Maximum quality: {0}' -f $qualityDescription)
    Write-Host ('Live: {0}' -f $Request.LiveDecision.Description)
    Write-Host ('Scope: {0}' -f $(if ($Request.PlaylistMode -eq 'Playlist') { 'Full playlist' } else { 'Single video' }))
    Write-Host ('Destination: {0}' -f $Request.TargetFolder)
}

# The set of functional download modes. Phase 2 appends 'SocialPost' once the
# gallery-dl engine exists; until then only video/audio is offered.
function Get-AvailableDownloadModes {
    return @('VideoAudio', 'SocialPost')
}

# Last mode chosen this session, defaulting to video/audio. Read defensively so a
# fresh process (or a function-only test harness) never trips StrictMode.
function Get-LastDownloadMode {
    if (Test-Path variable:script:LastMode) { return $script:LastMode }
    return 'VideoAudio'
}

# Ask for the download mode. With a single available mode this returns it without
# prompting, so the existing flow is unchanged until more modes are registered.
# Returns $null when the user backs out.
function Read-DownloadMode {
    param([string]$DefaultValue = 'VideoAudio', [string]$Url)
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        if ((Get-UrlPlatform -Url $Url) -in (Get-SocialPostPlatforms)) { return 'SocialPost' }
        return 'VideoAudio'
    }
    $modes = @(Get-AvailableDownloadModes)
    if ($modes.Count -le 1) { return $modes[0] }
    $labels = @{ VideoAudio = 'Video / audio'; SocialPost = 'Entire social post' }
    $default = if ($modes -contains $DefaultValue) { $DefaultValue } else { $modes[0] }
    $options = foreach ($m in $modes) {
        [pscustomobject]@{ Key = [string]([array]::IndexOf($modes, $m) + 1); Label = $labels[$m]; Value = $m }
    }
    return Read-MenuChoice -Title 'What do you want to download?' -Options $options -DefaultValue $default
}

# Account profiles matching a URL's platform. Anonymous is offered whenever the
# URL's platform has no configured profile.
function Get-AccountProfilesForUrl {
    param([string]$Url)
    $platform = Get-UrlPlatform -Url $Url
    if ([string]::IsNullOrEmpty($platform)) { return @() }
    return @(Read-AccountProfiles | Where-Object { $_.Platform -eq $platform })
}

# Choose an account profile for the request. Returns $null for Anonymous, which is
# the only option until profiles exist. Anonymous is always the default.
function Read-AccountProfile {
    param([string]$Url)
    $profiles = @(Get-AccountProfilesForUrl -Url $Url)
    if ($profiles.Count -eq 0) { return $null }
    $options = @([pscustomobject]@{ Key = '1'; Label = 'Anonymous'; Value = $null })
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $options += [pscustomobject]@{ Key = [string]($i + 2); Label = $profiles[$i].Name; Value = $profiles[$i] }
    }
    return Read-MenuChoice -Title 'Account' -Options $options -DefaultValue $null
}

function New-DownloadRequest {
    param([switch]$ForQueue)
    Clear-Terminal
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

    # Decide mode and authentication before any dependency check or probe, so the
    # right dependencies are validated and no speculative request is issued for
    # social/authenticated downloads.
    $mode = Read-DownloadMode -DefaultValue (Get-LastDownloadMode) -Url $url
    if ($null -eq $mode) { return }
    $script:LastMode = $mode

    $account = Read-AccountProfile -Url $url  # $null = Anonymous

    if (-not (Resolve-RequestDependencies -Mode $mode)) { return }

    # A platform hold blocks work across both engines and every account.
    $urlPlatform = Get-UrlPlatform -Url $url
    if (-not [string]::IsNullOrEmpty($urlPlatform) -and (Test-PlatformHeld -Platform $urlPlatform)) {
        $hold = Get-PlatformHold -Platform $urlPlatform
        Write-Host ('{0} is on hold: {1}' -f (Get-PlatformDisplayName $urlPlatform), (Get-PropertyValue -InputObject $hold -Name 'reason')) -ForegroundColor Red
        Write-Host 'Release it from Settings > Review blocked platforms before downloading.' -ForegroundColor Yellow
        Pause-Terminal
        return
    }

    # Entire-post mode skips the yt-dlp question flow entirely: it offers no
    # resolution/audio/playlist choices, so it goes straight to review.
    if ($mode -eq 'SocialPost') {
        $request = New-SocialPostRequest -Url $url -Account $account
        if ($null -eq $request) { return }
        $scope = Read-MenuChoice -Title 'What should be saved?' -Options @(
            [pscustomobject]@{ Key = '1'; Label = 'Media only (photos and videos)'; Value = 'Media' }
            [pscustomobject]@{ Key = '2'; Label = 'Entire social post (include manifest)'; Value = 'Manifest' }
        ) -DefaultValue 'Media'
        if ($null -eq $scope) { return }
        $request.IncludeManifest = ($scope -eq 'Manifest')
        Show-DownloadReview -Request $request
        $review = Read-MenuChoice -Title 'Ready?' -RedrawHeader { Show-DownloadReview -Request $request } -Options @(
            [pscustomobject]@{ Key = '1'; Label = $(if ($ForQueue) { 'Add to queue' } else { 'Start download' }); Value = 'Start' }
            [pscustomobject]@{ Key = '2'; Label = 'Cancel'; Value = 'Cancel' }
        )
        if ($review -ne 'Start') { return }
        return $request
    }

    # Optional metadata must never hold up the questions or confirmation, and is only
    # gathered for anonymous video/audio requests: social/entire-post extraction and
    # any authenticated request must not fire a pre-confirmation probe.
    $probeJob = $null
    if ($mode -eq 'VideoAudio' -and $null -eq $account) {
        try { $probeJob = Start-MetadataProbe -Url $url } catch {}
    }
    $probe = $null
    $metadataFrozen = $false
    $clipTitle = ''

  try {
    # The questions run as a small step machine so a mis-click is recoverable: each
    # prompt offers "B. Back", which steps back exactly one question while keeping the
    # earlier answers intact, instead of only cancelling out to the main menu.
    # Steps: 0 Format, 1 Quality (video only), 2 Live mode, 3 Playlist, 4 Review.
    $preset = $null
    $quality = 'best'
    $requestedLiveMode = $null
    $playlistMode = $null
    $step = 0
    while ($step -le 4) {
        # Pull the probe result the instant it is ready, without ever blocking, so the clip
        # title fills into the header on the next repaint.
        if (-not $metadataFrozen -and $null -eq $probe -and $null -ne $probeJob -and (Test-MetadataProbeCompleted -ProbeJob $probeJob)) {
            $probe = Complete-MetadataProbe -ProbeJob $probeJob
            if ($probe.Success) {
                $clipTitle = [string](Get-PropertyValue -InputObject $probe.Metadata -Name 'title')
            }
        }

        # Show only choices confirmed by an *earlier* step; the field being asked now
        # (and any later ones) stays blank, so stepping Back visibly clears it.
        $presetDisplay  = if ($step -gt 0) { [string]$preset } else { '' }
        $qualityDisplay = if ($step -gt 1) { if ($preset -in @('mp4', 'mkv')) { [string]$quality } else { 'n/a' } } else { '' }
        $liveDisplay    = if ($step -gt 2) { [string]$requestedLiveMode } else { '' }
        if ($step -lt 4) {
            Show-DownloadHeader -Title $clipTitle -Url $url `
                -Preset $presetDisplay `
                -Quality $qualityDisplay `
                -Live $liveDisplay `
                -Playlist ''
        }
        switch ($step) {
            0 {
                $preset = Read-FormatPreset -DefaultValue $preset
                if ($null -eq $preset) { return }  # Back on the first question cancels.
                $step = 1
            }
            1 {
                if ($preset -in @('mp4', 'mkv')) {
                    $choice = Read-VideoQuality -DefaultValue $quality
                    if ($null -eq $choice) { return }
                    if ($choice -eq 'BACK') { $step = 0; break }
                    $quality = $choice
                } else {
                    $quality = 'best'  # Audio presets have no quality step.
                }
                $step = 2
            }
            2 {
                $choice = Read-LiveMode -DefaultValue $requestedLiveMode -Manual:($null -eq $probe -or -not $probe.Success)
                if ($null -eq $choice) { return }
                if ($choice -eq 'BACK') {
                    # Back skips the quality step for audio presets.
                    $step = if ($preset -in @('mp4', 'mkv')) { 1 } else { 0 }
                    break
                }
                $requestedLiveMode = $choice
                $step = 3
            }
            3 {
                # Freeze the metadata snapshot before asking explicit scope/live choices.
                # Late results must not reinterpret choices when returning from review.
                $metadataFrozen = $true
                if ($null -eq $probe) {
                    if ($null -ne $probeJob) { Stop-MetadataProbe -ProbeJob $probeJob; $probeJob = $null }
                    $probe = [pscustomobject]@{ Success = $false; Metadata = $null; Cancelled = $false }
                }

                if ($probe.Cancelled) { return }

                $isPlaylist = $false
                if ($probe.Success) {
                    $isPlaylist = Test-MetadataIsPlaylist -Metadata $probe.Metadata
                }
                $choice = Read-PlaylistMode -DefaultValue $playlistMode -ProbeSucceeded $probe.Success -IsPlaylist $isPlaylist -Url $url
                if ($null -eq $choice) { return }
                if ($choice -eq 'BACK') { $step = 2; break }
                $playlistMode = $choice
                $step = 4
            }
            4 {
                $liveDecision = Resolve-LiveDecision -RequestedMode $requestedLiveMode -ProbeSucceeded $probe.Success -Metadata $probe.Metadata
                if ($liveDecision.Cancelled) { return }
                if (-not $probe.Success -and $requestedLiveMode -eq 'Auto') {
                    $requestedLiveMode = if ($liveDecision.Enabled) { 'Force' } else { 'Normal' }
                }
                $startedAt = Get-Date
                $targetFolder = Join-Path $script:DownloadsRoot $startedAt.ToString('yyyy-MM-dd')
                $request = [pscustomobject]@{
                    Url = $url; Title = $clipTitle; Preset = $preset; Quality = $quality
                    LiveDecision = $liveDecision; PlaylistMode = $playlistMode
                    TargetFolder = $targetFolder; Status = 'Pending'
                    Mode = $mode; Account = $account
                }
                Show-DownloadReview -Request $request
                $review = Read-MenuChoice -Title 'Ready?' -RedrawHeader { Show-DownloadReview -Request $request } -Options @(
                    [pscustomobject]@{ Key = '1'; Label = $(if ($ForQueue) { 'Add to queue' } else { 'Start download' }); Value = 'Start' }
                    [pscustomobject]@{ Key = '2'; Label = 'Change choices'; Value = 'Change' }
                )
                if ($null -eq $review) { return }
                if ($review -eq 'Change') { $step = 0 } else { $step = 5 }
            }
        }
    }
  } finally {
    # If the user cancelled before the playlist step ever consumed the probe, tear down the
    # still-running background runspace so it does not leak.
    if ($null -ne $probeJob -and -not $metadataFrozen -and $null -eq $probe) {
        try { Stop-MetadataProbe -ProbeJob $probeJob } catch {}
    }
  }

    return $request
}

function Start-SmartDownload {
    $request = New-DownloadRequest
    if ($null -ne $request) { [void](Invoke-DownloadRequest -Request $request) }
}

function Invoke-MediaProcess {
    param(
        [string[]]$Arguments,
        [scriptblock]$OnOutput,
        # Defaults to yt-dlp so existing callers are unchanged; other engines
        # (gallery-dl) pass their own executable path. Evaluated at call time.
        [string]$ExecutablePath = $script:YtDlp,
        [string]$WorkingDirectory
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $ExecutablePath
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    if ([IO.Path]::GetExtension($ExecutablePath) -eq '.cmd') {
        $info.FileName = $env:ComSpec
        $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + $info.Arguments + '"'
    }
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
        $info.WorkingDirectory = $WorkingDirectory
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $interrupted = $false
    $started = $false
    $restoreControlC = $false
    $previousControlC = $false
    try {
        # Read Ctrl+C as input so cancellation does not stop the PowerShell runspace
        # itself. That leaves the session queue available after stopping yt-dlp.
        if (-not [Console]::IsInputRedirected) {
            $previousControlC = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
            $restoreControlC = $true
        }
        $started = $process.Start()
        $outputTask = $process.StandardOutput.ReadLineAsync()
        $errorTask = $process.StandardError.ReadLineAsync()
        while ($null -ne $outputTask -or $null -ne $errorTask -or -not $process.HasExited) {
            if ($restoreControlC -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ([int]$key.KeyChar -eq 3 -or ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))) {
                    $interrupted = $true
                    Stop-OwnedProcess -Process $process
                }
            }
            $received = $false
            if ($null -ne $outputTask -and $outputTask.IsCompleted) {
                $line = $outputTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $outputTask = $null } else {
                    . $OnOutput $line
                    $outputTask = $process.StandardOutput.ReadLineAsync()
                }
                $received = $true
            }
            if ($null -ne $errorTask -and $errorTask.IsCompleted) {
                $line = $errorTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $errorTask = $null } else {
                    . $OnOutput $line
                    $errorTask = $process.StandardError.ReadLineAsync()
                }
                $received = $true
            }
            if (-not $received) { Start-Sleep -Milliseconds 20 }
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Interrupted = $interrupted }
    } finally {
        if ($restoreControlC) { [Console]::TreatControlCAsInput = $previousControlC }
        if ($started -and -not $process.HasExited) {
            Stop-OwnedProcess -Process $process
        }
        $process.Dispose()
    }
}

# Dispatch a request to the engine for its mode. Requests without a Mode (legacy
# queue items, older tests) are treated as video/audio.
function Invoke-DownloadRequest {
    param([Parameter(Mandatory = $true)][object]$Request, [switch]$Queued, [string]$QueueLabel = '')
    $mode = Get-PropertyValue -InputObject $Request -Name 'Mode'
    if ($mode -eq 'SocialPost') {
        return (Invoke-SocialPostRequest -Request $Request -Queued:$Queued -QueueLabel $QueueLabel)
    }
    return (Invoke-YtDlpRequest -Request $Request -Queued:$Queued -QueueLabel $QueueLabel)
}

function Invoke-YtDlpRequest {
    param([Parameter(Mandatory = $true)][object]$Request, [switch]$Queued, [string]$QueueLabel = '')
    $url = $Request.Url
    $preset = $Request.Preset
    $quality = $Request.Quality
    $liveDecision = $Request.LiveDecision
    $playlistMode = $Request.PlaylistMode
    $targetFolder = $Request.TargetFolder
    $startedAt = Get-Date
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

    Clear-Terminal
    Write-Heading -Text $(if ($QueueLabel) { "Downloading $QueueLabel" } else { 'Downloading' })
    Write-Host $(if ($Request.Title) { $Request.Title } else { $url })
    Write-Host ('Format: {0} | Quality: {1} | Live: {2} | Playlist: {3}' -f $preset.ToUpperInvariant(), $qualityLabel, $liveDecision.Description, $playlistMode)
    Write-Host ('Destination: {0}' -f (Get-RelativeDisplayPath -Path $targetFolder))
    Write-Host 'Press Ctrl+C once if you need to interrupt the download.' -ForegroundColor DarkGray
    Write-Host ''

    $reportedPaths = New-Object System.Collections.Generic.List[string]
    $interrupted = $false
    $exitCode = 1
    # The live progress readout is pinned to the bottom-most line: it is drawn in place
    # with a carriage return, and whenever a content line (Saved:, a warning, etc.) arrives
    # the bar is erased, the content is printed - scrolling everything up - and the bar is
    # redrawn below it. For a playlist yt-dlp also prints "Downloading item N of M"; that
    # counter is folded into the bar instead of scrolling past.
    $progressState = @{ Active = $false; Width = 0; Last = $null; Position = $null }

    # Render the pinned bar in place, returning $true when something was actually drawn.
    # Grows $progressState.Width to the widest bar seen so the trailing padding fully overwrites
    # a previously longer line. Uses only that tracked width (never [Console]::BufferWidth) so
    # it stays safe under a redirected console in tests. Nothing is drawn until the first
    # progress line has arrived, so a leading "Downloading item" counter simply waits.
    $writePinnedBar = {
        if ($null -eq $progressState.Last) { return $false }
        $barText = if ([string]::IsNullOrEmpty($progressState.Position)) {
            $progressState.Last
        } else {
            '{0} | {1}' -f $progressState.Position, $progressState.Last
        }
        $progressState.Width = [Math]::Max($progressState.Width, $barText.Length)
        $padding = ' ' * ($progressState.Width - $barText.Length)
        [Console]::Write(("`r{0}{1}" -f $barText, $padding))
        return $true
    }

    # Scrolling content shares the SAME channel as the bar: everything goes through
    # [Console] rather than Write-Host. Mixing Write-Host (the PowerShell host channel)
    # with [Console]::Write (raw stdout) desyncs in a real terminal - the two writers
    # buffer independently, so the carriage-return redraws land on the wrong rows and the
    # bar stacks instead of pinning. One writer keeps the cursor coherent everywhere.
    $writeContentLine = {
        param([string]$Text, [object]$Color)
        $previous = $null
        if ($null -ne $Color) {
            try { $previous = [Console]::ForegroundColor; [Console]::ForegroundColor = [System.ConsoleColor]$Color } catch { $previous = $null }
        }
        [Console]::WriteLine($Text)
        if ($null -ne $previous) {
            try { [Console]::ForegroundColor = $previous } catch {}
        }
    }

    try {
        $processResult = Invoke-MediaProcess -Arguments $arguments -OnOutput {
            param([string]$line)

            if ($line -match '^\[download\]\s+Downloading item\s+(\d+)\s+of\s+(\d+)') {
                # Playlist counter: fold it into the pinned bar rather than scrolling it.
                $progressState.Position = 'Item {0}/{1}' -f $matches[1], $matches[2]
                if (& $writePinnedBar) { $progressState.Active = $true }
                return
            }

            if ($line -match '^\[download\]\s+\d+(?:\.\d+)?%') {
                $progressState.Last = $line
                if (& $writePinnedBar) { $progressState.Active = $true }
                return
            }

            # Any other line is scrolling content. Erase the pinned bar, print the content so
            # it scrolls up, then redraw the bar underneath so it stays at the bottom.
            if ($progressState.Active) {
                [Console]::Write(("`r{0}`r" -f (' ' * $progressState.Width)))
            }

            if ($line.StartsWith($script:OutputMarker, [System.StringComparison]::Ordinal)) {
                $reportedPaths.Add($line.Substring($script:OutputMarker.Length))
                & $writeContentLine ('Saved: {0}' -f $line.Substring($script:OutputMarker.Length)) ([System.ConsoleColor]::Green)
            } else {
                & $writeContentLine $line $null
            }

            if ($progressState.Active) {
                [void](& $writePinnedBar)
            }
        }
        $exitCode = $processResult.ExitCode
        $interrupted = $processResult.Interrupted
        if ($exitCode -in @(130, -1073741510)) { $interrupted = $true }
    } catch [System.Management.Automation.PipelineStoppedException] {
        $interrupted = $true
        $exitCode = 130
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $exitCode = 1
    } finally {
        if ($progressState.Active) {
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

    if (-not $Queued) {
        Write-Heading -Text 'Download result'
        if ($exitCode -eq 0) {
            Write-Host 'yt-dlp finished successfully.' -ForegroundColor Green
        } elseif ($interrupted) {
            Write-Host 'The download was interrupted. Any .part file is kept so yt-dlp can resume it later.' -ForegroundColor Yellow
        } else {
            Write-Host ('yt-dlp failed with exit code {0}.' -f $exitCode) -ForegroundColor Red
        }
        Show-FileList -Files $completedFiles -IncludeTotal
    }
    if ($exitCode -eq 0 -and $script:Settings.OpenFolderAfterDownload -and $completedFiles.Count -gt 0) {
        Open-DownloadLocation -Files $completedFiles -TargetFolder $targetFolder
    }
    if (-not $Queued) { Pause-Terminal }
    return [pscustomobject]@{
        Status = $(if ($interrupted) { 'Interrupted' } elseif ($exitCode -eq 0) { 'Completed' } else { 'Failed' })
        ExitCode = $exitCode
    }
}

# The full queue outcome model. yt-dlp only produces the original subset today;
# Partial and Blocked are reserved for the gallery-dl engine and platform holds.
# Exposed as functions (not script bootstrap vars) so every function-loaded test
# harness sees them without replicating startup state.
function Get-QueueStates {
    return @('Pending', 'Downloading', 'Completed', 'Partial', 'Failed', 'Interrupted', 'Blocked')
}

# "Retry failed / interrupted" reruns these; Blocked is never cleared by a retry.
function Get-QueueRetryStates {
    return @('Partial', 'Failed', 'Interrupted')
}

# Delay (seconds) inserted between consecutive queued source-URL downloads. A
# product default, not a safety threshold; overridable in tests.
function Get-QueueItemDelaySeconds {
    return (Get-Random -Minimum 5 -Maximum 11)
}

function Start-DownloadQueue {
    param([switch]$RetryFailed)
    if ($RetryFailed) {
        $retryStates = Get-QueueRetryStates
        foreach ($item in $script:DownloadQueue) {
            # Blocked items are held deliberately and must never be reset by a retry.
            if ($item.Status -in $retryStates) { $item.Status = 'Pending' }
        }
    }
    $pending = @($script:DownloadQueue.ToArray() | Where-Object { $_.Status -eq 'Pending' })
    if ($pending.Count -eq 0) { return }

    # Validate each mode present once, up front. Video/audio uses the original
    # combined check; entire-post additionally needs gallery-dl.
    $modes = @($pending | ForEach-Object { $m = Get-PropertyValue -InputObject $_ -Name 'Mode'; if ([string]::IsNullOrEmpty($m)) { 'VideoAudio' } else { $m } } | Sort-Object -Unique)
    if ($modes -contains 'VideoAudio' -and -not (Initialize-DownloadDependencies)) { return }
    if ($modes -contains 'SocialPost' -and -not (Resolve-RequestDependencies -Mode 'SocialPost')) { return }

    $position = 0
    $ranAny = $false
    foreach ($item in $pending) {
        $position++

        # Re-check the platform hold immediately before execution.
        $platform = Get-PropertyValue -InputObject $item -Name 'Platform'
        if ([string]::IsNullOrEmpty($platform)) { $platform = Get-UrlPlatform -Url $item.Url }
        if (-not [string]::IsNullOrEmpty($platform) -and (Test-PlatformHeld -Platform $platform)) {
            $item.Status = 'Blocked'
            continue
        }

        # Pace between actual source-URL downloads, never before the first one.
        if ($ranAny) { Start-Sleep -Seconds (Get-QueueItemDelaySeconds) }

        $item.Status = 'Downloading'
        try {
            $result = Invoke-DownloadRequest -Request $item -Queued -QueueLabel "$position/$($pending.Count)"
            $item.Status = $result.Status
        } catch [System.Management.Automation.PipelineStoppedException] {
            $item.Status = 'Interrupted'
        } catch {
            $item.Status = 'Failed'
            Write-Host $_.Exception.Message -ForegroundColor Red
        } finally {
            if ($item.Status -eq 'Downloading') { $item.Status = 'Interrupted' }
        }
        $ranAny = $true
        if ($item.Status -eq 'Interrupted') { break }
    }
    Clear-Terminal
    Write-Heading -Text 'Queue result'
    $counts = @($script:DownloadQueue.ToArray() | Group-Object Status | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count })
    Write-Host ($counts -join ' | ')
    [void](Read-Host 'Enter to return to queue')
}

function Show-QueueItems {
    $pageIndex = 0
    while ($true) {
        Clear-Terminal
        Write-Heading -Text 'Queued downloads'
        if ($script:DownloadQueue.Count -eq 0) {
            Write-Host 'Queue is empty.'
            [void](Read-Host 'Enter to return')
            return
        }
        $page = Get-PageInfo -Items $script:DownloadQueue.ToArray() -PageIndex $pageIndex -PageSize 5
        $pageIndex = $page.PageIndex
        $options = @()
        for ($i = 0; $i -lt $page.Items.Count; $i++) {
            $item = $page.Items[$i]
            $name = if ($item.Title) { $item.Title } else { $item.Url }
            $options += [pscustomobject]@{
                Key = [string]($i + 1)
                Label = '{0} | {1} | {2}' -f $item.Status, $item.Preset.ToUpperInvariant(), $name
                Value = [string]($page.StartIndex + $i)
            }
        }
        if ($pageIndex -gt 0) { $options += [pscustomobject]@{ Key = 'P'; Label = 'Previous page'; Value = 'Previous' } }
        if ($pageIndex -lt ($page.PageCount - 1)) { $options += [pscustomobject]@{ Key = 'N'; Label = 'Next page'; Value = 'Next' } }
        $choice = Read-MenuChoice -Title ('Remove an item ({0}/{1})' -f $page.PageNumber, $page.PageCount) -Options $options -AllowBack
        if ($null -eq $choice -or $choice -eq 'BACK') { return }
        if ($choice -eq 'Previous') { $pageIndex--; continue }
        if ($choice -eq 'Next') { $pageIndex++; continue }
        $script:DownloadQueue.RemoveAt([int]$choice)
    }
}

function Show-DownloadQueue {
    while ($true) {
        Clear-Terminal
        Write-Heading -Text 'Download queue'
        $pendingCount = @($script:DownloadQueue.ToArray() | Where-Object { $_.Status -eq 'Pending' }).Count
        $retryStates = Get-QueueRetryStates
        $retryCount = @($script:DownloadQueue.ToArray() | Where-Object { $_.Status -in $retryStates }).Count
        $choice = Read-MenuChoice -Title ('{0} items | {1} pending' -f $script:DownloadQueue.Count, $pendingCount) -Notes @('Cleared when you close the app.') -AllowBack -Options @(
            [pscustomobject]@{ Key = '1'; Label = 'Add link'; Value = 'Add' }
            [pscustomobject]@{ Key = '2'; Label = 'View / remove'; Value = 'View'; Disabled = ($script:DownloadQueue.Count -eq 0) }
            [pscustomobject]@{ Key = '3'; Label = 'Start queue'; Value = 'Start'; Disabled = ($pendingCount -eq 0) }
            [pscustomobject]@{ Key = '4'; Label = 'Retry failed / interrupted'; Value = 'Retry'; Disabled = ($retryCount -eq 0) }
        )
        switch ($choice) {
            'Add' { $request = New-DownloadRequest -ForQueue; if ($null -ne $request) { $script:DownloadQueue.Add($request) } }
            'View' { Show-QueueItems }
            'Start' { Start-DownloadQueue }
            'Retry' { Start-DownloadQueue -RetryFailed }
            default { return }
        }
    }
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

    $validRows = @()
    $skipped = 0
    foreach ($row in $rows) {
        $size = [long]0
        $hasColumns = $true
        foreach ($column in @('SizeBytes','Status','TimestampLocal','Preset','FilePath','Url')) {
            if ($null -eq $row.PSObject.Properties[$column]) { $hasColumns = $false }
        }
        if (-not $hasColumns -or -not [long]::TryParse([string](Get-PropertyValue $row 'SizeBytes'), [ref]$size) -or $size -lt 0) {
            $skipped++
            continue
        }
        $row.SizeBytes = $size
        $validRows += $row
    }
    $rows = $validRows
    $sorted = @($rows | Sort-Object { [long]$_.SizeBytes } -Descending)
    if ($sorted.Count -eq 0) {
        Clear-Terminal
        Write-Heading -Text 'Download history - biggest to smallest'
        Write-Host $(if ($skipped -gt 0) { 'No valid history records remain. The original CSV has been preserved.' } else { 'The history file is empty.' }) -ForegroundColor Yellow
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
        if ($skipped -gt 0) { Write-Host ('Skipped {0} damaged history row(s). The original CSV has been preserved.' -f $skipped) -ForegroundColor Yellow }
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
    Clear-Terminal
    Write-Heading -Text 'Update downloader engines'

    # yt-dlp updates itself in place via its own -U command.
    Write-Host 'yt-dlp:' -ForegroundColor Cyan
    Write-Host 'Checking for a newer yt-dlp.exe...' -ForegroundColor DarkGray
    try {
        & $script:YtDlp @($script:YtDlpBaseArguments) -U 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host 'yt-dlp is up to date (or was updated successfully).' -ForegroundColor Green
        } else {
            Write-Host ('The yt-dlp update finished with exit code {0}.' -f $exitCode) -ForegroundColor Yellow
        }
    } catch {
        Write-Host ('Could not update yt-dlp: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }

    # gallery-dl is updated from the tested, pinned release rather than self-updating.
    Write-Host ''
    Write-Host 'gallery-dl:' -ForegroundColor Cyan
    $release = Get-GalleryDlRelease
    $installed = Get-GalleryDlVersion
    if ([string]::IsNullOrWhiteSpace($installed)) {
        Write-Host 'gallery-dl is not installed.' -ForegroundColor Yellow
        [void](Install-GalleryDl)
    } else {
        Write-Host ('Installed: {0} | Tested/pinned: {1}' -f $installed, $release.Version) -ForegroundColor DarkGray
        if ($installed -eq $release.Version) {
            Write-Host 'gallery-dl matches the tested release.' -ForegroundColor Green
        } else {
            if (Install-GalleryDl) { Write-Host 'gallery-dl updated to the tested release.' -ForegroundColor Green }
        }
    }
    Pause-Terminal
}

function Show-SettingsMenu {
    while ($true) {
        Clear-Terminal
        Write-Heading -Text 'Settings'
        $state = if ($script:Settings.OpenFolderAfterDownload) { 'On' } else { 'Off' }
        $profileCount = @(Read-AccountProfiles).Count
        $heldCount = @((Read-PlatformHolds).Keys).Count
        Write-Host ('  1. Open the download folder when a download finishes: {0}' -f $state)
        Write-Host ('  2. Manage account profiles (cookie files): {0} configured' -f $profileCount)
        Write-Host ('  3. Review blocked platforms: {0} on hold' -f $heldCount)
        Write-Host '  B. Back'
        Write-Host ''
        $choice = (Read-Host 'Choose an option [B]').Trim().ToUpperInvariant()
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
            '2' { Show-AccountProfilesMenu }
            '3' { Show-BlockedPlatformsMenu }
            'B' { return }
            default {
                Write-Host 'Please choose 1-3 or B.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Manage cookie-file account profiles. Profiles store only a name, platform, and
# path - never cookie values.
function Show-AccountProfilesMenu {
    while ($true) {
        Clear-Terminal
        Write-Heading -Text 'Account profiles'
        Write-Host 'Profiles let entire-post mode use a signed-in session for gated posts.' -ForegroundColor DarkGray
        Write-Host 'They store only a name, platform, and the path to a cookies.txt you export.' -ForegroundColor DarkGray
        Write-Host ''
        $profiles = @(Read-AccountProfiles)
        if ($profiles.Count -eq 0) {
            Write-Host '  (no profiles yet)' -ForegroundColor DarkGray
        } else {
            for ($i = 0; $i -lt $profiles.Count; $i++) {
                $exists = if (Test-Path -LiteralPath $profiles[$i].CookieFile -PathType Leaf) { '' } else { '  [file missing]' }
                Write-Host ('  {0}. {1} ({2}){3}' -f ($i + 1), $profiles[$i].Name, (Get-PlatformDisplayName $profiles[$i].Platform), $exists)
            }
        }
        Write-Host ''
        Write-Host '  A. Add a profile'
        if ($profiles.Count -gt 0) { Write-Host '  R. Remove a profile' }
        Write-Host '  B. Back'
        Write-Host ''
        $choice = (Read-Host 'Choose an option [B]').Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'B' }
        switch ($choice) {
            'A' { Add-AccountProfileInteractive }
            'R' {
                if ($profiles.Count -eq 0) { continue }
                $sel = (Read-Host ('Remove which number? [1-{0}], blank to cancel' -f $profiles.Count)).Trim()
                $index = 0
                if ([int]::TryParse($sel, [ref]$index) -and $index -ge 1 -and $index -le $profiles.Count) {
                    $remaining = @($profiles | Where-Object { $_ -ne $profiles[$index - 1] })
                    Write-AccountProfiles -Profiles $remaining
                    Write-Host 'Profile removed.' -ForegroundColor Green
                    Start-Sleep -Seconds 1
                }
            }
            'B' { return }
            default { }
        }
    }
}

function Add-AccountProfileInteractive {
    Clear-Terminal
    Write-Heading -Text 'Add account profile'
    Write-Host 'Export a Netscape-format cookies.txt from your browser while signed in, then' -ForegroundColor DarkGray
    Write-Host 'point to that file here. Cookie values are never stored by this app.' -ForegroundColor DarkGray
    Write-Host ''
    $platforms = @(Get-SocialPostPlatforms)
    $options = foreach ($p in $platforms) {
        [pscustomobject]@{ Key = [string]([array]::IndexOf($platforms, $p) + 1); Label = (Get-PlatformDisplayName $p); Value = $p }
    }
    $platform = Read-MenuChoice -Title 'Which platform is this account for?' -Options $options
    if ($null -eq $platform) { return }

    $name = (Read-Host 'Friendly name (e.g. "My IG")').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Host 'Cancelled.' -ForegroundColor Yellow; Start-Sleep -Seconds 1; return }

    $path = (Read-Host 'Full path to the cookies.txt file').Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host 'That file was not found. Nothing was saved.' -ForegroundColor Red
        Pause-Terminal
        return
    }
    if ($null -eq (New-FilteredCookieFile -SourcePath $path -Platform $platform)) {
        Write-Host ('That file has no {0} cookies, or could not be read/secured. Nothing was saved.' -f (Get-PlatformDisplayName $platform)) -ForegroundColor Red
        Pause-Terminal
        return
    }
    # New-FilteredCookieFile created a temp copy just to validate; sweep it away.
    Clear-StaleCookieFiles

    $profiles = @(Read-AccountProfiles)
    $profiles += [pscustomobject]@{ Name = $name; Platform = $platform; CookieFile = $path }
    Write-AccountProfiles -Profiles $profiles
    Write-Host 'Profile saved.' -ForegroundColor Green
    Start-Sleep -Seconds 1
}

# Review and release platform holds. Releasing never starts a download.
function Show-BlockedPlatformsMenu {
    while ($true) {
        Clear-Terminal
        Write-Heading -Text 'Blocked platforms'
        $holds = Read-PlatformHolds
        $names = @($holds.Keys)
        if ($names.Count -eq 0) {
            Write-Host 'No platforms are on hold.' -ForegroundColor Green
            Pause-Terminal
            return
        }
        for ($i = 0; $i -lt $names.Count; $i++) {
            $h = $holds[$names[$i]]
            $reason = Get-PropertyValue -InputObject $h -Name 'reason'
            $retry = Get-PropertyValue -InputObject $h -Name 'retryAfter'
            $suffix = if ($retry) { ('  (retry after {0})' -f $retry) } else { '' }
            Write-Host ('  {0}. {1} - {2}{3}' -f ($i + 1), (Get-PlatformDisplayName $names[$i]), $reason, $suffix)
        }
        Write-Host ''
        Write-Host '  Releasing a hold does not start any download; it only re-enables the platform.' -ForegroundColor DarkGray
        Write-Host '  R. Release a hold'
        Write-Host '  B. Back'
        Write-Host ''
        $choice = (Read-Host 'Choose an option [B]').Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'B' }
        if ($choice -eq 'B') { return }
        if ($choice -eq 'R') {
            $sel = (Read-Host ('Release which number? [1-{0}], blank to cancel' -f $names.Count)).Trim()
            $index = 0
            if ([int]::TryParse($sel, [ref]$index) -and $index -ge 1 -and $index -le $names.Count) {
                $hold = $holds[$names[$index - 1]]
                $retry = Get-PropertyValue -InputObject $hold -Name 'retryAfter'
                if ($retry) {
                    $when = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$retry, [ref]$when) -and (Get-Date) -lt $when) {
                        $confirm = (Read-Host ('This platform asked to wait until {0}. Release anyway? [y/N]' -f $retry)).Trim().ToUpperInvariant()
                        if ($confirm -notin @('Y', 'YES')) { continue }
                    }
                }
                Remove-PlatformHold -Platform $names[$index - 1]
                Write-Host 'Hold released.' -ForegroundColor Green
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
    $previousProgress = $ProgressPreference
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
        $ProgressPreference = $previousProgress
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $succeeded
}

# ===========================================================================
#  Social-post engine (gallery-dl)
# ===========================================================================

# Map a URL to a known platform key, or $null when unrecognised. Host-based so
# query strings and paths do not affect detection.
function Get-UrlPlatform {
    param([string]$Url)
    $parsed = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsed)) { return $null }
    $h = $parsed.Host.ToLowerInvariant()
    if ($h.StartsWith('www.')) { $h = $h.Substring(4) }
    switch -Regex ($h) {
        '(^|\.)instagram\.com$'                 { return 'instagram' }
        '(^|\.)(tiktok\.com|vm\.tiktok\.com)$'  { return 'tiktok' }
        '(^|\.)(x\.com|twitter\.com)$'          { return 'x' }
        '(^|\.)(facebook\.com|fb\.watch|fb\.com)$' { return 'facebook' }
        '(^|\.)(youtube\.com|youtu\.be)$'       { return 'youtube' }
        default { return $null }
    }
}

function Get-PlatformDisplayName {
    param([string]$Platform)
    switch ($Platform) {
        'instagram' { 'Instagram' }
        'tiktok'    { 'TikTok' }
        'x'         { 'X' }
        'facebook'  { 'Facebook' }
        'youtube'   { 'YouTube' }
        default     { if ([string]::IsNullOrEmpty($Platform)) { 'Unknown' } else { $Platform } }
    }
}

# Best-effort stable post id from a single-post URL, used for the output folder.
# Deterministic (no network) so the destination never depends on remote titles.
# Returns $null when no id pattern matches; callers fall back to the request id.
function Get-PostIdFromUrl {
    param([string]$Url, [string]$Platform)
    $parsed = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsed)) { return $null }
    $path = $parsed.AbsolutePath
    switch ($Platform) {
        'x'         { if ($path -match '/status/(\d+)') { return $matches[1] } }
        'tiktok'    {
            if ($path -match '/(?:video|photo)/(\d+)') { return $matches[1] }
            if ($path -match '^/([A-Za-z0-9]+)/?$') { return $matches[1] }  # vm.tiktok.com short code
        }
        'instagram' { if ($path -match '/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)') { return $matches[1] } }
        'facebook'  {
            if ($path -match '/(?:videos|reel)/(\d+)') { return $matches[1] }
            if ($path -match '/posts/([A-Za-z0-9]+)') { return $matches[1] }
            $query = $parsed.Query.TrimStart('?')
            foreach ($pair in ($query -split '&')) {
                $kv = $pair -split '=', 2
                if ($kv.Count -eq 2 -and $kv[0] -in @('story_fbid', 'v', 'fbid') -and $kv[1]) {
                    return [System.Uri]::UnescapeDataString($kv[1])
                }
            }
        }
    }
    return $null
}

# Reject URL forms that address a collection (profile, feed, album, stories) rather
# than a single post. Entire-post mode must never silently expand to these.
function Test-IsCollectionUrl {
    param([string]$Url, [string]$Platform)
    $parsed = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsed)) { return $false }
    $path = $parsed.AbsolutePath.TrimEnd('/')
    switch ($Platform) {
        'instagram' {
            if ($path -match '^/(explore|reels/audio|directory)') { return $true }
            if ($path -match '^/stories/') { return $true }
            # A bare "/username" (no /p//reel//tv/ segment) is a profile.
            if ($path -match '^/[^/]+$' -and $path -notmatch '^/(p|reel|reels|tv)$') { return $true }
        }
        'x' {
            if ($path -match '^/[^/]+$') { return $true }                       # profile
            if ($path -match '^/[^/]+/(media|likes|with_replies|following|followers)$') { return $true }
            if ($path -match '^/i/lists/') { return $true }
        }
        'tiktok' {
            if ($path -match '^/@[^/]+$') { return $true }                      # profile
            if ($path -match '^/(foryou|following|explore)$') { return $true }
            if ($path -match '/@[^/]+/(playlist|collection)') { return $true }
        }
        'facebook' {
            if ($path -match '^/(groups|watch|marketplace|profile\.php)$') { return $true }
            if ($path -match '^/[^/]+$' -and $path -notmatch '^/(watch|reel)$') { return $true }  # page/profile
        }
    }
    return $false
}

# Platforms enabled for entire-post mode. All four ship in this release; gated
# platforms simply need a cookie profile to succeed.
function Get-SocialPostPlatforms {
    return @('instagram', 'tiktok', 'x', 'facebook')
}

# Pinned gallery-dl release. Codeberg publishes no checksum file, so Sha256 is
# empty by default: Install-GalleryDl then records and fingerprints the binary on
# first download (trust-on-first-use). Set Sha256 to enforce strict verification.
function Get-GalleryDlRelease {
    return [pscustomobject]@{
        Version = '1.32.13'
        Url     = 'https://codeberg.org/mikf/gallery-dl/releases/download/v1.32.13/gallery-dl.exe'
        Sha256  = ''
    }
}

function Get-GalleryDlVersion {
    if (-not (Test-Path -LiteralPath $script:GalleryDl -PathType Leaf)) { return $null }
    try {
        $output = & $script:GalleryDl --version 2>$null
        return ([string]$output).Trim()
    } catch { return $null }
}

function Test-GalleryDlReady {
    if (-not (Test-Path -LiteralPath $script:GalleryDl -PathType Leaf)) {
        Write-Host 'gallery-dl was not found beside this script.' -ForegroundColor Yellow
        Write-Host 'It downloads photos and mixed-media social posts.' -ForegroundColor Yellow
        if (Install-GalleryDl) {
            Write-Host 'gallery-dl is ready.' -ForegroundColor Green
        } else {
            Write-Host 'Setup was not completed. Entire-post downloads are unavailable until gallery-dl is installed.' -ForegroundColor Yellow
            Pause-Terminal
            return $false
        }
    }
    return $true
}

# Fetch gallery-dl, verify integrity, smoke-test, and place it beside the script.
# Any existing binary is preserved until the replacement passes its smoke test.
function Install-GalleryDl {
    Write-Host ''
    Write-Host 'gallery-dl can be downloaded (about 22 MB) straight into this folder - no install needed.' -ForegroundColor Cyan
    $answer = (Read-Host 'Download gallery-dl now? [Y]es / [N]o').Trim().ToUpperInvariant()
    if ($answer -notin @('', 'Y', 'YES')) { return $false }

    $release = Get-GalleryDlRelease
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('gallery-dl-{0}.exe' -f ([guid]::NewGuid().ToString('N')))
    $succeeded = $false
    $previousProgress = $ProgressPreference
    try {
        Write-Host ('Downloading gallery-dl {0}...' -f $release.Version) -ForegroundColor DarkGray
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $release.Url -OutFile $temp -UseBasicParsing
        $ProgressPreference = $previousProgress

        $hash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($release.Sha256)) {
            if ($hash -ne $release.Sha256.ToLowerInvariant()) {
                Write-Host 'Downloaded gallery-dl failed SHA-256 verification; discarding it.' -ForegroundColor Red
                return $false
            }
            Write-Host 'SHA-256 verified.' -ForegroundColor DarkGray
        } else {
            Write-Host ('SHA-256 (record to pin): {0}' -f $hash) -ForegroundColor DarkGray
        }

        # Smoke-test the fresh binary before it replaces any existing one.
        $version = $null
        try { $version = (& $temp --version 2>$null | Select-Object -First 1) } catch { $version = $null }
        if ([string]::IsNullOrWhiteSpace([string]$version)) {
            Write-Host 'The downloaded gallery-dl did not run; keeping the previous setup.' -ForegroundColor Red
            return $false
        }

        Copy-Item -LiteralPath $temp -Destination $script:GalleryDl -Force
        $succeeded = Test-Path -LiteralPath $script:GalleryDl -PathType Leaf
    } catch {
        Write-Host ('gallery-dl download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    } finally {
        $ProgressPreference = $previousProgress
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return $succeeded
}

# Default request-pacing (seconds) per platform. Instagram's 6-12s window is the
# only upstream-documented value; the rest are product defaults, not safety limits.
function Get-PlatformSleepRequest {
    param([string]$Platform)
    switch ($Platform) {
        'instagram' { return @(6, 12) }
        default     { return @(3, 6) }
    }
}

# Build a temporary gallery-dl config file for one request and return its path.
# The caller deletes it after the run. Pacing, retry budgets, the flat output
# folder, and (when supplied) the cookie file all live here rather than on the
# command line.
function New-GalleryDlConfigFile {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [string]$CookiePath
    )
    $sleep = Get-PlatformSleepRequest -Platform $Platform
    $extractor = [ordered]@{
        'directory'     = @()                        # flat: no per-extractor subfolders
        'sleep-request' = $sleep
        'retries'       = 2                          # native transient retries, capped
    }
    if (-not [string]::IsNullOrWhiteSpace($CookiePath)) {
        $extractor['cookies'] = $CookiePath
    }
    $config = [ordered]@{
        extractor  = $extractor
        downloader = [ordered]@{
            retries = 2
            ytdl    = [ordered]@{
                # gallery-dl delegates some video to embedded yt-dlp; point it at the
                # bundled ffmpeg (already on PATH) for merged playback output.
                'raw-options' = [ordered]@{ ffmpeg_location = $script:Root }
            }
        }
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('gdl-config-{0}.json' -f ([guid]::NewGuid().ToString('N')))
    ($config | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-GalleryDlArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$DestDir,
        [Parameter(Mandatory = $true)][string]$Url
    )
    # --config-ignore: use only our generated config, never the user's ~/.gallery-dl.conf.
    # -D sets the exact (flat) destination directory for this post.
    return @('--config-ignore', '--config', $ConfigPath, '-D', $DestDir, '--', $Url)
}

# Social media shares one folder per date and platform: Downloads/<date>/<platform>.
function Get-SocialPostFolder {
    param([datetime]$StartedAt, [string]$Platform, [string]$PostId, [string]$RequestId)
    return Join-Path (Join-Path $script:DownloadsRoot $StartedAt.ToString('yyyy-MM-dd')) $Platform
}

# ---- Per-request manifest (durable item record) ----------------------------

function Get-ManifestPath {
    param([string]$TargetFolder, [string]$RequestId)
    $name = if ($RequestId) { 'manifest-{0}.json' -f $RequestId } else { 'manifest.json' }
    return Join-Path $TargetFolder $name
}

function New-ManifestItem {
    param([int]$Order, [System.IO.FileInfo]$File, [string]$MediaType, [string]$Provenance = 'gallery-dl')
    return [ordered]@{
        order      = $Order
        path       = (Get-RelativeDisplayPath -Path $File.FullName)
        sizeBytes  = [long]$File.Length
        mediaType  = $MediaType
        provenance = $Provenance
    }
}

# Write the manifest atomically (temp file + move) so a crash never leaves a
# half-written record.
function Write-RequestManifest {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Manifest)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $temp = '{0}.{1}.tmp' -f $Path, ([guid]::NewGuid().ToString('N'))
    ($Manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-RequestManifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-MediaTypeForFile {
    param([System.IO.FileInfo]$File)
    if ($script:ImageExtensions -contains $File.Extension.ToLowerInvariant()) { return 'image' }
    return 'video'
}

# Signals that a platform is actively blocking/challenging us. Heuristic: no
# wrapper can guarantee interception before the engine emits the error, so this
# only drives the observable stop + hold, never a completeness claim.
function Test-BlockingSignal {
    param([string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    return ($Line -match '(?i)\b(429|rate.?limit|too many requests|temporarily blocked|challenge_required|checkpoint_required|login[_ ]required|please wait a few minutes|account has been)\b')
}

function New-SocialPostRequest {
    param([Parameter(Mandatory = $true)][string]$Url, [AllowNull()][object]$Account, [switch]$IncludeManifest)
    $platform = Get-UrlPlatform -Url $Url
    if ($null -eq $platform -or $platform -eq 'youtube') {
        Write-Host 'Entire-post mode supports Instagram, TikTok, X, and Facebook links.' -ForegroundColor Red
        if ($platform -eq 'youtube') { Write-Host 'Use Video / audio mode for YouTube.' -ForegroundColor Yellow }
        Pause-Terminal
        return $null
    }
    if ($platform -notin (Get-SocialPostPlatforms)) {
        Write-Host ('{0} is not available in entire-post mode yet.' -f (Get-PlatformDisplayName -Platform $platform)) -ForegroundColor Red
        Pause-Terminal
        return $null
    }
    if (Test-IsCollectionUrl -Url $Url -Platform $platform) {
        Write-Host 'That link points to a profile, feed, or album, not a single post.' -ForegroundColor Red
        Write-Host 'Entire-post mode downloads one post at a time. Paste a single post/reel/photo link.' -ForegroundColor Yellow
        Pause-Terminal
        return $null
    }

    $startedAt = Get-Date
    $requestId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $postId = Get-PostIdFromUrl -Url $Url -Platform $platform
    $targetFolder = Get-SocialPostFolder -StartedAt $startedAt -Platform $platform -PostId $postId -RequestId $requestId

    return [pscustomobject]@{
        Url          = $Url
        Title        = ''
        Mode         = 'SocialPost'
        IncludeManifest = [bool]$IncludeManifest
        Engine       = 'gallery-dl'
        Platform     = $platform
        Account      = $Account
        RequestId    = $requestId
        PostId       = $postId
        TargetFolder = $targetFolder
        Status       = 'Pending'
        # Placeholder yt-dlp fields keep shared history/display code total.
        Preset       = 'post'
        Quality      = 'best'
        PlaylistMode = 'Single'
        LiveDecision = [pscustomobject]@{ Enabled = $false; Description = 'n/a' }
    }
}

# Execute one entire-post request with gallery-dl. Mirrors Invoke-YtDlpRequest's
# history/records contract but records durable item identities via the manifest.
function Invoke-SocialPostRequest {
    param([Parameter(Mandatory = $true)][object]$Request, [switch]$Queued, [string]$QueueLabel = '')
    $url = $Request.Url
    $platform = $Request.Platform
    $targetFolder = $Request.TargetFolder
    $startedAt = Get-Date
    if (-not (Test-Path -LiteralPath $targetFolder)) {
        [void](New-Item -ItemType Directory -Path $targetFolder -Force)
    }
    $before = Get-FileSnapshot -Path $targetFolder

    # Phase 3 resolves a temporary filtered cookie copy from $Request.Account.
    $cookiePath = Resolve-RequestCookiePath -Request $Request
    $configPath = $null
    $exitCode = 1
    $interrupted = $false
    $script:SocialBlockingHit = $false

    Clear-Terminal
    Write-Heading -Text $(if ($QueueLabel) { "Downloading $QueueLabel" } else { 'Downloading post' })
    Write-Host ('{0} post' -f (Get-PlatformDisplayName -Platform $platform))
    Write-Host $url
    Write-Host ('Destination: {0}' -f (Get-RelativeDisplayPath -Path $targetFolder))
    if ($null -ne $Request.Account) {
        Write-Host ('Account: {0}' -f $Request.Account.Name) -ForegroundColor DarkGray
    }
    Write-Host 'Press Ctrl+C once if you need to interrupt the download.' -ForegroundColor DarkGray
    Write-Host ''

    try {
        $configPath = New-GalleryDlConfigFile -Platform $platform -CookiePath $cookiePath
        $arguments = Get-GalleryDlArguments -ConfigPath $configPath -DestDir $targetFolder -Url $url
        $processResult = Invoke-MediaProcess -ExecutablePath $script:GalleryDl -Arguments $arguments -OnOutput {
            param([string]$line)
            if (Test-BlockingSignal -Line $line) { $script:SocialBlockingHit = $true }
            Write-Host $line
        }
        $exitCode = $processResult.ExitCode
        $interrupted = $processResult.Interrupted
        if ($exitCode -in @(130, -1073741510)) { $interrupted = $true }
    } catch [System.Management.Automation.PipelineStoppedException] {
        $interrupted = $true
        $exitCode = 130
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $exitCode = 1
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($configPath) -and (Test-Path -LiteralPath $configPath)) {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        }
        Remove-TemporaryCookieFile -Path $cookiePath
    }

    # Only finalized files are recorded; gallery-dl writes final names directly, so
    # a folder diff of media+image files is the durable evidence of completion.
    $completedFiles = @(Get-NewOrChangedFiles -Path $targetFolder -Before $before | Sort-Object FullName)
    $status = Get-SocialPostStatus -ExitCode $exitCode -Interrupted $interrupted -Blocked $script:SocialBlockingHit -CompletedCount $completedFiles.Count

    # Durable per-request manifest.
    $items = New-Object System.Collections.Generic.List[object]
    $order = 0
    foreach ($file in $completedFiles) {
        $order++
        $items.Add((New-ManifestItem -Order $order -File $file -MediaType (Get-MediaTypeForFile -File $file)))
    }
    $manifest = [ordered]@{
        manifestVersion = 1
        requestId       = $Request.RequestId
        url             = $url
        platform        = $platform
        postId          = $Request.PostId
        mode            = 'SocialPost'
        status          = $status
        expectedCount   = $null            # gallery-dl gives no reliable pre-count
        enumerationFinished = ($exitCode -eq 0)
        engineVersions  = [ordered]@{ 'gallery-dl' = (Get-GalleryDlVersion) }
        downloadedCount = $completedFiles.Count
        items           = $items.ToArray()
        recordedAtLocal = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    if (Get-PropertyValue -InputObject $Request -Name 'IncludeManifest') {
        try { Write-RequestManifest -Path (Get-ManifestPath -TargetFolder $targetFolder -RequestId $Request.RequestId) -Manifest $manifest }
        catch { Write-Host ('Could not write the post manifest: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    }

    # History rows reuse the unchanged CSV columns.
    $historyRows = New-Object System.Collections.Generic.List[object]
    $historyStatus = switch ($status) {
        'Completed'   { 'Completed' }
        'Partial'     { 'Partial' }
        'Blocked'     { 'Blocked' }
        'Interrupted' { 'Interrupted' }
        default       { 'Failed (exit {0})' -f $exitCode }
    }
    foreach ($file in $completedFiles) {
        $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset ('post/{0}' -f $platform) -LiveMode 'n/a' -PlaylistMode 'Single' -Status $historyStatus -File $file))
    }
    if ($completedFiles.Count -eq 0) {
        $historyRows.Add((New-HistoryRow -Timestamp $startedAt -Url $url -Preset ('post/{0}' -f $platform) -LiveMode 'n/a' -PlaylistMode 'Single' -Status $historyStatus -File $null))
    }
    try { Add-HistoryRows -Rows $historyRows.ToArray() }
    catch { Write-Host ('Could not update download history: {0}' -f $_.Exception.Message) -ForegroundColor Red }

    if ($script:SocialBlockingHit) {
        Set-PlatformHold -Platform $platform -Reason 'Rate limit or account challenge detected.'
    }

    if (-not $Queued) {
        Write-Heading -Text 'Download result'
        switch ($status) {
            'Completed'   { Write-Host ('Downloaded {0} item(s).' -f $completedFiles.Count) -ForegroundColor Green }
            'Partial'     { Write-Host ('Partial: downloaded {0} item(s) before the download stopped.' -f $completedFiles.Count) -ForegroundColor Yellow }
            'Blocked'     { Write-Host ('{0} is temporarily blocking downloads. It has been put on hold.' -f (Get-PlatformDisplayName -Platform $platform)) -ForegroundColor Red }
            'Interrupted' { Write-Host 'The download was interrupted.' -ForegroundColor Yellow }
            default       { Write-Host ('gallery-dl failed with exit code {0}.' -f $exitCode) -ForegroundColor Red }
        }
        Show-FileList -Files $completedFiles -IncludeTotal
    }
    if ($status -eq 'Completed' -and $script:Settings.OpenFolderAfterDownload -and $completedFiles.Count -gt 0) {
        Open-DownloadLocation -Files $completedFiles -TargetFolder $targetFolder
    }
    if (-not $Queued) { Pause-Terminal }
    return [pscustomobject]@{ Status = $status; ExitCode = $exitCode }
}

# Map raw engine outcome to the queue state model.
function Get-SocialPostStatus {
    param([int]$ExitCode, [bool]$Interrupted, [bool]$Blocked, [int]$CompletedCount)
    if ($Blocked) { return 'Blocked' }
    if ($Interrupted) { return 'Interrupted' }
    if ($ExitCode -eq 0 -and $CompletedCount -gt 0) { return 'Completed' }
    if ($CompletedCount -gt 0) { return 'Partial' }
    # Nothing was downloaded (including an exit-0 "empty success"): treat as a
    # retryable failure rather than claiming completion with zero items.
    return 'Failed'
}

# ===========================================================================
#  Authentication (user-supplied Netscape cookie files)
# ===========================================================================

# Filename prefix for our temporary, permission-restricted cookie copies. A
# function (not a script var) so every function-loaded test harness sees it.
function Get-CookieTempPrefix { return 'seen-dl-cookies-' }

# Cookie domains kept when filtering a user cookie file down to one platform.
function Get-PlatformCookieDomains {
    param([string]$Platform)
    switch ($Platform) {
        'instagram' { @('instagram.com', 'cdninstagram.com') }
        'tiktok'    { @('tiktok.com', 'tiktokcdn.com') }
        'x'         { @('x.com', 'twitter.com') }
        'facebook'  { @('facebook.com', 'fbcdn.net', 'fb.com') }
        default     { @() }
    }
}

# Restrict a file to the current user only. Best-effort: failure to tighten the
# ACL must not leak the file, so the caller treats a failure as fatal for the copy.
function Restrict-FilePermissions {
    param([string]$Path)
    try {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $Path /inheritance:r /grant:r ("{0}:F" -f $me) *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# Build a temp cookie file containing only the platform's cookie lines, preserving
# Netscape domain/path/expiry semantics. Returns the temp path, or $null on any
# problem (the original file is never modified).
function New-FilteredCookieFile {
    param([string]$SourcePath, [string]$Platform)
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return $null }
    $domains = Get-PlatformCookieDomains -Platform $Platform
    if ($domains.Count -eq 0) { return $null }
    try {
        $lines = Get-Content -LiteralPath $SourcePath -ErrorAction Stop
    } catch { return $null }

    $kept = New-Object System.Collections.Generic.List[string]
    $kept.Add('# Netscape HTTP Cookie File')
    $matched = 0
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#') -and -not $line.StartsWith('#HttpOnly_')) { continue }
        $domainField = ($line -split "`t")[0].TrimStart('#').TrimStart('.').ToLowerInvariant()
        foreach ($d in $domains) {
            if ($domainField -eq $d -or $domainField.EndsWith('.' + $d)) {
                $kept.Add($line); $matched++; break
            }
        }
    }
    if ($matched -eq 0) { return $null }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}{1}.txt' -f (Get-CookieTempPrefix), ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -LiteralPath $temp -Value $kept -Encoding ASCII -ErrorAction Stop
    } catch { return $null }
    if (-not (Restrict-FilePermissions -Path $temp)) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $temp
}

# Resolve the cookie file to hand the engine for a request. Anonymous requests
# return $null. Authenticated requests must have an establishable, matching
# platform, or they are refused (credentials are never sent to an unknown host).
function Resolve-RequestCookiePath {
    param([object]$Request)
    $account = Get-PropertyValue -InputObject $Request -Name 'Account'
    if ($null -eq $account) { return $null }
    $platform = Get-PropertyValue -InputObject $Request -Name 'Platform'
    if ([string]::IsNullOrEmpty($platform)) { $platform = Get-UrlPlatform -Url $Request.Url }
    if ([string]::IsNullOrEmpty($platform)) {
        throw 'Cannot establish the platform for an authenticated request; refusing to send cookies.'
    }
    $accountPlatform = Get-PropertyValue -InputObject $account -Name 'Platform'
    if ($accountPlatform -and $accountPlatform -ne $platform) {
        throw ('The selected account is for {0}, not {1}.' -f (Get-PlatformDisplayName $accountPlatform), (Get-PlatformDisplayName $platform))
    }
    $cookieFile = Get-PropertyValue -InputObject $account -Name 'CookieFile'
    $filtered = New-FilteredCookieFile -SourcePath $cookieFile -Platform $platform
    if ($null -eq $filtered) {
        throw 'The cookie file could not be read, contained no cookies for this platform, or could not be secured.'
    }
    return $filtered
}

# Delete a temporary cookie copy we created. Never touches anything outside our
# temp prefix, so a user's original file can never be removed by accident.
function Remove-TemporaryCookieFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $name = Split-Path -Leaf $Path
    if ($name.StartsWith((Get-CookieTempPrefix)) -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

# Remove any application-owned temporary cookie copies left by a prior crash.
function Clear-StaleCookieFiles {
    $tempRoot = [System.IO.Path]::GetTempPath()
    Get-ChildItem -LiteralPath $tempRoot -Filter ('{0}*' -f (Get-CookieTempPrefix)) -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
#  Platform holds (persisted across restarts)
# ===========================================================================

function Get-HoldStorePath {
    if (-not (Test-Path variable:script:LogsRoot)) { return $null }
    return (Join-Path $script:LogsRoot 'platform-holds.json')
}

function Read-PlatformHolds {
    $path = Get-HoldStorePath
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $map = @{}
        foreach ($p in $raw.PSObject.Properties) { $map[$p.Name] = $p.Value }
        return $map
    } catch { return @{} }
}

function Write-PlatformHolds {
    param([hashtable]$Holds)
    if (-not (Test-Path -LiteralPath $script:LogsRoot)) { [void](New-Item -ItemType Directory -Path $script:LogsRoot -Force) }
    $path = Get-HoldStorePath
    $temp = '{0}.{1}.tmp' -f $path, ([guid]::NewGuid().ToString('N'))
    ($Holds | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Set-PlatformHold {
    param([string]$Platform, [string]$Reason = '', [datetime]$RetryAfter)
    $holds = Read-PlatformHolds
    $entry = [ordered]@{
        reason  = $Reason
        heldAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    if ($PSBoundParameters.ContainsKey('RetryAfter')) {
        $entry['retryAfter'] = $RetryAfter.ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    $holds[$Platform] = [pscustomobject]$entry
    Write-PlatformHolds -Holds $holds
}

function Get-PlatformHold {
    param([string]$Platform)
    $holds = Read-PlatformHolds
    if ($holds.ContainsKey($Platform)) { return $holds[$Platform] }
    return $null
}

function Remove-PlatformHold {
    param([string]$Platform)
    $holds = Read-PlatformHolds
    if ($holds.ContainsKey($Platform)) {
        $holds.Remove($Platform)
        Write-PlatformHolds -Holds $holds
    }
}

# A platform is held only until its recorded retry-after time passes; an expired
# hold is cleared automatically so work can resume.
function Test-PlatformHeld {
    param([string]$Platform)
    $hold = Get-PlatformHold -Platform $Platform
    if ($null -eq $hold) { return $false }
    $retryAfter = Get-PropertyValue -InputObject $hold -Name 'retryAfter'
    if ($retryAfter) {
        $when = [datetime]::MinValue
        if ([datetime]::TryParse([string]$retryAfter, [ref]$when) -and (Get-Date) -ge $when) {
            Remove-PlatformHold -Platform $Platform
            return $false
        }
    }
    return $true
}

# ---- Account profile store -------------------------------------------------
# Profiles store only a friendly name, platform, and cookie-file path. Cookie
# values are never persisted here or anywhere else in the application.

function Get-ProfileStorePath {
    if (-not (Test-Path variable:script:LogsRoot)) { return $null }
    return (Join-Path $script:LogsRoot 'account-profiles.json')
}

function Read-AccountProfiles {
    $path = Get-ProfileStorePath
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @($raw | ForEach-Object {
            [pscustomobject]@{
                Name       = [string]$_.Name
                Platform   = [string]$_.Platform
                CookieFile = [string]$_.CookieFile
            }
        })
    } catch { return @() }
}

function Write-AccountProfiles {
    param([object[]]$Profiles)
    if (-not (Test-Path -LiteralPath $script:LogsRoot)) { [void](New-Item -ItemType Directory -Path $script:LogsRoot -Force) }
    $path = Get-ProfileStorePath
    $temp = '{0}.{1}.tmp' -f $path, ([guid]::NewGuid().ToString('N'))
    (,@($Profiles) | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $path -Force
}

# Build the version label shown on the home screen. Prefers the human-friendly
# version stamped in README.md and appends the short install revision recorded in
# installed-version.txt, which the installer rewrites on every update. Any missing
# piece is simply omitted, so this never blocks the menu.
function Get-AppVersion {
    $friendly = $null
    $readme = Join-Path $script:Root 'README.md'
    if (Test-Path -LiteralPath $readme -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $readme -Raw
            $match = [regex]::Match($raw, '(?m)^\*\*Version:\*\*\s*(\S+)')
            if ($match.Success) { $friendly = $match.Groups[1].Value }
        } catch { }
    }
    $rev = $null
    $verFile = Join-Path $script:Root 'installed-version.txt'
    if (Test-Path -LiteralPath $verFile -PathType Leaf) {
        try {
            $sha = (Get-Content -LiteralPath $verFile -Raw).Trim()
            if ($sha -match '^[0-9a-f]{7,40}$') { $rev = $sha.Substring(0, 7) }
        } catch { }
    }
    if ($friendly -and $rev) { return ('v{0} (rev {1})' -f $friendly, $rev) }
    if ($friendly) { return ('v{0}' -f $friendly) }
    if ($rev) { return ('rev {0}' -f $rev) }
    return 'dev build'
}

function Show-MainMenu {
    Clear-Terminal
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host "          SEEN'S yt-dlp DOWNLOADER" -ForegroundColor White
    Write-Host ('               {0}' -f (Get-AppVersion)) -ForegroundColor DarkGray
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host '  1. Download a video, audio, live, playlist, or social post'
    Write-Host '  2. Download queue'
    Write-Host '  3. View media library sizes'
    Write-Host '  4. View recorded download history'
    Write-Host '  5. Update downloader engines (yt-dlp + gallery-dl)'
    Write-Host '  6. Settings'
    Write-Host '  7. Exit'
    Write-Host ''
}

# --- Per-mode dependency checks --------------------------------------------
# Each check validates and, where possible, self-installs a single dependency,
# returning $true only when the dependency is ready. Resolve-RequestDependencies
# composes just the checks a given mode needs, so entire-post (gallery-dl) mode
# does not require the standalone yt-dlp executable or a JavaScript runtime.

function Test-YtDlpReady {
    if (-not (Test-Path -LiteralPath $script:YtDlp -PathType Leaf)) {
        Write-Host ('yt-dlp.exe was not found beside this script: {0}' -f $script:YtDlp) -ForegroundColor Red
        return $false
    }
    return $true
}

function Test-JsRuntimeReady {
    Update-JsRuntimeState
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
            return $false
        }
        Write-Host 'Node.js is ready.' -ForegroundColor Green
    }
    return $true
}

function Test-FfmpegReady {
    $script:FfmpegAvailable = Test-CommandAvailable -Name 'ffmpeg'
    if (-not $script:FfmpegAvailable) {
        Write-Host 'FFmpeg was not found on PATH.' -ForegroundColor Yellow
        Write-Host 'It is needed for MP3/AAC audio and some high-quality video merges.' -ForegroundColor Yellow
        if (Install-FfmpegLocal) {
            $script:FfmpegAvailable = $true
            Write-Host 'FFmpeg is ready.' -ForegroundColor Green
        } else {
            Write-Host 'Download setup was not completed. Install FFmpeg and try again; library and history remain available.' -ForegroundColor Yellow
            Write-Host 'You can also install it yourself from https://ffmpeg.org/ and add it to PATH.' -ForegroundColor Yellow
            Pause-Terminal
            return $false
        }
    }
    return $true
}

# Validate only the dependencies the chosen mode actually uses.
#   VideoAudio -> yt-dlp + JavaScript runtime + FFmpeg (existing behavior)
#   SocialPost -> gallery-dl + FFmpeg (gallery-dl check lands in Phase 2)
function Resolve-RequestDependencies {
    param([string]$Mode = 'VideoAudio')
    switch ($Mode) {
        'VideoAudio' {
            if (-not (Test-YtDlpReady)) { return $false }
            if (-not (Test-JsRuntimeReady)) { return $false }
            if (-not (Test-FfmpegReady)) { return $false }
            return $true
        }
        'SocialPost' {
            if (-not (Test-GalleryDlReady)) { return $false }
            if (-not (Test-FfmpegReady)) { return $false }
            return $true
        }
        default { return $false }
    }
}

# Backward-compatible entry point: the original full-dependency check maps to the
# existing video/audio workflow.
function Initialize-DownloadDependencies {
    return (Resolve-RequestDependencies -Mode 'VideoAudio')
}

$script:Settings = Get-DownloaderSettings
# Remove any application-owned temporary cookie copies left by a prior crash.
Clear-StaleCookieFiles

while ($true) {
    Show-MainMenu
    $menuChoice = (Read-Host 'Choose an option [1]').Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($menuChoice)) { $menuChoice = '1' }
    switch ($menuChoice) {
        '1' { Start-SmartDownload }
        '2' { Show-DownloadQueue }
        '3' { Show-LibraryReport }
        '4' { Show-DownloadHistory }
        '5' { Update-DownloaderEngine }
        '6' { Show-SettingsMenu }
        '7' { break }
        'Q' { break }
        default {
            Write-Host 'Please choose 1-7.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
    if ($menuChoice -in @('7', 'Q')) { break }
}

Write-Host 'Goodbye.' -ForegroundColor Cyan
