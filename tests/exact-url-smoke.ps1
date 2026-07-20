[CmdletBinding()]
param(
    [string]$Url = 'https://www.youtube.com/watch?v=yxf9w1gJea4',
    [switch]$KeepArtifacts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$downloaderPath = Join-Path $projectRoot 'smart-downloader.ps1'
$script:answers = New-Object System.Collections.Generic.Queue[string]

function Clear-Host {}
function Read-Host {
    param([string]$Prompt)
    if ($script:answers.Count -eq 0) { return '' }
    return $script:answers.Dequeue()
}

# Load the production functions, choosing Exit at the initial menu.
$script:answers.Enqueue('4')
. $downloaderPath *> $null

$liveRoot = Join-Path $projectRoot ('.test-temp\live-exact-url-{0}' -f [guid]::NewGuid().ToString('N'))
$script:DownloadsRoot = Join-Path $liveRoot 'Downloads'
$script:LogsRoot = Join-Path $liveRoot 'logs'
$script:HistoryPath = Join-Path $script:LogsRoot 'download-history.csv'

# AAC keeps this live network test small while exercising the complete wrapper path.
$script:answers = New-Object System.Collections.Generic.Queue[string]
$script:answers.Enqueue($Url)
$script:answers.Enqueue('4')
$script:answers.Enqueue('N')
$script:answers.Enqueue('')

try {
    $originalConsoleOut = [Console]::Out
    $terminalWriter = New-Object System.IO.StringWriter
    [Console]::SetOut($terminalWriter)
    try {
        $output = Start-SmartDownload *>&1 | Out-String
    } finally {
        [Console]::SetOut($originalConsoleOut)
    }
    $terminalOutput = $terminalWriter.ToString()
    $progressLines = @(
        $terminalOutput -split "`r|`n" |
            Where-Object { $_ -match '^\[download\].*%.*(?:KiB|MiB|GiB).*at\s+.*(?:ETA|in\s)' }
    )
    $newlineProgressRows = [regex]::Matches($terminalOutput, "`n\[download\]\s+\d+(?:\.\d+)?%").Count
    $historyExists = Test-Path -LiteralPath $script:HistoryPath -PathType Leaf
    $media = @(
        Get-ChildItem -LiteralPath $script:DownloadsRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.aac', '.m4a') }
    )
    $hasFailure = $output -match 'Could not update download history|yt-dlp failed'

    if ($progressLines.Count -eq 0 -or $newlineProgressRows -gt 0 -or -not $historyExists -or $media.Count -eq 0 -or $hasFailure) {
        Write-Host 'LIVE_SMOKE_TEST: FAIL' -ForegroundColor Red
        Write-Host $output
        throw 'Live smoke test assertions failed.'
    }

    Write-Host 'LIVE_SMOKE_TEST: PASS' -ForegroundColor Green
    Write-Host 'Progress samples:'
    $progressLines | Select-Object -First 2
    if ($progressLines.Count -gt 2) {
        $progressLines | Select-Object -Last 2
    }
    Write-Host ('History CSV: {0}' -f $script:HistoryPath)
    Write-Host ('Media: {0} ({1} bytes)' -f $media[0].FullName, $media[0].Length)
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $liveRoot)) {
        Remove-Item -LiteralPath $liveRoot -Recurse -Force
        Write-Host 'Temporary live-test artifacts removed.' -ForegroundColor DarkGray
    }
}
