Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$source = ([IO.File]::ReadAllText((Join-Path $root 'Install Yt-dlp Downloader.cmd')) -split '(?m)^# POWERSHELL START\r?$', 2)[1]
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
function Assert($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
$tempRoot = Join-Path $root ('.test-temp\installer-network-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$server = Start-Job -ScriptBlock {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $listener.LocalEndpoint.Port
    try {
        while ($true) {
            while (-not $listener.Pending()) { Start-Sleep -Milliseconds 100 }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = New-Object IO.StreamReader($stream)
                $request = $reader.ReadLine()
                while ($reader.ReadLine()) { }
                if ($request -match '/headers ') { Start-Sleep -Seconds 4; continue }
                if ($request -match '/unavailable ') {
                    $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 503 Service Unavailable`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($header, 0, $header.Length)
                    continue
                }
                $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 1048576`r`nConnection: close`r`n`r`n")
                $stream.Write($header, 0, $header.Length)
                if ($request -match '/stall ') { Start-Sleep -Seconds 4; continue }
                $chunk = New-Object byte[] 65536
                for ($i = 0; $i -lt 16; $i++) {
                    $stream.Write($chunk, 0, $chunk.Length)
                    $stream.Flush()
                    if ($request -match '/truncated ') { break }
                    Start-Sleep -Milliseconds 250
                }
            } catch { } finally { $client.Dispose() }
        }
    } finally { $listener.Stop() }
}
try {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $port = $null
    while (-not $port -and $clock.Elapsed.TotalSeconds -lt 15) {
        $port = Receive-Job $server
        Start-Sleep -Milliseconds 100
    }
    if (-not $port) { throw 'Fixture server did not start.' }
    $messages = @(Get-SetupFile "http://127.0.0.1:$port/slow" (Join-Path $tempRoot 'slow.zip') 6>&1)
    Assert ((Get-Item (Join-Path $tempRoot 'slow.zip')).Length -eq 1048576) 'slow download completes intact'
    Assert (@($messages | Where-Object { "$_" -match 'MB|Connecting' }).Count -ge 2) 'slow download reports activity while it transfers (regression: silent frozen screen)'
    foreach ($route in @('truncated', 'unavailable', 'stall', 'headers')) {
        $destination = Join-Path $tempRoot "$route.zip"
        $clock.Restart()
        $failure = ''
        try { Get-SetupFile "http://127.0.0.1:$port/$route" $destination -Attempts 1 -IdleTimeoutSec 1 -TimeoutSec 10 } catch { $failure = $_.Exception.Message }
        Assert ($failure.Length -gt 0) "$route response fails instead of reporting success"
        Assert (-not (Test-Path $destination) -and -not (Test-Path "$destination.part")) "$route response leaves no partial download"
        if ($route -in @('stall', 'headers')) {
            Assert ($failure -match 'No download data received' -and $clock.Elapsed.TotalSeconds -lt 3) "$route timeout returns promptly"
            Start-Sleep -Seconds 4
        }
    }
} finally {
    Stop-Job $server
    Remove-Job $server
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $root '.test-temp'))
    if ((Split-Path -Parent $tempRoot) -eq $expectedParent -and (Split-Path -Leaf $tempRoot) -match '^installer-network-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
