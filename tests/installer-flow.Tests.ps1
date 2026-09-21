Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$sandbox = Join-Path $root ('.test-temp\installer-flow-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
function Assert($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
try {
    $env:SEEN_TEST_SOURCE = $root
    $env:SEEN_TEST_FIXTURES = $sandbox
    Set-Content (Join-Path $sandbox 'engine.bin') 'fixture engine'
    $nodeRoot = Join-Path $sandbox 'node-v24.0.0-win-x64'
    $ffRoot = Join-Path $sandbox 'ffmpeg-fixture'
    New-Item -ItemType Directory -Path $nodeRoot,$ffRoot | Out-Null
    Copy-Item (Join-Path $sandbox 'engine.bin') (Join-Path $nodeRoot 'node.exe')
    Set-Content (Join-Path $nodeRoot 'LICENSE') 'fixture license'
    Compress-Archive -LiteralPath $nodeRoot -DestinationPath (Join-Path $sandbox 'node.zip')
    foreach ($name in @('ffmpeg.exe','ffprobe.exe')) { Copy-Item (Join-Path $sandbox 'engine.bin') (Join-Path $ffRoot $name) }
    Set-Content (Join-Path $ffRoot 'LICENSE') 'fixture license'
    Compress-Archive -LiteralPath $ffRoot -DestinationPath (Join-Path $sandbox 'ffmpeg.zip')
    $body = ([IO.File]::ReadAllText((Join-Path $root 'Install Seen Downloader.cmd')) -split '(?m)^# POWERSHELL START\r?$',2)[1]
    $body = $body.Replace('# --- Main flow', '. (Join-Path $env:SEEN_TEST_SOURCE "tests\fixtures\installer-downloads.ps1")' + "`r`n# --- Main flow")
    $runner = Join-Path $sandbox 'setup.ps1'
    [IO.File]::WriteAllText($runner, $body, (New-Object Text.UTF8Encoding($true)))
    $target = Join-Path $sandbox "Installed app & user's folder"
    $engine = (Get-Process -Id $PID).Path
    & $engine -NoProfile -ExecutionPolicy Bypass -File $runner -InstallDir $target -NoLaunch -NoShortcuts *> (Join-Path $sandbox 'first.log')
    Assert ($LASTEXITCODE -eq 0) 'complete standalone installer succeeds from an empty folder'
    foreach ($file in @('smart-downloader.ps1', "Seen's yt-dlp Downloader.cmd", 'Install Seen Downloader.cmd', 'installed-version.txt', 'installed-helpers.json','yt-dlp.exe','node.exe','ffmpeg.exe','ffprobe.exe','gallery-dl.exe')) {
        Assert (Test-Path -LiteralPath (Join-Path $target $file)) "installs $file"
    }
    Assert (@(Get-Content (Join-Path $sandbox 'probes.txt')).Count -eq 5) 'all five helper checks run before installation'
    New-Item -ItemType Directory -Path (Join-Path $target 'Downloads') | Out-Null
    Set-Content (Join-Path $target 'Downloads\keep.txt') 'personal download'
    Set-Content (Join-Path $target 'logs\settings.json') '{"CheckForUpdates":false}'
    & $engine -NoProfile -ExecutionPolicy Bypass -File $runner -InstallDir $target -NoLaunch -NoShortcuts *> (Join-Path $sandbox 'second.log')
    Assert ($LASTEXITCODE -eq 0) 'standalone installer updates an existing installation'
    Assert ((Get-Content (Join-Path $sandbox 'second.log') -Raw) -match 'ffmpeg is current; reusing') 'update reuses current verified FFmpeg'
    Assert ((Get-Content (Join-Path $target 'Downloads\keep.txt')) -eq 'personal download') 'update preserves user downloads'
    Assert ((Get-Content (Join-Path $target 'logs\settings.json')) -eq '{"CheckForUpdates":false}') 'update preserves settings'
    Set-Content (Join-Path $target 'smart-downloader.ps1') '# previous working app'
    $env:SEEN_TEST_FAIL_HELPER = 'ffprobe.exe'
    & $engine -NoProfile -ExecutionPolicy Bypass -File $runner -InstallDir $target -NoLaunch -NoShortcuts *> (Join-Path $sandbox 'failed.log')
    Assert ($LASTEXITCODE -ne 0) 'failed helper check prevents installation'
    Assert ((Get-Content (Join-Path $target 'smart-downloader.ps1')) -eq '# previous working app') 'failed setup preserves the previous app'
    Assert (@(Get-ChildItem -LiteralPath $target -Directory -Filter '.setup-*').Count -eq 0) 'success and failure clean staging folders'
    $lock = [IO.File]::Open((Join-Path $target '.setup.lock'),'Open','ReadWrite','None')
    $lock.Dispose()
    Assert $true 'setup lock is released after failure'
    Assert (@(Get-ChildItem (Join-Path $target 'logs') -Filter 'setup-*.log').Count -ge 1) 'setup preserves diagnostic logs'
    Remove-Item Env:\SEEN_TEST_FAIL_HELPER
    & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fixtures\inapp-update.ps1') -Target $target *> (Join-Path $sandbox 'inapp.log')
    Assert ($LASTEXITCODE -eq 0) 'in-app updater runs the same full installer in a fresh process and requests restart'
    Assert ((Get-Content (Join-Path $target 'smart-downloader.ps1') -Raw) -eq (Get-Content (Join-Path $root 'smart-downloader.ps1') -Raw)) 'in-app updater installs the new app payload'
    Assert ((Get-Content (Join-Path $target 'Downloads\keep.txt')) -eq 'personal download') 'in-app updater preserves downloads'

    # Exercise the actual CMD relaunch loop with a tiny app that requests one restart.
    $stub = @'
$path = Join-Path $PSScriptRoot 'starts.txt'
$count = if (Test-Path $path) { [int](Get-Content $path) } else { 0 }
Set-Content $path ($count + 1)
if ($count -eq 0) { exit 42 }
exit 0
'@
    Set-Content (Join-Path $target 'smart-downloader.ps1') $stub
    & (Join-Path $target "Seen's yt-dlp Downloader.cmd") *> (Join-Path $sandbox 'restart.log')
    Assert ($LASTEXITCODE -eq 0 -and (Get-Content (Join-Path $target 'starts.txt')) -eq '2') 'launcher reloads the new app exactly once after an update'
} finally {
    Remove-Item Env:\SEEN_TEST_SOURCE,Env:\SEEN_TEST_FIXTURES,Env:\SEEN_TEST_FAIL_HELPER -ErrorAction SilentlyContinue
    if ((Split-Path -Parent $sandbox) -eq [IO.Path]::GetFullPath((Join-Path $root '.test-temp')) -and (Split-Path -Leaf $sandbox) -match '^installer-flow-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
