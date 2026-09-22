Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$source = Join-Path (Split-Path $PSScriptRoot) 'smart-downloader.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
function Assert($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
$script:YtDlp = (Get-Command node.exe).Source
$script:YtDlpBaseArguments = @('-e', 'setTimeout(()=>console.log(JSON.stringify({title:process.argv[process.argv.length-1]})),20)', '--')
$url = 'https://example.com/video?a=1&b=two%20words'
$job = Start-MetadataProbe $url
$result = Complete-MetadataProbe $job
Assert ($result.Success -and $result.Metadata.title -eq $url) 'native probe preserves URL arguments and parses metadata'

$script:YtDlpBaseArguments = @('-e', 'setTimeout(()=>{},10000)', '--')
foreach ($iteration in 1..3) {
    $job = Start-MetadataProbe $url
    $probeId = $job.Process.Id
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Stop-MetadataProbe $job
    $timer.Stop()
    Assert ($timer.ElapsedMilliseconds -lt 500) "cancel returns within 500 ms ($($timer.ElapsedMilliseconds) ms)"
    Assert ($null -eq (Get-Process -Id $probeId -ErrorAction SilentlyContinue)) 'cancel terminates the owned native probe'
    Stop-MetadataProbe $job
}
$job = Start-MetadataProbe $url -TimeoutMilliseconds 100
$probeId = $job.Process.Id
$result = Complete-MetadataProbe $job
Assert (-not $result.Success -and $result.Error -match 'timed out') 'timeout produces manual-fallback result'
Assert ($null -eq (Get-Process -Id $probeId -ErrorAction SilentlyContinue)) 'timeout terminates native probe'
$script:YtDlpBaseArguments = @('-e', 'console.error("fixture failure");process.exit(1)', '--')
$result = Complete-MetadataProbe (Start-MetadataProbe $url)
Assert (-not $result.Success -and $result.Error -match 'fixture failure') 'failed probe retains useful error'

# Reproduce the original user flow with a real slow native process.
function Resolve-RequestDependencies { param($Mode) $true }
function Read-DownloadMode { param($DefaultValue) 'VideoAudio' }
function Read-Host { $url }
function Read-FormatPreset { param($DefaultValue) $null }
function Show-DownloadHeader {}
$script:YtDlpBaseArguments = @('-e', 'setTimeout(()=>{},10000)', '--')
$timer = [Diagnostics.Stopwatch]::StartNew()
Start-SmartDownload *> $null
$timer.Stop()
Assert ($timer.ElapsedMilliseconds -lt 500) "setup cancellation returns promptly ($($timer.ElapsedMilliseconds) ms)"

# Use actual history rendering with in-memory CSV rows, never personal history.
function Test-Path { $true }
function Import-Csv { $script:rows }
function Clear-Terminal {}
function Pause-Terminal {}
function Read-PageCommand { 'Exit' }
$script:Root = Split-Path $PSScriptRoot
$script:HistoryPath = 'in-memory.csv'
$good = [pscustomobject]@{SizeBytes='12';Status='Completed';TimestampLocal='2026-09-12';Preset='mp4';FilePath='';Url=$url}
$script:rows = @($good)
foreach ($size in @('broken','-1','999999999999999999999999999999')) {
    $bad = $good.PSObject.Copy(); $bad.SizeBytes = $size; $script:rows += $bad
}
$script:rows += [pscustomobject]@{SizeBytes='3'}
$output = Show-DownloadHistory *>&1 | Out-String
Assert ($output -match 'Skipped 4 damaged' -and $output -match 'Recorded outputs: 1 files') 'mixed damaged history preserves valid rows and totals'
$script:rows = @([pscustomobject]@{SizeBytes='bad'})
$output = Show-DownloadHistory *>&1 | Out-String
Assert ($output -match 'No valid history') 'all-invalid history returns cleanly'
$script:rows = @()
$output = Show-DownloadHistory *>&1 | Out-String
Assert ($output -match 'history file is empty') 'empty history returns cleanly'
$zero = $good.PSObject.Copy(); $zero.SizeBytes = '0'; $zero.Status = 'Failed'
$script:rows = @($zero)
$output = Show-DownloadHistory *>&1 | Out-String
Assert ($output -match 'Failed' -and $output -notmatch 'damaged') 'zero-byte failure record remains visible'
Remove-Item Function:Test-Path

# Exercise setup through review; any media/directory side effect is a test failure.
function Resolve-RequestDependencies { param($Mode) $true }
function Start-MetadataProbe { [pscustomobject]@{} }
function Test-MetadataProbeCompleted { $true }
function Complete-MetadataProbe { [pscustomobject]@{Success=$true;Cancelled=$false;Metadata=[pscustomobject]@{title='Fixture';_type='video';live_status='not_live'}} }
function Show-DownloadHeader {}
function Read-Host { $url }
function Read-FormatPreset { param($DefaultValue) $script:formatDefaults += $DefaultValue; 'mp4' }
function Read-VideoQuality { param($DefaultValue) '720' }
function Read-LiveMode { param($DefaultValue) 'Normal' }
function New-Item { throw 'Directory created before confirmation' }
function Read-MenuChoice { param($Title,$Options) $script:reviews++; if ($script:reviews -eq 1) { 'Change' } else { $null } }
$script:DownloadsRoot = Join-Path $script:Root 'must-not-be-created'
$script:formatDefaults = @()
$script:reviews = 0
$output = Start-SmartDownload *>&1 | Out-String
Assert ($script:reviews -eq 2 -and $script:formatDefaults[1] -eq 'mp4') 'change choices retains previous format default'
Assert ($output -match 'Review download' -and $output -match '720' -and $output -match 'Destination:') 'review includes choices and destination before cancellation'

# Run the real numbered pickers across setup scenarios; cancel at final review.
foreach ($name in @('Read-FormatPreset','Read-VideoQuality','Read-LiveMode','Read-MenuChoice')) {
    $definition = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)[0]
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Read-Host {
    param($Prompt)
    if ($script:answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    $script:answers.Dequeue()
}
function Complete-MetadataProbe { [pscustomobject]@{Success=$script:probeSuccess;Cancelled=$false;Error='Offline fixture';Metadata=$script:metadata} }
$script:FfmpegAvailable = $true
$video = [pscustomobject]@{title='Fixture';_type='video';live_status='not_live'}
$playlist = [pscustomobject]@{title='Playlist';_type='playlist';entries=@()}
$live = [pscustomobject]@{title='Live';_type='video';live_status='is_live'}
$cases = @(
    @{Name='single video'; Metadata=$video; Success=$true; Answers=@($url,'1','3','A','C'); Expected='Up to 720p'},
    @{Name='playlist-only link'; Metadata=$playlist; Success=$true; Answers=@($url,'1','1','A','Y','C'); Expected='Scope: Full playlist'},
    @{Name='selected video in playlist'; Metadata=$playlist; Success=$true; Answers=@('https://www.youtube.com/watch?v=fixture&list=fixture','1','1','A','1','C'); Expected='Scope: Single video'},
    @{Name='livestream'; Metadata=$live; Success=$true; Answers=@($url,'1','1','A','C'); Expected='Auto \(live detected\)'},
    @{Name='audio skips quality'; Metadata=$video; Success=$true; Answers=@($url,'2','A','C'); Expected='n/a \(audio\)'},
    @{Name='metadata failure manual fallback'; Metadata=$null; Success=$false; Answers=@($url,'1','1','N','1','C'); Expected='Live: Normal'},
    @{Name='back from video quality to audio'; Metadata=$video; Success=$true; Answers=@($url,'1','B','2','N','C'); Expected='Format: MP3'},
    @{Name='change choices keeps quality'; Metadata=$video; Success=$true; Answers=@($url,'1','3','N','2','','','','C'); Expected='Up to 720p'}
)
foreach ($case in $cases) {
    $script:metadata = $case.Metadata
    $script:probeSuccess = $case.Success
    $script:answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($answer in $case.Answers) { $script:answers.Enqueue($answer) }
    $output = Start-SmartDownload *>&1 | Out-String
    Assert ($output -match $case.Expected -and $script:answers.Count -eq 0) $case.Name
}

# Dependency tests restore the real resolver with installers stubbed out.
$resolver = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-RequestDependencies'},$false)[0]
. ([scriptblock]::Create($resolver.Extent.Text))
$setup = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DownloadDependencies'},$false)[0]
. ([scriptblock]::Create($setup.Extent.Text))
function Test-Path { $true }
function Update-JsRuntimeState { $script:JsRuntime = $null }
function Test-CommandAvailable { $false }
function Install-NodeRuntime { $false }
Assert (-not (Initialize-DownloadDependencies)) 'declined Node setup returns without exiting application'
function Update-JsRuntimeState { $script:JsRuntime = 'node' }
function Install-FfmpegLocal { $false }
Assert (-not (Initialize-DownloadDependencies)) 'declined FFmpeg setup returns without starting download'
Write-Host 'All UX regression tests passed.'
