# Shared installation/update workers. Embedded in both deliverables for legacy upgrades.

function Write-Step {
    param([string]$Marker, [string]$Message)
    Write-Host ('  [{0}] {1}' -f $Marker, $Message)
}

function Invoke-SetupTransfer {
    param([string]$Url, [string]$Destination, [hashtable]$Headers = @{},
        [int]$IdleTimeoutSec = 45, [int]$TimeoutSec = 1800)
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $Url)
    $cancel = New-Object Threading.CancellationTokenSource
    $response = $null; $inputStream = $null; $outputStream = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $idle = [Diagnostics.Stopwatch]::StartNew()
    $display = [Diagnostics.Stopwatch]::StartNew()
    [long]$received = 0
    [long]$total = 0
    $label = Split-Path -Leaf $Destination
    $wait = {
        param($Task)
        do {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSec) { throw "Download exceeded $TimeoutSec seconds." }
            if ($idle.Elapsed.TotalSeconds -ge $IdleTimeoutSec) { throw "No download data received for $IdleTimeoutSec seconds." }
            if ($display.Elapsed.TotalSeconds -ge 2) {
                $size = '{0:N1} MB' -f ($received / 1MB)
                if ($total -gt 0) { $size += ' / {0:N1} MB ({1:N0}%)' -f ($total / 1MB), (100 * $received / $total) }
                Write-Step '*' ('{0}: {1}, {2:N0}s elapsed' -f $label, $size, $clock.Elapsed.TotalSeconds)
                $display.Restart()
            }
            if ($Task.IsCompleted) { break }
            [void]$Task.Wait(100)
        } while ($true)
    }
    try {
        foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key]) }
        if (-not $request.Headers.UserAgent.ToString()) { [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'Seen-Downloader-Setup') }
        Write-Step '*' ("Connecting to {0} for {1}..." -f ([uri]$Url).Host, $label)
        $task = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token)
        & $wait $task
        $response = $task.GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        if ($null -ne $response.Content.Headers.ContentLength) { $total = $response.Content.Headers.ContentLength }
        $task = $response.Content.ReadAsStreamAsync()
        & $wait $task
        $inputStream = $task.GetAwaiter().GetResult()
        $outputStream = [IO.File]::Create($Destination)
        $buffer = New-Object byte[] 65536
        while ($true) {
            $task = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token)
            & $wait $task
            $count = $task.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            $outputStream.Write($buffer, 0, $count)
            $received += $count
            $idle.Restart()
        }
        if ($received -eq 0) { throw 'The server returned an empty file.' }
        if ($total -gt 0 -and $received -ne $total) { throw 'The download ended before the complete file arrived.' }
        Write-Step 'ok' ('{0}: {1:N1} MB downloaded.' -f $label, ($received / 1MB))
    } finally {
        $cancel.Cancel()
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
        $cancel.Dispose()
    }
}

function Get-SetupFile {
    param([string]$Url, [string]$Destination, [hashtable]$Headers = @{},
        [int]$Attempts = 3, [int]$IdleTimeoutSec = 45, [int]$TimeoutSec = 1800)
    $partial = $Destination + '.part'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Invoke-SetupTransfer $Url $partial $Headers -IdleTimeoutSec $IdleTimeoutSec -TimeoutSec $TimeoutSec
            if ((Get-Item -LiteralPath $partial).Length -eq 0) { throw 'The server returned an empty file.' }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        } catch {
            if ($attempt -eq $Attempts) { throw "Could not download $([IO.Path]::GetFileName($Destination)) from $(([uri]$Url).Host): $($_.Exception.Message)" }
            Write-Step '!' ("Download attempt $attempt/$Attempts failed: $($_.Exception.Message) Retrying...")
            Start-Sleep -Seconds 2
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    }
}

function Get-SetupFfmpeg {
    param([string]$Stage, [string]$Target = '')
    $zip = Join-Path $Stage 'ffmpeg.zip'
    try {
        Write-Step '*' 'Trying FFmpeg publisher on GitHub...'
        $metadata = Join-Path $Stage 'ffmpeg-release.json'
        Get-SetupFile 'https://api.github.com/repos/GyanD/codexffmpeg/releases/latest' $metadata -Attempts 1
        $release = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
        $assets = @($release.assets | Where-Object { $_.name -match '^ffmpeg-[0-9.]+-essentials_build\.zip$' })
        if ($assets.Count -ne 1) { throw 'No unique FFmpeg essentials ZIP was published.' }
        $asset = $assets[0]
        if ($asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'The FFmpeg release has no SHA256 digest.' }
        $hash = $Matches[1]
        if ($Target -and (Copy-SetupCachedGroup $Target $Stage 'ffmpeg' $hash @('ffmpeg.exe', 'ffprobe.exe', 'FFmpeg-LICENSE.txt'))) {
            Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
            return $true
        }
        if ($asset.browser_download_url -notlike 'https://github.com/GyanD/codexffmpeg/releases/download/*') { throw 'Unexpected FFmpeg release URL.' }
        Get-SetupFile $asset.browser_download_url $zip -Attempts 1
        Assert-SetupHash $zip "$hash  ffmpeg.zip" 'ffmpeg.zip'
        Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
        return $false
    } catch {
        Write-Step '!' ("FFmpeg GitHub source failed: $($_.Exception.Message)")
        Write-Step '*' 'Switching to the FFmpeg publisher at gyan.dev...'
    }
    $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    Get-SetupFile "$url.sha256" (Join-Path $Stage 'ffmpeg-checksum.txt') -Attempts 1
    $hash = ((Get-Content -LiteralPath (Join-Path $Stage 'ffmpeg-checksum.txt') -Raw).Trim() -split '\s+')[0]
    if ($hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid FFmpeg checksum from gyan.dev.' }
    if ($Target -and (Copy-SetupCachedGroup $Target $Stage 'ffmpeg' $hash @('ffmpeg.exe', 'ffprobe.exe', 'FFmpeg-LICENSE.txt'))) {
        Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
        return $true
    }
    Get-SetupFile $url $zip -Attempts 1
    Assert-SetupHash $zip "$hash  ffmpeg.zip" 'ffmpeg.zip'
    Set-Content (Join-Path $Stage 'ffmpeg-key.txt') $hash -Encoding ASCII
    return $false
}

function Assert-SetupHash {
    param([string]$Path, [string]$Checksums, [string]$Name)
    $pattern = '(?im)^([a-f0-9]{64})\s+\*?' + [regex]::Escape($Name) + '\s*$'
    $match = [regex]::Match($Checksums, $pattern)
    if (-not $match.Success) { throw "No SHA256 checksum was published for $Name." }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $match.Groups[1].Value) {
        throw "Checksum mismatch for $Name. Run setup again to download a fresh copy."
    }
}

function Test-SetupHelper {
    param([string]$Path, [string]$Arguments = '--version', [int]$TimeoutSec = 30)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Path
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) { throw "$(Split-Path -Leaf $Path) did not respond within $TimeoutSec seconds. Close the app and rerun setup." }
        if ($process.ExitCode -ne 0) { throw "$(Split-Path -Leaf $Path) could not run on this PC: $($stderr.GetAwaiter().GetResult())" }
        $reported = $stdout.GetAwaiter().GetResult()
        if (-not $reported.Trim()) { throw "$(Split-Path -Leaf $Path) returned no version information." }
        Write-Step 'ok' ('{0}: {1}' -f (Split-Path -Leaf $Path), ($reported -split '\r?\n')[0])
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Install-SetupFiles {
    param([string]$Stage, [string]$Target, [string[]]$Names)
    $backup = Join-Path $Stage 'backup'
    New-Item -ItemType Directory -Path $backup | Out-Null
    $changed = @()
    try {
        foreach ($name in $Names) {
            $destination = Join-Path $Target $name
            $existed = Test-Path -LiteralPath $destination
            if ($existed) { Copy-Item -LiteralPath $destination -Destination (Join-Path $backup $name) }
            $changed += [pscustomobject]@{ Name = $name; Existed = $existed }
            Copy-Item -LiteralPath (Join-Path $Stage $name) -Destination $destination -Force
        }
    } catch {
        $originalError = $_
        foreach ($item in $changed) {
            $destination = Join-Path $Target $item.Name
            try {
                if ($item.Existed) {
                    Copy-Item -LiteralPath (Join-Path $backup $item.Name) -Destination $destination -Force
                } elseif (Test-Path -LiteralPath $destination) {
                    Remove-Item -LiteralPath $destination -Force
                }
            } catch { Write-Step '!' "Could not restore $destination. Close the downloader and rerun setup." }
        }
        throw $originalError
    }
}

# Reuse only the exact published package already installed, with every local file
# still matching the recorded hash. Executables are run-tested again before commit.
function Copy-SetupCachedGroup {
    param([string]$Target, [string]$Stage, [string]$Group, [string]$Key, [string[]]$Files)
    try {
        $record = Get-Content -LiteralPath (Join-Path $Target 'installed-helpers.json') -Raw | ConvertFrom-Json
        $entry = $record.PSObject.Properties[$Group].Value
        if ($entry.Key -ne $Key) { return $false }
        foreach ($name in $Files) {
            $expected = $entry.Hashes.PSObject.Properties[$name].Value
            if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $Target $name) -Algorithm SHA256).Hash -ne $expected) { return $false }
        }
        foreach ($name in $Files) { Copy-Item -LiteralPath (Join-Path $Target $name) -Destination (Join-Path $Stage $name) -Force }
        Write-Step 'ok' "$Group is current; reusing verified installed files."
        return $true
    } catch { return $false }
}

function New-SetupHelperRecord {
    param([string]$Stage, [string]$Key, [string[]]$Files)
    $hashes = [ordered]@{}
    foreach ($name in $Files) { $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $Stage $name) -Algorithm SHA256).Hash }
    return [pscustomobject]@{ Key = $Key; Hashes = $hashes }
}

function Get-SetupGalleryRelease {
    # Digest pinned from the HTTPS-distributed binary, run-tested on Windows.
    return [pscustomobject]@{
        Version = '1.32.13'
        Url = 'https://codeberg.org/mikf/gallery-dl/releases/download/v1.32.13/gallery-dl.exe'
        Sha256 = 'f9a810132003701af4115a0ee07e84c3f9dd3e59d91bd4a82949f32e6c4318e7'
    }
}
