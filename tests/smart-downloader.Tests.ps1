[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$downloaderPath = Join-Path $projectRoot 'smart-downloader.ps1'
$fakeYtDlpPath = Join-Path $PSScriptRoot 'fixtures\fake-yt-dlp.cmd'
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        $script:failures.Add($Message)
        Write-Host ("FAIL: {0}" -f $Message) -ForegroundColor Red
    } else {
        Write-Host ("PASS: {0}" -f $Message) -ForegroundColor Green
    }
}

# Load the downloader functions without taking an interactive menu action.
$script:loadingDownloader = $true
function Clear-Host {}
function Read-Host {
    param([string]$Prompt)
    if ($script:loadingDownloader) { return '6' }
    if ($script:promptAnswers.Count -eq 0) { return '' }
    return $script:promptAnswers.Dequeue()
}
. $downloaderPath *> $null
$script:loadingDownloader = $false

$testRoot = Join-Path $projectRoot '.test-temp\regression'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $testRoot -Force)

$acceptsEmptyPaths = $true
try {
    $emptyPaths = New-Object System.Collections.Generic.List[string]
    [void](Resolve-CompletedFiles -ReportedPaths $emptyPaths -TargetFolder $testRoot -Before @{})
} catch {
    $acceptsEmptyPaths = $false
}
Assert-True -Condition $acceptsEmptyPaths -Message 'download result handling accepts no reported output paths'

$acceptsEmptyFiles = $true
try {
    Show-FileList -Files @() *> $null
} catch {
    $acceptsEmptyFiles = $false
}
Assert-True -Condition $acceptsEmptyFiles -Message 'download result display accepts an empty completed-file list'

$script:YtDlp = $fakeYtDlpPath
$script:DownloadsRoot = Join-Path $testRoot 'Downloads'
$script:LogsRoot = Join-Path $testRoot 'logs'
$script:HistoryPath = Join-Path $script:LogsRoot 'download-history.csv'
$script:promptAnswers = New-Object System.Collections.Generic.Queue[string]
# Prompt order: URL, format ('' -> mp4), video quality ('' -> best), live mode (N -> normal).
$script:promptAnswers.Enqueue('https://www.youtube.com/watch?v=yxf9w1gJea4')
$script:promptAnswers.Enqueue('')
$script:promptAnswers.Enqueue('')
$script:promptAnswers.Enqueue('N')
$script:promptAnswers.Enqueue('')

$originalConsoleOut = [Console]::Out
$terminalWriter = New-Object System.IO.StringWriter
[Console]::SetOut($terminalWriter)
try {
    $downloadOutput = Start-SmartDownload *>&1 | Out-String
} finally {
    [Console]::SetOut($originalConsoleOut)
}
$terminalOutput = $terminalWriter.ToString()
$capturedProgressRows = @(
    $downloadOutput -split "`r?`n" |
        Where-Object { $_ -match '^\[download\]\s+\d+(?:\.\d+)?%' }
)
$carriageReturnUpdates = [regex]::Matches($terminalOutput, "`r\[download\]\s+\d+(?:\.\d+)?%").Count
Assert-True -Condition ($downloadOutput -match '(?m)^ARGS:.*--js-runtimes\s+node(?:\s|$)') -Message 'download enables the installed Node.js runtime for YouTube extraction'
Assert-True -Condition ($downloadOutput -match '(?m)^ARGS:.*--progress(?:\s|$)') -Message 'download explicitly restores yt-dlp progress output'
Assert-True -Condition ($downloadOutput -match '(?m)^ARGS:.*--newline(?:\s|$)') -Message 'download emits line-oriented progress through the PowerShell pipeline'
Assert-True -Condition ($capturedProgressRows.Count -le 1) -Message 'progress refreshes do not create newline-separated terminal spam'
Assert-True -Condition ($carriageReturnUpdates -ge 2) -Message 'progress refreshes overwrite one terminal status line'
Assert-True -Condition ($downloadOutput -notmatch 'Could not update download history') -Message 'successful download records history without a Generic.List conversion error'
Assert-True -Condition (Test-Path -LiteralPath $script:HistoryPath -PathType Leaf) -Message 'successful download creates the history CSV'
Assert-True -Condition ($downloadOutput -notmatch 'height<=') -Message 'best-quality video download does not add a resolution ceiling'
Assert-True -Condition ($null -ne (Get-Command Read-VideoQuality -ErrorAction SilentlyContinue)) -Message 'video quality picker is available'
Assert-True -Condition ($null -ne $script:JsRuntime) -Message 'a JavaScript runtime (node or deno) is detected'
Assert-True -Condition ($null -ne (Get-Command Install-NodeRuntime -ErrorAction SilentlyContinue)) -Message 'node auto-install helper is available'
Assert-True -Condition ($null -ne (Get-Command Install-FfmpegLocal -ErrorAction SilentlyContinue)) -Message 'ffmpeg auto-download helper is available'

# Settings persistence: default off, and a saved value round-trips through disk.
$originalSettingsPath = $script:SettingsPath
$script:SettingsPath = Join-Path $testRoot 'settings.json'
if (Test-Path -LiteralPath $script:SettingsPath) { Remove-Item -LiteralPath $script:SettingsPath -Force }
$defaultSettings = Get-DownloaderSettings
Assert-True -Condition ($defaultSettings.OpenFolderAfterDownload -eq $false) -Message 'settings default to auto-open disabled when no file exists'
$defaultSettings.OpenFolderAfterDownload = $true
Save-DownloaderSettings -Settings $defaultSettings
$reloadedSettings = Get-DownloaderSettings
Assert-True -Condition ($reloadedSettings.OpenFolderAfterDownload -eq $true) -Message 'a saved auto-open setting round-trips through disk'
$script:SettingsPath = $originalSettingsPath

# Explorer launch decision: highlight a single file, open the folder otherwise.
$singleFile = @([pscustomobject]@{ FullName = (Join-Path $testRoot 'only.mp4') })
$singleLaunch = Get-ExplorerLaunch -Files $singleFile -TargetFolder $testRoot
Assert-True -Condition ($singleLaunch -eq ('/select,"{0}"' -f (Join-Path $testRoot 'only.mp4'))) -Message 'a single completed file is highlighted in Explorer'
$manyFiles = @(
    [pscustomobject]@{ FullName = (Join-Path $testRoot 'a.mp4') },
    [pscustomobject]@{ FullName = (Join-Path $testRoot 'b.mp4') }
)
$manyLaunch = Get-ExplorerLaunch -Files $manyFiles -TargetFolder $testRoot
Assert-True -Condition ($manyLaunch -eq ('"{0}"' -f $testRoot)) -Message 'multiple completed files open the download folder'
$emptyLaunch = Get-ExplorerLaunch -Files @() -TargetFolder $testRoot
Assert-True -Condition ($emptyLaunch -eq ('"{0}"' -f $testRoot)) -Message 'no completed files open the download folder'
Assert-True -Condition ($null -ne (Get-Command Show-SettingsMenu -ErrorAction SilentlyContinue)) -Message 'settings menu screen is available'

$startupOutput = @('6') | & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $downloaderPath 2>&1 | Out-String
$startupExitCode = $LASTEXITCODE
Assert-True -Condition ($startupExitCode -eq 0) -Message 'redirected/non-interactive startup exits cleanly'
Assert-True -Condition ($startupOutput -notmatch 'CursorPosition') -Message 'redirected startup does not fail while clearing the screen'

$paginationHelpersAvailable = (
    $null -ne (Get-Command Get-PageInfo -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command ConvertTo-PageCommand -ErrorAction SilentlyContinue)
)
Assert-True -Condition $paginationHelpersAvailable -Message 'pagination helpers are available'

if ($paginationHelpersAvailable) {
    $emptyPage = Get-PageInfo -Items @() -PageIndex 0 -PageSize 5
    Assert-True -Condition ($emptyPage.PageCount -eq 1 -and $emptyPage.Items.Count -eq 0) -Message 'empty pagination has one empty page'

    $exactPage = Get-PageInfo -Items @(1, 2, 3, 4, 5) -PageIndex 0 -PageSize 5
    Assert-True -Condition ($exactPage.PageCount -eq 1 -and $exactPage.Items.Count -eq 5) -Message 'five entries fit on one page'

    $secondPage = Get-PageInfo -Items @(1, 2, 3, 4, 5, 6) -PageIndex 1 -PageSize 5
    Assert-True -Condition ($secondPage.PageCount -eq 2 -and $secondPage.StartIndex -eq 5 -and $secondPage.Items[0] -eq 6) -Message 'six entries produce a one-item second page'

    $clampedLastPage = Get-PageInfo -Items @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11) -PageIndex 99 -PageSize 5
    Assert-True -Condition ($clampedLastPage.PageIndex -eq 2 -and $clampedLastPage.PageCount -eq 3 -and $clampedLastPage.Items[0] -eq 11) -Message 'out-of-range pagination clamps to the final page'

    $clampedFirstPage = Get-PageInfo -Items @(1, 2, 3, 4, 5, 6) -PageIndex -4 -PageSize 5
    Assert-True -Condition ($clampedFirstPage.PageIndex -eq 0 -and $clampedFirstPage.Items[0] -eq 1) -Message 'negative pagination clamps to the first page'

    Assert-True -Condition ((ConvertTo-PageCommand -InputValue 'LeftArrow') -eq 'Previous') -Message 'Left Arrow maps to the previous page'
    Assert-True -Condition ((ConvertTo-PageCommand -InputValue 'P') -eq 'Previous') -Message 'P maps to the previous page'
    Assert-True -Condition ((ConvertTo-PageCommand -InputValue 'RightArrow') -eq 'Next') -Message 'Right Arrow maps to the next page'
    Assert-True -Condition ((ConvertTo-PageCommand -InputValue 'n') -eq 'Next') -Message 'N maps to the next page case-insensitively'
    Assert-True -Condition ((ConvertTo-PageCommand -InputValue 'Enter') -eq 'Exit') -Message 'Enter exits pagination'
    Assert-True -Condition ((ConvertTo-PageCommand -InputValue 'Escape') -eq 'Exit') -Message 'Escape exits pagination'
    Assert-True -Condition ((ConvertTo-PageCommand -InputValue 'Q') -eq 'Exit') -Message 'Q exits pagination'

    $fallbackCommand = Read-PageCommand
    Assert-True -Condition ($fallbackCommand -eq 'Exit') -Message 'redirected input falls back to a blank-to-exit text command'
}

$fakeLibraryFiles = @(
    1..6 | ForEach-Object {
        [pscustomobject]@{
            Length        = [long]($_ * 1000)
            LastWriteTime = [datetime]'2026-07-20T12:00:00'
            FullName      = Join-Path $testRoot ('library-{0}.mp4' -f $_)
        }
    }
)
function Get-MediaFiles { return @($fakeLibraryFiles) }
function Clear-Terminal {
    $script:clearTerminalCalls++
}
function Read-PageCommand {
    if ($script:pageCommands.Count -eq 0) { return 'Exit' }
    return $script:pageCommands.Dequeue()
}

$script:clearTerminalCalls = 0
$script:pageCommands = New-Object System.Collections.Generic.Queue[string]
$script:pageCommands.Enqueue('Previous')
$script:pageCommands.Enqueue('Next')
$script:pageCommands.Enqueue('Next')
$script:pageCommands.Enqueue('Previous')
$script:pageCommands.Enqueue('Exit')
$libraryOutput = Show-LibraryReport *>&1 | Out-String
$libraryRenders = @($libraryOutput -split 'Media library - biggest to smallest' | Where-Object { $_ -match 'Page \d+ of \d+' })
Assert-True -Condition ($libraryOutput -match 'Page 1 of 2' -and $libraryOutput -match 'Page 2 of 2') -Message 'media library renders two five-item pages'
Assert-True -Condition ($libraryRenders[0] -notmatch 'library-1\.mp4' -and $libraryRenders[1] -match 'library-1\.mp4') -Message 'media library limits the first page to five files'
Assert-True -Condition ($script:clearTerminalCalls -eq 3) -Message 'page-boundary commands do not cause unnecessary redraws'
Assert-True -Condition ($libraryOutput -match 'Total: 6 files') -Message 'media library keeps the full-list total on paged output'

$historyRows = @(
    1..6 | ForEach-Object {
        [pscustomobject][ordered]@{
            TimestampLocal = '2026-07-20T12:00:00+07:00'
            Url            = 'https://example.test/history-{0}' -f $_
            Preset         = 'mp4'
            LiveMode       = 'Normal'
            PlaylistMode   = 'Single'
            Status         = 'Completed'
            FilePath       = Join-Path $testRoot ('history-{0}.mp4' -f $_)
            SizeBytes      = [long]($_ * 1000)
        }
    }
)
$script:HistoryPath = Join-Path $testRoot 'paged-history.csv'
$historyRows | Export-Csv -LiteralPath $script:HistoryPath -NoTypeInformation -Encoding UTF8
$script:clearTerminalCalls = 0
$script:pageCommands = New-Object System.Collections.Generic.Queue[string]
$script:pageCommands.Enqueue('Next')
$script:pageCommands.Enqueue('Previous')
$script:pageCommands.Enqueue('Exit')
$historyOutput = Show-DownloadHistory *>&1 | Out-String
$historyRenders = @($historyOutput -split 'Download history - biggest to smallest' | Where-Object { $_ -match 'Page \d+ of \d+' })
Assert-True -Condition ($historyOutput -match 'Page 1 of 2' -and $historyOutput -match 'Page 2 of 2') -Message 'download history renders five records per page'
Assert-True -Condition ($historyRenders[0] -notmatch 'history-1(?:\s|$)' -and $historyRenders[1] -match 'history-1(?:\s|$)') -Message 'download history limits the first page to five records'
Assert-True -Condition ($script:clearTerminalCalls -eq 3) -Message 'history redraws when moving forward and backward'
Assert-True -Condition ($historyOutput -match 'Recorded outputs: 6 files') -Message 'download history keeps the full-list total on every page'

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host ("{0} regression test(s) failed." -f $failures.Count) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All regression tests passed.' -ForegroundColor Green
Remove-Item -LiteralPath $testRoot -Recurse -Force
