Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$text = [IO.File]::ReadAllText((Join-Path $root 'Install Yt-dlp Downloader.cmd'))
$source = ($text -split '(?m)^# POWERSHELL START\r?$', 2)[1]
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
function Assert($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
$tempRoot = Join-Path $root ('.test-temp\installer-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $stage = $tempRoot
    Set-Content (Join-Path $stage 'node-index.json') '[{"version":"v26.0.0","lts":false,"files":["win-x64-zip"]},{"version":"v24.1.0","lts":"LTS","files":["win-x64-zip"]},{"version":"v22.1.0","lts":"Older","files":["win-x64-zip"]}]'
    $nodeAssignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$node' }, $true)
    . ([scriptblock]::Create($nodeAssignment.Extent.Text))
    Assert (@($node).Count -eq 1 -and $node.version -eq 'v24.1.0') 'selects one latest LTS release on both PowerShell versions'
    $file = Join-Path $tempRoot 'engine.exe'
    Set-Content -LiteralPath $file -Value 'verified download'
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    Assert-SetupHash $file "$hash *engine.exe" 'engine.exe'
    Assert $true 'published checksum accepted'
    foreach ($checksums in @("$('0' * 64)  engine.exe", "$hash  other.exe")) {
        $rejected = $false
        try { Assert-SetupHash $file $checksums 'engine.exe' } catch { $rejected = $true }
        Assert $rejected 'wrong or missing checksum rejected'
    }

    # Simulate an existing installation with personal data and an obsolete app.
    $target = Join-Path $tempRoot "Installed app with spaces & apostrophe's"
    New-Item -ItemType Directory -Path $target | Out-Null
    Set-Content (Join-Path $target 'app.ps1') 'old app'
    foreach ($folder in @('Downloads', 'logs')) {
        New-Item -ItemType Directory -Path (Join-Path $target $folder) | Out-Null
        Set-Content (Join-Path $target "$folder\keep.txt") 'personal data'
    }
    $stage = Join-Path $tempRoot 'success'
    New-Item -ItemType Directory -Path $stage | Out-Null
    Set-Content (Join-Path $stage 'app.ps1') 'new app'
    Set-Content (Join-Path $stage 'node.exe') 'new helper'
    Install-SetupFiles $stage $target @('app.ps1', 'node.exe')
    Assert ((Get-Content (Join-Path $target 'app.ps1')) -eq 'new app') 'update replaces app'
    Assert ((Get-Content (Join-Path $target 'node.exe')) -eq 'new helper') 'update adds helper'
    foreach ($folder in @('Downloads', 'logs')) {
        Assert ((Get-Content (Join-Path $target "$folder\keep.txt")) -eq 'personal data') "$folder preserved"
    }

    $stage = Join-Path $tempRoot 'failure'
    New-Item -ItemType Directory -Path $stage | Out-Null
    Set-Content (Join-Path $stage 'app.ps1') 'broken update'
    Set-Content (Join-Path $stage 'extra.exe') 'temporary addition'
    $failed = $false
    try { Install-SetupFiles $stage $target @('app.ps1', 'extra.exe', 'missing.exe') } catch { $failed = $true }
    Assert $failed 'mid-install copy failure is reported'
    Assert ((Get-Content (Join-Path $target 'app.ps1')) -eq 'new app') 'failed update restores previous app'
    Assert (-not (Test-Path (Join-Path $target 'extra.exe'))) 'failed update removes partial additions'

    # Exercise retry behavior without network access or delays.
    $script:attempts = 0
    function Invoke-SetupTransfer {
        param($Url, $Destination, $Headers, $IdleTimeoutSec, $TimeoutSec)
        $script:attempts++
        if ($script:attempts -lt 3) { throw 'network disconnected' }
        Set-Content -LiteralPath $Destination 'downloaded'
    }
    function Start-Sleep { param($Seconds) }
    Get-SetupFile 'https://example.invalid/file' (Join-Path $tempRoot 'retry.txt')
    Assert ($script:attempts -eq 3) 'transient download failures retry successfully'
    $script:attempts = 0
    function Invoke-SetupTransfer {
        param($Url, $Destination, $Headers, $IdleTimeoutSec, $TimeoutSec)
        $script:attempts++
        Set-Content -LiteralPath $Destination 'partial data'
        throw 'offline'
    }
    $failed = $false
    try { Get-SetupFile 'https://example.invalid/file' (Join-Path $tempRoot 'offline.txt') } catch { $failed = $true }
    Assert ($failed -and $script:attempts -eq 3) 'permanent download failure stops after three attempts'
    Assert (-not (Test-Path (Join-Path $tempRoot 'offline.txt.part'))) 'failed transfer removes partial file'
    Assert (-not (Test-Path (Join-Path $tempRoot 'offline.txt'))) 'failed transfer never publishes a completed file'

    # Exercise real FFmpeg source selection and hash validation with fake transports.
    $script:urls = @()
    $script:fixtureHash = $hash
    $script:badGithubHash = $false
    function Invoke-SetupTransfer {
        param($Url, $Destination, $Headers, $IdleTimeoutSec, $TimeoutSec)
        $script:urls += $Url
        if ($Url -match '/releases/latest$') {
            if (-not $script:badGithubHash) { throw 'HTTP 503' }
            Set-Content -LiteralPath $Destination ('{"assets":[{"name":"ffmpeg-9.0-essentials_build.zip","digest":"sha256:' + ('0' * 64) + '","browser_download_url":"https://github.com/GyanD/codexffmpeg/releases/download/9.0/ffmpeg-9.0-essentials_build.zip"}]}')
        } elseif ($Url -like '*.sha256') {
            Set-Content -LiteralPath $Destination $script:fixtureHash
        } else {
            Copy-Item -LiteralPath $file -Destination $Destination
        }
    }
    [void](Get-SetupFfmpeg $tempRoot)
    Assert ($script:urls[-1] -like 'https://www.gyan.dev/*zip') 'FFmpeg switches publisher hosts when GitHub is unavailable'
    Assert ((Get-FileHash (Join-Path $tempRoot 'ffmpeg.zip')).Hash -eq $hash) 'fallback FFmpeg ZIP is hash verified'
    $script:badGithubHash = $true
    $script:urls = @()
    [void](Get-SetupFfmpeg $tempRoot)
    Assert ($script:urls.Count -eq 4 -and $script:urls[-1] -like 'https://www.gyan.dev/*zip') 'corrupt GitHub ZIP triggers independently verified fallback'

    $helper = (Get-Command powershell.exe).Source
    Test-SetupHelper $helper '-NoProfile -Command "Write-Output fixture-version"'
    $failed = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { Test-SetupHelper $helper '-NoProfile -Command "Start-Sleep -Seconds 30"' -TimeoutSec 1 } catch { $failed = $_.Exception.Message -match 'did not respond' }
    Assert ($failed -and $clock.Elapsed.TotalSeconds -lt 5) 'unresponsive helper is terminated promptly'
    $failed = $false
    try { Test-SetupHelper $helper '-NoProfile -Command "exit 2"' } catch { $failed = $_.Exception.Message -match 'could not run' }
    Assert $failed 'helper exit failure rejects installation'
    $failed = $false
    try { Test-SetupHelper (Join-Path $tempRoot 'missing-helper.exe') } catch { $failed = $_.Exception.Message -notmatch 'Id|HasExited' }
    Assert $failed 'helper startup failure preserves original error'
    # gallery-dl is staged as a first-class helper: downloaded, run-tested, and
    # included in the atomic install set (it has no checksum to verify).
    $gallery = Get-SetupGalleryRelease
    Assert ($gallery.Url -match '/v1\.32\.13/gallery-dl\.exe$' -and $gallery.Sha256 -match '^[a-f0-9]{64}$') 'installer pins gallery-dl version and SHA256'
    Assert ($source -match "foreach \(\`$name in @\('yt-dlp\.exe'[^\)]*'gallery-dl\.exe'\)") 'installer run-tests gallery-dl.exe with the other helpers'
    Assert ($source -match "\`$names = \`$appFiles \+ @\([^\)]*'gallery-dl\.exe'[^\)]*'GalleryDl-LICENSE\.txt'") 'installer installs gallery-dl.exe and its license notice'

    $cacheTarget = Join-Path $tempRoot 'cache-target'
    $cacheStage = Join-Path $tempRoot 'cache-stage'
    New-Item -ItemType Directory -Path $cacheTarget,$cacheStage | Out-Null
    Set-Content (Join-Path $cacheTarget 'node.exe') 'working binary'
    $records = @{ node = (New-SetupHelperRecord $cacheTarget 'v1' @('node.exe')) }
    $records | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $cacheTarget 'installed-helpers.json')
    Assert (Copy-SetupCachedGroup $cacheTarget $cacheStage 'node' 'v1' @('node.exe')) 'same verified helper package is reused'
    Assert (-not (Copy-SetupCachedGroup $cacheTarget $cacheStage 'node' 'v2' @('node.exe'))) 'new helper version forces a download'
    Set-Content (Join-Path $cacheTarget 'node.exe') 'damaged binary'
    Assert (-not (Copy-SetupCachedGroup $cacheTarget $cacheStage 'node' 'v1' @('node.exe'))) 'changed or corrupt helper is not reused'
    Write-Host 'Installer tests passed.' -ForegroundColor Green
} finally {
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $root '.test-temp'))
    if ((Split-Path -Parent $tempRoot) -eq $expectedParent -and (Split-Path -Leaf $tempRoot) -match '^installer-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
