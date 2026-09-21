Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$tokens = $null; $errors = $null
$root = Split-Path $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'smart-downloader.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$script:failures = New-Object System.Collections.Generic.List[string]
function Assert($Condition, $Message) {
    if (-not $Condition) { $script:failures.Add($Message); Write-Host "FAIL: $Message" -ForegroundColor Red }
    else { Write-Host "PASS: $Message" -ForegroundColor Green }
}

# Sandbox script state.
$sandbox = Join-Path $root ('.test-temp\social-' + [guid]::NewGuid().ToString('N'))
$script:Root = $root
$script:DownloadsRoot = Join-Path $sandbox 'Downloads'
$script:LogsRoot = Join-Path $sandbox 'logs'
$script:HistoryPath = Join-Path $script:LogsRoot 'download-history.csv'
$script:GalleryDl = Join-Path $PSScriptRoot 'fixtures\fake-gallery-dl.cmd'
$script:Settings = [pscustomobject]@{ OpenFolderAfterDownload = $false }
$script:ImageExtensions = @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif')
$script:MediaExtensions = @('.mp4', '.mkv', '.webm', '.mov', '.mp3', '.m4a', '.aac') + $script:ImageExtensions
New-Item -ItemType Directory -Path $script:LogsRoot -Force | Out-Null

function Clear-Terminal {}
function Pause-Terminal {}

# --- Platform detection -----------------------------------------------------
Assert ((Get-UrlPlatform 'https://www.instagram.com/p/ABC123/') -eq 'instagram') 'detects Instagram'
Assert ((Get-UrlPlatform 'https://vm.tiktok.com/ZMabc/') -eq 'tiktok') 'detects TikTok short host'
Assert ((Get-UrlPlatform 'https://x.com/user/status/123') -eq 'x') 'detects X'
Assert ((Get-UrlPlatform 'https://twitter.com/user/status/123') -eq 'x') 'detects legacy twitter.com as X'
Assert ((Get-UrlPlatform 'https://www.facebook.com/watch/?v=123') -eq 'facebook') 'detects Facebook'
Assert ((Get-UrlPlatform 'https://youtu.be/abc') -eq 'youtube') 'detects YouTube'
Assert ($null -eq (Get-UrlPlatform 'https://example.com/x')) 'unknown host yields null platform'
Assert ($null -eq (Get-UrlPlatform 'not a url')) 'non-URL yields null platform'

# --- Post id extraction -----------------------------------------------------
Assert ((Get-PostIdFromUrl 'https://x.com/u/status/1789' 'x') -eq '1789') 'x status id'
Assert ((Get-PostIdFromUrl 'https://www.tiktok.com/@u/video/6677' 'tiktok') -eq '6677') 'tiktok video id'
Assert ((Get-PostIdFromUrl 'https://www.instagram.com/reel/CxYz_1/' 'instagram') -eq 'CxYz_1') 'instagram reel shortcode'
Assert ((Get-PostIdFromUrl 'https://www.facebook.com/watch/?v=99887' 'facebook') -eq '99887') 'facebook v param id'
Assert ($null -eq (Get-PostIdFromUrl 'https://x.com/u' 'x')) 'no id for a profile url'

# --- Collection rejection ---------------------------------------------------
Assert (Test-IsCollectionUrl 'https://x.com/someuser' 'x') 'x profile is a collection'
Assert (-not (Test-IsCollectionUrl 'https://x.com/someuser/status/1' 'x')) 'x status is not a collection'
Assert (Test-IsCollectionUrl 'https://www.instagram.com/someuser/' 'instagram') 'instagram profile is a collection'
Assert (-not (Test-IsCollectionUrl 'https://www.instagram.com/p/ABC/' 'instagram') ) 'instagram post is not a collection'
Assert (Test-IsCollectionUrl 'https://www.tiktok.com/@someuser' 'tiktok') 'tiktok profile is a collection'
Assert (-not (Test-IsCollectionUrl 'https://www.tiktok.com/@u/video/6' 'tiktok')) 'tiktok video is not a collection'

# --- Request builder --------------------------------------------------------
$req = New-SocialPostRequest -Url 'https://x.com/u/status/42' -Account $null
Assert ($null -ne $req -and $req.Platform -eq 'x' -and $req.PostId -eq '42' -and $req.Mode -eq 'SocialPost') 'builds an X single-post request'
Assert ($req.TargetFolder -eq (Join-Path (Join-Path $script:DownloadsRoot (Get-Date).ToString('yyyy-MM-dd')) 'x')) 'target folder is Downloads/date/platform without post id'
Assert ((Get-SocialPostFolder -StartedAt ([datetime]'2026-09-21') -Platform 'x' -PostId '42' -RequestId 'first') -eq (Get-SocialPostFolder -StartedAt ([datetime]'2026-09-21') -Platform 'x' -PostId '99' -RequestId 'second')) 'different posts on the same day share the platform folder'
Assert (-not $req.IncludeManifest) 'media-only is the default'
function Read-MenuChoice { param($Title, $Options, $DefaultValue) throw "Unexpected mode prompt: $Title" }
Assert ((Read-DownloadMode -Url 'https://x.com/u/status/42/photo/1') -eq 'SocialPost') 'X photo routes automatically without mode prompt'
Assert ((Read-DownloadMode -Url 'https://twitter.com/u/status/42' -DefaultValue 'VideoAudio') -eq 'SocialPost') 'plain Twitter post routes automatically regardless of last mode'
Assert ((Read-DownloadMode -Url 'https://youtu.be/abc' -DefaultValue 'SocialPost') -eq 'VideoAudio') 'YouTube routes to video/audio regardless of last mode'
$rejected = New-SocialPostRequest -Url 'https://x.com/someuser' -Account $null
Assert ($null -eq $rejected) 'collection URL is rejected'
$unknown = New-SocialPostRequest -Url 'https://youtu.be/abc' -Account $null
Assert ($null -eq $unknown) 'YouTube is rejected in entire-post mode'

# --- Config file ------------------------------------------------------------
$cfgPath = New-GalleryDlConfigFile -Platform 'instagram'
$cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
Assert (($cfg.extractor.'sleep-request'[0] -eq 6) -and ($cfg.extractor.'sleep-request'[1] -eq 12)) 'instagram pacing is 6-12s'
Assert ($null -eq (Get-PropertyValue -InputObject $cfg.extractor -Name 'cookies')) 'anonymous config has no cookies key'
Remove-Item -LiteralPath $cfgPath -Force
$cfgPath2 = New-GalleryDlConfigFile -Platform 'x' -CookiePath 'C:\tmp\c.txt'
$cfg2 = Get-Content -Raw -LiteralPath $cfgPath2 | ConvertFrom-Json
Assert ($cfg2.extractor.cookies -eq 'C:\tmp\c.txt' -and $cfg2.extractor.'sleep-request'[0] -eq 3) 'cookie path and default pacing are written'
Remove-Item -LiteralPath $cfgPath2 -Force

# --- Status mapping ---------------------------------------------------------
Assert ((Get-SocialPostStatus -ExitCode 0 -Interrupted $false -Blocked $false -CompletedCount 3) -eq 'Completed') 'exit 0 => Completed'
Assert ((Get-SocialPostStatus -ExitCode 1 -Interrupted $false -Blocked $false -CompletedCount 2) -eq 'Partial') 'exit!=0 with files => Partial'
Assert ((Get-SocialPostStatus -ExitCode 1 -Interrupted $false -Blocked $false -CompletedCount 0) -eq 'Failed') 'exit!=0 no files => Failed'
Assert ((Get-SocialPostStatus -ExitCode 1 -Interrupted $true -Blocked $false -CompletedCount 0) -eq 'Interrupted') 'interrupted => Interrupted'
Assert ((Get-SocialPostStatus -ExitCode 1 -Interrupted $true -Blocked $true -CompletedCount 5) -eq 'Blocked') 'blocked wins over everything'

# --- Blocking signal --------------------------------------------------------
Assert (Test-BlockingSignal 'HTTP Error 429: Too Many Requests') 'detects 429'
Assert (Test-BlockingSignal 'challenge_required') 'detects instagram challenge'
Assert (-not (Test-BlockingSignal 'downloading 3 of 4')) 'normal progress is not a block'

# --- Manifest atomicity -----------------------------------------------------
$mfDir = Join-Path $sandbox 'mf'
New-Item -ItemType Directory -Path $mfDir -Force | Out-Null
$mfPath = Get-ManifestPath -TargetFolder $mfDir
Write-RequestManifest -Path $mfPath -Manifest ([ordered]@{ manifestVersion = 1; items = @() })
Assert (Test-Path -LiteralPath $mfPath) 'manifest is written'
Assert (@(Get-ChildItem -LiteralPath $mfDir -Filter '*.tmp').Count -eq 0) 'no temp manifest files remain'
$readBack = Read-RequestManifest -Path $mfPath
Assert ($readBack.manifestVersion -eq 1) 'manifest reads back'

# --- Cookie filtering + cleanup ---------------------------------------------
$srcCookie = Join-Path $sandbox 'cookies.txt'
@(
    '# Netscape HTTP Cookie File',
    "x.com`tTRUE`t/`tTRUE`t9999999999`tauth_token`tSECRETX",
    ".x.com`tTRUE`t/`tTRUE`t9999999999`tct0`tSECRETCT0",
    "instagram.com`tTRUE`t/`tTRUE`t9999999999`tsessionid`tSECRETIG"
) | Set-Content -LiteralPath $srcCookie -Encoding ASCII
$filtered = New-FilteredCookieFile -SourcePath $srcCookie -Platform 'x'
Assert ($null -ne $filtered -and (Test-Path -LiteralPath $filtered)) 'filtered cookie file created'
$filteredContent = Get-Content -Raw -LiteralPath $filtered
Assert (($filteredContent -match 'SECRETX') -and ($filteredContent -match 'SECRETCT0')) 'keeps x.com cookies'
Assert (-not ($filteredContent -match 'SECRETIG')) 'drops other-platform cookies'
Assert ((Get-Content -Raw -LiteralPath $srcCookie) -match 'SECRETIG') 'original cookie file is untouched'
Remove-TemporaryCookieFile -Path $filtered
Assert (-not (Test-Path -LiteralPath $filtered)) 'temporary cookie copy is deleted'
# Remove-TemporaryCookieFile never touches a non-temp path.
Remove-TemporaryCookieFile -Path $srcCookie
Assert (Test-Path -LiteralPath $srcCookie) 'cleanup refuses to delete a non-temp file'
Assert ($null -eq (New-FilteredCookieFile -SourcePath $srcCookie -Platform 'tiktok')) 'no matching cookies yields null'

# Resolve-RequestCookiePath: anonymous, mismatch, and success.
Assert ($null -eq (Resolve-RequestCookiePath -Request ([pscustomobject]@{ Url = 'https://x.com/u/status/1'; Platform = 'x'; Account = $null }))) 'anonymous resolves to no cookie'
$mismatch = [pscustomobject]@{ Url = 'https://x.com/u/status/1'; Platform = 'x'; Account = [pscustomobject]@{ Name = 'ig'; Platform = 'instagram'; CookieFile = $srcCookie } }
$threw = $false
try { Resolve-RequestCookiePath -Request $mismatch } catch { $threw = $true }
Assert $threw 'platform mismatch is refused'
$okAcct = [pscustomobject]@{ Url = 'https://x.com/u/status/1'; Platform = 'x'; Account = [pscustomobject]@{ Name = 'x'; Platform = 'x'; CookieFile = $srcCookie } }
$resolved = Resolve-RequestCookiePath -Request $okAcct
Assert ($null -ne $resolved -and (Test-Path -LiteralPath $resolved)) 'matching account resolves a temp cookie copy'
Remove-TemporaryCookieFile -Path $resolved

# Clear-StaleCookieFiles removes leftover app-owned temp cookies.
$stale = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}stale.txt' -f (Get-CookieTempPrefix))
Set-Content -LiteralPath $stale -Value 'x' -Encoding ASCII
Clear-StaleCookieFiles
Assert (-not (Test-Path -LiteralPath $stale)) 'startup sweep removes stale temp cookies'

# --- Platform holds (persisted) ---------------------------------------------
Remove-PlatformHold -Platform 'tiktok'
Assert (-not (Test-PlatformHeld -Platform 'tiktok')) 'no hold by default'
Set-PlatformHold -Platform 'tiktok' -Reason 'rate limited'
Assert (Test-PlatformHeld -Platform 'tiktok') 'hold is active after being set'
Assert (Test-Path -LiteralPath (Get-HoldStorePath)) 'hold persisted to disk'
Assert ((Get-PlatformHold -Platform 'tiktok').reason -eq 'rate limited') 'hold reason is stored'
Set-PlatformHold -Platform 'x' -Reason 'expired soon' -RetryAfter (Get-Date).AddSeconds(-5)
Assert (-not (Test-PlatformHeld -Platform 'x')) 'a past retry-after auto-releases the hold'
Assert ($null -eq (Get-PlatformHold -Platform 'x')) 'expired hold is removed from the store'
Set-PlatformHold -Platform 'facebook' -Reason 'future' -RetryAfter (Get-Date).AddHours(1)
Assert (Test-PlatformHeld -Platform 'facebook') 'a future retry-after keeps the hold'
Remove-PlatformHold -Platform 'tiktok'
Assert (-not (Test-PlatformHeld -Platform 'tiktok')) 'hold can be released manually'

# --- End-to-end via the fake gallery-dl -------------------------------------
Remove-PlatformHold -Platform 'x'
$e2e = New-SocialPostRequest -Url 'https://x.com/u/status/55501' -Account $null -IncludeManifest
$result = Invoke-SocialPostRequest -Request $e2e -Queued
Assert ($result.Status -eq 'Completed') 'successful post download is Completed'
$files = @(Get-ChildItem -LiteralPath $e2e.TargetFolder -File | Where-Object { $_.Extension -ne '.json' })
Assert ($files.Count -eq 2) 'two media files were downloaded'
$mf = Read-RequestManifest -Path (Get-ManifestPath -TargetFolder $e2e.TargetFolder -RequestId $e2e.RequestId)
Assert ($mf.downloadedCount -eq 2 -and @($mf.items).Count -eq 2) 'manifest records both items'
Assert (($mf.items[0].mediaType -eq 'image') -or ($mf.items[1].mediaType -eq 'image')) 'manifest classifies an image item'
$hist = @(Import-Csv -LiteralPath $script:HistoryPath)
Assert (@($hist | Where-Object { $_.Status -eq 'Completed' }).Count -ge 2) 'history records completed items'

# Empty result => Failed.
$env:FAKE_GDL_EMPTY = '1'
$e2eEmpty = New-SocialPostRequest -Url 'https://x.com/u/status/55502' -Account $null
$emptyResult = Invoke-SocialPostRequest -Request $e2eEmpty -Queued
Remove-Item Env:\FAKE_GDL_EMPTY
Assert ($emptyResult.Status -eq 'Failed') 'a post yielding no files is Failed'
Assert (-not (Test-Path (Get-ManifestPath -TargetFolder $e2eEmpty.TargetFolder -RequestId $e2eEmpty.RequestId))) 'media-only does not write a manifest'
Assert (Test-Path (Get-ManifestPath -TargetFolder $e2e.TargetFolder -RequestId $e2e.RequestId)) 'another request preserves the previous manifest'

# Partial: exit non-zero but some files present.
$env:FAKE_GDL_EXIT = '1'
$e2ePartial = New-SocialPostRequest -Url 'https://x.com/u/status/55503' -Account $null
$partialResult = Invoke-SocialPostRequest -Request $e2ePartial -Queued
Remove-Item Env:\FAKE_GDL_EXIT
Assert ($partialResult.Status -eq 'Partial') 'partial download is Partial'

# Blocking: engine emits a 429 => Blocked + a platform hold is set.
Remove-PlatformHold -Platform 'x'
$env:FAKE_GDL_BLOCK = '1'
$e2eBlocked = New-SocialPostRequest -Url 'https://x.com/u/status/55504' -Account $null
$blockedResult = Invoke-SocialPostRequest -Request $e2eBlocked -Queued
Remove-Item Env:\FAKE_GDL_BLOCK
Assert ($blockedResult.Status -eq 'Blocked') 'a rate-limited post is Blocked'
Assert (Test-PlatformHeld -Platform 'x') 'a block places the platform on hold'
Remove-PlatformHold -Platform 'x'

# --- Queue skips held platforms, runs the rest ------------------------------
function Write-Heading { param($Text) }
function Get-QueueItemDelaySeconds { 0 }
function Initialize-DownloadDependencies { $true }
function Resolve-RequestDependencies { param($Mode) $true }
function Invoke-DownloadRequest { param($Request, [switch]$Queued, $QueueLabel) $Request.Status = 'Completed'; return [pscustomobject]@{ Status = 'Completed'; ExitCode = 0 } }
function Read-Host { param($Prompt) '' }
Set-PlatformHold -Platform 'instagram' -Reason 'test hold'
Remove-PlatformHold -Platform 'tiktok'
$script:DownloadQueue = New-Object 'System.Collections.Generic.List[object]'
$script:DownloadQueue.Add([pscustomobject]@{ Url = 'https://www.instagram.com/p/AAA/'; Platform = 'instagram'; Mode = 'SocialPost'; Status = 'Pending'; Preset = 'post'; Title = 'ig' })
$script:DownloadQueue.Add([pscustomobject]@{ Url = 'https://www.tiktok.com/@u/video/9'; Platform = 'tiktok'; Mode = 'SocialPost'; Status = 'Pending'; Preset = 'post'; Title = 'tt' })
Start-DownloadQueue
Assert ($script:DownloadQueue[0].Status -eq 'Blocked') 'queue marks a held-platform item Blocked'
Assert ($script:DownloadQueue[1].Status -eq 'Completed') 'queue still runs items on non-held platforms'
Remove-PlatformHold -Platform 'instagram'

# --- Cleanup ----------------------------------------------------------------
# Drive the actual interactive request builder for both save choices.
function Read-Host { param($Prompt) 'https://x.com/u/status/42/photo/1' }
function Read-AccountProfile { param($Url) $null }
function Start-MetadataProbe { param($Url) throw 'Social request must not start a video probe' }
function Read-MenuChoice {
    param($Title, $Options, $DefaultValue, $RedrawHeader)
    $script:promptTitles.Add($Title)
    if ($Title -eq 'What should be saved?') { return $script:saveChoice }
    if ($Title -eq 'Ready?') { return 'Start' }
    throw "Unexpected prompt: $Title"
}
foreach ($choice in @('Media', 'Manifest')) {
    $script:saveChoice = $choice
    $script:promptTitles = New-Object System.Collections.Generic.List[string]
    $built = New-DownloadRequest
    Assert ($built.IncludeManifest -eq ($choice -eq 'Manifest')) "request builder honors $choice choice"
    Assert (($script:promptTitles -join ',') -eq 'What should be saved?,Ready?') 'photo flow only asks save choice and confirmation'
}
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:failures.Count -gt 0) {
    Write-Host ("{0} social-engine test(s) failed." -f $script:failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'All social-engine regression tests passed.' -ForegroundColor Green
