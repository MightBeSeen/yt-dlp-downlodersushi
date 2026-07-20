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
    if ($script:loadingDownloader) { return '4' }
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
$script:promptAnswers.Enqueue('https://www.youtube.com/watch?v=yxf9w1gJea4')
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
Assert-True -Condition ($downloadOutput -match '(?m)^ARGS:.*--progress(?:\s|$)') -Message 'download explicitly restores yt-dlp progress output'
Assert-True -Condition ($downloadOutput -match '(?m)^ARGS:.*--newline(?:\s|$)') -Message 'download emits line-oriented progress through the PowerShell pipeline'
Assert-True -Condition ($capturedProgressRows.Count -le 1) -Message 'progress refreshes do not create newline-separated terminal spam'
Assert-True -Condition ($carriageReturnUpdates -ge 2) -Message 'progress refreshes overwrite one terminal status line'
Assert-True -Condition ($downloadOutput -notmatch 'Could not update download history') -Message 'successful download records history without a Generic.List conversion error'
Assert-True -Condition (Test-Path -LiteralPath $script:HistoryPath -PathType Leaf) -Message 'successful download creates the history CSV'

$startupOutput = @('4') | & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $downloaderPath 2>&1 | Out-String
$startupExitCode = $LASTEXITCODE
Assert-True -Condition ($startupExitCode -eq 0) -Message 'redirected/non-interactive startup exits cleanly'
Assert-True -Condition ($startupOutput -notmatch 'CursorPosition') -Message 'redirected startup does not fail while clearing the screen'

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host ("{0} regression test(s) failed." -f $failures.Count) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All regression tests passed.' -ForegroundColor Green
Remove-Item -LiteralPath $testRoot -Recurse -Force
