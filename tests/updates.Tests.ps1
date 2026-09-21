Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'smart-downloader.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
function Assert($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
$sandbox = Join-Path $repo ('.test-temp\updates-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$script:Root = $sandbox
$script:RepoOwnerName = 'example/repo'
$script:RepoBranch = 'main'
$script:AppFiles = @('smart-downloader.ps1', "Seen's yt-dlp Downloader.cmd", 'README.md', 'READ ME FIRST.txt')
$script:nextRevision = 'b' * 40
function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) [pscustomobject]@{ sha = $script:nextRevision } }
function Invoke-ReliableDownload {
    param($Url, $Destination)
    Set-Content -LiteralPath $Destination -Value '# new version' -Encoding ASCII
    return $true
}
try {
    Set-Content (Join-Path $sandbox 'smart-downloader.ps1') '# old version'
    Set-Content (Join-Path $sandbox 'installed-version.txt') ('a' * 40)
    $lock = [IO.File]::Open((Join-Path $sandbox 'installed-version.txt'), 'Open', 'Read', 'Read')
    try { Update-AppFromGitHub | Out-Null } finally { $lock.Dispose() }
    Assert ((Get-Content (Join-Path $sandbox 'smart-downloader.ps1')) -eq '# old version') 'revision write failure rolls back app files too'
    Assert ((Get-Content (Join-Path $sandbox 'installed-version.txt')) -eq ('a' * 40)) 'failed update preserves previous revision'
    $setupLock = [IO.File]::Open((Join-Path $sandbox '.setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { $result = Update-AppFromGitHub } finally { $setupLock.Dispose() }
    Assert (-not $result -and (Get-Content (Join-Path $sandbox 'smart-downloader.ps1')) -eq '# old version') 'parallel standalone setup blocks in-app file replacement'
    $script:RestartRequested = $false
    $result = Update-AppFromGitHub
    Assert ($result -and $script:RestartRequested) 'successful app update requests a restart'
    Assert ((Get-Content (Join-Path $sandbox 'installed-version.txt')) -eq $script:nextRevision) 'app and revision are committed together'
    $script:RestartRequested = $false
    Assert (-not (Update-AppFromGitHub) -and -not $script:RestartRequested) 'already-current app does not restart'

    $script:Settings = [pscustomobject]@{ CheckForUpdates = $true }
    $script:checks = 0; $script:offers = 0; $script:updates = 0
    $script:startupRevision = 'c' * 40
    function Get-StartupUpdateRevision { $script:checks++; return $script:startupRevision }
    function Read-MenuChoice { param($Title, $Options, $DefaultValue) $script:offers++; return $script:choice }
    function Update-DownloaderEngine { param($Revision) if ($Revision -ne $script:startupRevision) { throw 'Update lost the checked revision' }; $script:updates++ }
    $script:choice = 'Later'
    Invoke-StartupUpdateCheck
    Assert ($script:offers -eq 1 -and $script:updates -eq 0) 'startup offers a new version but Later never installs it'
    $script:choice = 'Update'
    Invoke-StartupUpdateCheck
    Assert ($script:updates -eq 1) 'startup Update choice passes the checked revision to the full installer'
    $script:startupRevision = $script:nextRevision
    Invoke-StartupUpdateCheck
    Assert ($script:offers -eq 2) 'current version does not prompt'
    $script:startupRevision = $null
    Invoke-StartupUpdateCheck
    Assert ($script:offers -eq 2) 'offline check does not prompt or block the menu'
    $script:Settings.CheckForUpdates = $false
    $previousChecks = $script:checks
    Invoke-StartupUpdateCheck
    Assert ($script:checks -eq $previousChecks) 'disabled startup setting makes no network check'
} finally {
    if ((Split-Path -Parent $sandbox) -eq [IO.Path]::GetFullPath((Join-Path $repo '.test-temp')) -and (Split-Path -Leaf $sandbox) -match '^updates-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
