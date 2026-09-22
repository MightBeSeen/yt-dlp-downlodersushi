[CmdletBinding()]
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$core = [IO.File]::ReadAllText((Join-Path $root 'lib\update-core.ps1')).Replace("`r`n", "`n").TrimEnd()
$block = "# BEGIN GENERATED UPDATE CORE - edit lib/update-core.ps1, then run scripts/Sync-UpdateCore.ps1`n$core`n# END GENERATED UPDATE CORE"
foreach ($name in @('smart-downloader.ps1', 'Install Yt-dlp Downloader.cmd')) {
    $path = Join-Path $root $name
    $source = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
    $pattern = '(?ms)^# BEGIN GENERATED UPDATE CORE[^\n]*\n.*?^# END GENERATED UPDATE CORE'
    if (-not [regex]::IsMatch($source, $pattern)) { throw "Missing generated core markers in $name" }
    $updated = [regex]::Replace($source, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $block })
    if ($Check) {
        if ($updated -cne $source) { throw "$name has stale update code. Run scripts/Sync-UpdateCore.ps1." }
    } else {
        [IO.File]::WriteAllText($path, $updated.Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    }
}
# Both the installer and launcher ship under a primary (Yt-dlp) name and a legacy (Seen)
# name so existing users can still fetch either during the rename. Keep each pair byte-
# identical; the launcher pair used to drift silently because nothing synchronized it.
$pairs = @(
    @{ Primary = 'Install Yt-dlp Downloader.cmd'; Legacy = 'Install Seen Downloader.cmd'; What = 'installer' }
    @{ Primary = 'Yt-dlp Downloader.cmd'; Legacy = "Seen's yt-dlp Downloader.cmd"; What = 'launcher' }
)
foreach ($pair in $pairs) {
    $primary = Join-Path $root $pair.Primary
    $legacy = Join-Path $root $pair.Legacy
    if ($Check) {
        if ([IO.File]::ReadAllText($primary) -cne [IO.File]::ReadAllText($legacy)) { throw "Legacy $($pair.What) is stale. Run scripts/Sync-UpdateCore.ps1." }
    } else {
        Copy-Item -LiteralPath $primary -Destination $legacy -Force
    }
}
Write-Host 'Shared update core and compatibility installer/launcher are synchronized.'
