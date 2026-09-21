param([string]$Target)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $env:SEEN_TEST_SOURCE 'smart-downloader.ps1'), [ref]$tokens, [ref]$errors)
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$script:Root = $Target
$script:RepoOwnerName = 'MightBeSeen/yt-dlp-downlodersushi'
$script:RepoBranch = 'stable'
$script:DownloadQueue = New-Object 'System.Collections.Generic.List[object]'
$script:RestartRequested = $false
function Clear-Terminal {}
function Pause-Terminal { throw 'Unexpected error/pause during successful in-app update' }
function Invoke-ReliableDownload {
    param($Url, $Destination)
    if ($Url -notmatch '/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/Install%20Seen%20Downloader.cmd$') { throw "Installer revision was not pinned: $Url" }
    $text = [IO.File]::ReadAllText((Join-Path $env:SEEN_TEST_SOURCE 'Install Seen Downloader.cmd'))
    $text = $text.Replace('# --- Main flow', '. (Join-Path $env:SEEN_TEST_SOURCE "tests\fixtures\installer-downloads.ps1")' + "`r`n# --- Main flow")
    [IO.File]::WriteAllText($Destination, $text)
    return $true
}
Update-DownloaderEngine -Revision ('b' * 40)
if (-not $script:RestartRequested) { throw 'Successful in-app update did not request a restart' }
