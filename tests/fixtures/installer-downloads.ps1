# Offline transport for installer-flow.Tests.ps1. All validation and installation
# code is real; executable version probes use marked fixture files.
function Get-SetupGalleryRelease {
    [pscustomobject]@{
        Version = '1.32.13'; Url = 'https://fixture.invalid/gallery-dl.exe'
        Sha256 = (Get-FileHash (Join-Path $env:SEEN_TEST_FIXTURES 'engine.bin')).Hash
    }
}
function Get-SetupFile {
    param($Url, $Destination, $Headers = @{}, $Attempts = 3, $IdleTimeoutSec = 45, $TimeoutSec = 1800)
    $base = $env:SEEN_TEST_FIXTURES
    switch -Regex ($Url) {
        'api.github.com/repos/MightBeSeen/.*/commits/' { Set-Content $Destination ('{"sha":"' + ('b' * 40) + '"}'); return }
        '^https://raw.githubusercontent.com/MightBeSeen/' {
            $name = [uri]::UnescapeDataString(($Url -split '/')[-1])
            Copy-Item -LiteralPath (Join-Path $env:SEEN_TEST_SOURCE $name) -Destination $Destination -Force
            return
        }
        '/SHA2-256SUMS$' { Set-Content $Destination ((Get-FileHash (Join-Path $base 'engine.bin')).Hash + '  yt-dlp.exe'); return }
        '/index.json$' { Set-Content $Destination '[{"version":"v24.0.0","lts":"LTS","files":["win-x64-zip"]}]'; return }
        '/SHASUMS256.txt$' { Set-Content $Destination ((Get-FileHash (Join-Path $base 'node.zip')).Hash + '  node-v24.0.0-win-x64.zip'); return }
        'api.github.com/repos/GyanD/codexffmpeg/releases/latest$' {
            @{ assets = @(@{ name = 'ffmpeg-9.0-essentials_build.zip'; digest = 'sha256:' + (Get-FileHash (Join-Path $base 'ffmpeg.zip')).Hash; browser_download_url = 'https://github.com/GyanD/codexffmpeg/releases/download/9.0/ffmpeg-9.0-essentials_build.zip' }) } |
                ConvertTo-Json -Depth 4 | Set-Content $Destination
            return
        }
        '/node-v.*\.zip$' { Copy-Item (Join-Path $base 'node.zip') $Destination; return }
        '/ffmpeg-.*\.zip$' { Copy-Item (Join-Path $base 'ffmpeg.zip') $Destination; return }
        '/(yt-dlp|gallery-dl)\.exe$' { Copy-Item (Join-Path $base 'engine.bin') $Destination; return }
        default { throw "Unexpected network request in offline test: $Url" }
    }
}
function Test-SetupHelper {
    param($Path, $Arguments, $TimeoutSec = 30)
    if ((Get-Content $Path -Raw).Trim() -ne 'fixture engine') { throw 'Unexpected helper contents' }
    $name = Split-Path -Leaf $Path
    Add-Content (Join-Path $env:SEEN_TEST_FIXTURES 'probes.txt') $name
    if ($env:SEEN_TEST_FAIL_HELPER -eq $name) { throw 'Injected helper failure' }
}
