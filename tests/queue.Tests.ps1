Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$root=Split-Path $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'smart-downloader.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count) { throw ($errors | Out-String) }
$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
function Assert($Condition,$Message) {
    if(-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
function Clear-Terminal {}
function Show-DownloadHeader {}
function Initialize-DownloadDependencies { $true }
function Get-QueueItemDelaySeconds { 0 }   # keep queue tests fast; pacing tested separately
function Read-Host {
    param($Prompt)
    if($script:answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    $script:answers.Dequeue()
}
function Set-Answers([string[]]$Values) {
    $script:answers=New-Object 'System.Collections.Generic.Queue[string]'
    foreach($value in $Values) { $script:answers.Enqueue($value) }
}
$script:YtDlp=(Get-Command node.exe).Source
$script:Root=$root
$script:DownloadsRoot=Join-Path $root ('.test-temp\queue-' + [guid]::NewGuid().ToString('N'))
$script:HistoryPath=Join-Path $script:DownloadsRoot 'history.csv'
$script:LogsRoot=$script:DownloadsRoot
$script:OutputMarker='__SMART_DOWNLOADER_FILE__:'
$script:Settings=@{OpenFolderAfterDownload=$false}
$script:FfmpegAvailable=$true
$script:MediaExtensions=@('.mp4','.mp3','.mkv','.aac')

# Real slow metadata process: setup must never await the result.
$script:YtDlpBaseArguments=@('-e','setTimeout(()=>console.log(JSON.stringify({title:"Late title",is_live:true,_type:"playlist"})),10000)','--')
Set-Answers @('https://example.com/video?a=1&b=two%20words','1','3','Y','2','1')
$timer=[Diagnostics.Stopwatch]::StartNew()
$request=New-DownloadRequest -ForQueue
$timer.Stop()
Assert ($timer.ElapsedMilliseconds -lt 1000) "slow metadata does not block review ($($timer.ElapsedMilliseconds) ms)"
Assert ($script:answers.Count -eq 0 -and $null -ne $request) 'queue confirmation consumes exactly the expected prompts'
Assert ($request.Quality -eq '720' -and $request.PlaylistMode -eq 'Playlist' -and $request.LiveDecision.Enabled) 'manual scope/live choices are retained'
Assert (-not (Test-Path -LiteralPath $script:DownloadsRoot)) 'preparing an item creates no download directory'

# Change choices after manual live resolution: no duplicate fallback prompt or lookup.
function Start-MetadataProbe { throw 'offline' }
Set-Answers @('https://example.com/video','1','3','N','1','2','','','','','1')
$edited=New-DownloadRequest -ForQueue
Assert ($edited.Quality -eq '720' -and $edited.LiveDecision.Description -eq 'Normal' -and $script:answers.Count -eq 0) 'change choices keeps manual defaults without asking twice'

$script:DownloadQueue=New-Object 'System.Collections.Generic.List[object]'
$script:DownloadQueue.Add($request)
$edited.Url='https://example.com/fail'
$edited.Preset='mp3'
$script:DownloadQueue.Add($edited)
$third=$request.PSObject.Copy(); $third.Url='https://example.com/last'; $third.Preset='mkv'
$script:DownloadQueue.Add($third)
$script:YtDlpBaseArguments=@('-e', @'
const fs=require('fs'), path=require('path');
const args=process.argv.slice(1), dir=args[args.indexOf('-P')+1], url=args[args.length-1];
fs.mkdirSync(dir,{recursive:true});
fs.appendFileSync(path.join(dir,'arguments.jsonl'),JSON.stringify(args)+'\n');
const file=path.join(dir,args[args.indexOf('-t')+1]+'.mp4');
fs.writeFileSync(file,'fixture media');
console.log('[download] 100.0% of fixture');
console.log('__SMART_DOWNLOADER_FILE__:'+file);
if(url.includes('/fail')) { console.error('Fixture failure'); process.exitCode=1; }
'@, '--')
Set-Answers @('')
Start-DownloadQueue
Assert (($script:DownloadQueue.Status -join ',') -eq 'Completed,Failed,Completed') 'queue continues after a native failure'
Assert ($script:answers.Count -eq 0) 'queue pauses only once after processing'
$calls=@(Get-Content -LiteralPath (Join-Path $request.TargetFolder 'arguments.jsonl') | ForEach-Object { ,($_ | ConvertFrom-Json) })
Assert ($calls.Count -eq 3 -and $calls[0][-1] -eq $request.Url -and $calls[2][-1] -eq $third.Url) 'native downloads preserve FIFO order and URL arguments'
Assert ($calls[0] -contains '--live-from-start' -and $calls[0] -contains 'bv*[height<=720]+ba/b[height<=720]' -and $calls[1] -contains '--no-playlist' -and $calls[1] -contains 'mp3') 'each item uses its own native arguments'
$history=@(Import-Csv -LiteralPath $script:HistoryPath)
Assert (@($history | Where-Object Status -eq 'Completed').Count -eq 2 -and @($history | Where-Object Status -like 'Failed*').Count -eq 1) 'queue records successes and failures in history'
Set-Answers @('')
Start-DownloadQueue -RetryFailed
$calls=@(Get-Content -LiteralPath (Join-Path $request.TargetFolder 'arguments.jsonl'))
Assert ($calls.Count -eq 4 -and $script:DownloadQueue[0].Status -eq 'Completed') 'retry runs failed items without repeating completed downloads'

# Drive cancellation through the real native-process loop with a simulated Ctrl+C.
Add-Type -TypeDefinition @'
using System;
public static class CancelTestConsole {
    public static bool IsInputRedirected=false, TreatControlCAsInput=false;
    public static int Polls=0;
    public static bool KeyAvailable { get { return ++Polls==15; } }
    public static ConsoleKeyInfo ReadKey(bool intercept) { return new ConsoleKeyInfo((char)3,ConsoleKey.C,false,false,true); }
}
'@
$definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-MediaProcess'},$false)[0]
. ([scriptblock]::Create($definition.Extent.Text.Replace('[Console]','[CancelTestConsole]')))
$script:YtDlpBaseArguments=@('-e', @'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const args=process.argv.slice(1),dir=args[args.indexOf('-P')+1];
const child=cp.spawn(process.execPath,['-e','setTimeout(()=>{},10000)'],{stdio:'ignore'});
fs.writeFileSync(path.join(dir,'processes.json'),JSON.stringify([process.pid,child.pid]));
console.log('started');setTimeout(()=>{},10000);
'@, '--')
$script:DownloadQueue.Clear()
foreach($url in @('https://example.com/interrupt','https://example.com/pending')) {
    $item=$request.PSObject.Copy(); $item.Url=$url; $item.Status='Pending'; $script:DownloadQueue.Add($item)
}
Set-Answers @('')
$timer.Restart()
Start-DownloadQueue
$timer.Stop()
Assert ($timer.ElapsedMilliseconds -lt 3000 -and ($script:DownloadQueue.Status -join ',') -eq 'Interrupted,Pending') 'Ctrl+C stops the native download and leaves the next item pending'
Assert (-not [CancelTestConsole]::TreatControlCAsInput) 'Ctrl+C input mode is restored'
$ownedIds=Get-Content -LiteralPath (Join-Path $request.TargetFolder 'processes.json') | ConvertFrom-Json
foreach($ownedId in $ownedIds) {
    Assert ($null -eq (Get-Process -Id $ownedId -ErrorAction SilentlyContinue)) "cancel terminates owned process $ownedId"
}

# Queue management removes only the selected item and safely returns from empty lists.
function Read-MenuChoice { param($Title,$Options,[switch]$AllowBack) if($script:removeFirst) { $script:removeFirst=$false; return '0' }; return 'BACK' }
$script:removeFirst=$true
Show-QueueItems
Assert ($script:DownloadQueue.Count -eq 1 -and $script:DownloadQueue[0].Url -eq 'https://example.com/pending') 'removing an item preserves the remaining request'
$script:DownloadQueue.Clear()
Set-Answers @('')
Show-QueueItems
Set-Answers @()
Start-DownloadQueue
Assert ($script:DownloadQueue.Count -eq 0) 'empty queue returns without downloading or asking for a run confirmation'
Write-Host 'All queue tests passed.'
