[CmdletBinding()]
param([ValidateSet('powershell','pwsh')][string]$Engine = 'powershell')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
& (Join-Path $PSScriptRoot 'Sync-UpdateCore.ps1') -Check
if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { throw 'Tests need Node.js on PATH (the installed app does not).' }
$logs = Join-Path $root '.test-temp\test-results'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$failed = @()
foreach ($test in (Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.Tests.ps1' | Sort-Object Name)) {
    $log = Join-Path $logs "$Engine-$($test.BaseName).log"
    & "$Engine.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File $test.FullName *> $log
    if ($LASTEXITCODE -ne 0) {
        $failed += $test.Name
        Write-Host "FAIL: $($test.Name)"
        Get-Content -LiteralPath $log -Tail 25 | Write-Host
    } else { Write-Host "PASS: $($test.Name)" }
}
if ($failed.Count) { throw "Failed suites: $($failed -join ', ')" }
Write-Host "All suites passed on $Engine. Logs: $logs"
