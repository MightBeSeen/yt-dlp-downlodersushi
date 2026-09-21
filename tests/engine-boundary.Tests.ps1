Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Load the downloader's functions in isolation (no menu bootstrap), matching the
# convention used by queue/ux suites.
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

# --- Queue state model -------------------------------------------------------
$states = Get-QueueStates
Assert (($states -join ',') -eq 'Pending,Downloading,Completed,Partial,Failed,Interrupted,Blocked') `
    'queue state model lists all seven states in order'
$retry = Get-QueueRetryStates
Assert (($retry -join ',') -eq 'Partial,Failed,Interrupted') 'retry set is Partial/Failed/Interrupted'
Assert ($retry -notcontains 'Blocked' -and $retry -notcontains 'Completed' -and $retry -notcontains 'Pending') `
    'retry set excludes Blocked/Completed/Pending'

# --- Retry reruns the retry set and never clears a platform hold -------------
function Clear-Terminal {}
function Write-Heading { param($Text) }
function Read-Host { param($Prompt) '' }
function Initialize-DownloadDependencies { $true }
function Get-QueueItemDelaySeconds { 0 }   # no real pacing delay during tests
function Invoke-DownloadRequest {
    param($Request, [switch]$Queued, $QueueLabel)
    $Request.Status = 'Completed'
    return [pscustomobject]@{ Status = 'Completed'; ExitCode = 0 }
}
$script:DownloadQueue = New-Object 'System.Collections.Generic.List[object]'
foreach ($s in @('Partial', 'Blocked', 'Failed', 'Interrupted', 'Completed')) {
    $script:DownloadQueue.Add([pscustomobject]@{ Url = "https://example.com/$s"; Status = $s; Preset = 'mp4'; Title = $s })
}
Start-DownloadQueue -RetryFailed
$byStatus = @{}; foreach ($i in $script:DownloadQueue) { $byStatus[$i.Title] = $i.Status }
Assert ($byStatus['Blocked'] -eq 'Blocked') 'retry leaves a Blocked platform hold in place'
Assert ($byStatus['Partial'] -eq 'Completed' -and $byStatus['Failed'] -eq 'Completed' -and $byStatus['Interrupted'] -eq 'Completed') `
    'retry reruns Partial, Failed, and Interrupted items'
Assert ($byStatus['Completed'] -eq 'Completed') 'retry leaves already-Completed items alone'

# --- Per-mode dependency selection ------------------------------------------
$script:depCalls = New-Object System.Collections.Generic.List[string]
function Test-YtDlpReady { $script:depCalls.Add('yt'); $true }
function Test-JsRuntimeReady { $script:depCalls.Add('js'); $true }
function Test-FfmpegReady { $script:depCalls.Add('ffmpeg'); $true }
function Test-GalleryDlReady { $script:depCalls.Add('gallerydl'); $true }

$script:depCalls.Clear(); [void](Resolve-RequestDependencies -Mode 'VideoAudio')
Assert (($script:depCalls -join ',') -eq 'yt,js,ffmpeg') 'video/audio validates yt-dlp + JS runtime + FFmpeg'

$script:depCalls.Clear(); [void](Resolve-RequestDependencies -Mode 'SocialPost')
Assert (($script:depCalls -join ',') -eq 'gallerydl,ffmpeg') 'entire-post validates gallery-dl + FFmpeg'
Assert ($script:depCalls -notcontains 'yt' -and $script:depCalls -notcontains 'js') `
    'entire-post skips the standalone yt-dlp executable and JS runtime'

function Test-YtDlpReady { $script:depCalls.Add('yt'); $false }
$script:depCalls.Clear(); $stopEarly = Resolve-RequestDependencies -Mode 'VideoAudio'
Assert (-not $stopEarly -and ($script:depCalls -join ',') -eq 'yt') 'a failing dependency stops further checks'
function Test-YtDlpReady { $script:depCalls.Add('yt'); $true }

# --- Mode and account defaults ----------------------------------------------
Assert ((Get-AvailableDownloadModes) -contains 'VideoAudio') 'video/audio is an available mode'
Assert ((Read-DownloadMode -DefaultValue 'VideoAudio') -eq 'VideoAudio') 'a single available mode returns without prompting'
Assert ($null -eq (Read-AccountProfile -Url 'https://example.com/x')) 'no configured profiles resolves to Anonymous'

# --- Probe gating (drives New-DownloadRequest) ------------------------------
# The step machine is cut short at the first question so only the pre-question
# probe decision is exercised.
function Show-DownloadHeader { param($Title, $Url, $Preset, $Quality, $Live, $Playlist) }
function Read-FormatPreset { param($DefaultValue) $null }   # Back on Q1 => return
function Resolve-RequestDependencies { param($Mode) $true }
function Start-MetadataProbe { param($Url) $script:probeStarted = $true; return $null }
function Read-Host { param($Prompt) 'https://example.com/video' }

function Read-DownloadMode { param($DefaultValue) 'VideoAudio' }
function Read-AccountProfile { param($Url) $null }
$script:probeStarted = $false
[void](New-DownloadRequest)
Assert $script:probeStarted 'anonymous video/audio starts a background metadata probe'

function Read-DownloadMode { param($DefaultValue) 'SocialPost' }
$script:probeStarted = $false
[void](New-DownloadRequest)
Assert (-not $script:probeStarted) 'entire-post mode issues no pre-confirmation probe'

function Read-DownloadMode { param($DefaultValue) 'VideoAudio' }
function Read-AccountProfile { param($Url) [pscustomobject]@{ Name = 'acct'; Platform = 'x' } }
$script:probeStarted = $false
[void](New-DownloadRequest)
Assert (-not $script:probeStarted) 'authenticated requests issue no pre-confirmation probe'

if ($script:failures.Count -gt 0) {
    Write-Host ("{0} engine-boundary test(s) failed." -f $script:failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'All engine-boundary regression tests passed.' -ForegroundColor Green
