@echo off
setlocal
cd /d "%~dp0"
set "SEEN_LAUNCHER=1"

:run
where pwsh.exe >nul 2>&1
if errorlevel 1 goto windows_powershell

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0smart-downloader.ps1"
goto finished

:windows_powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0smart-downloader.ps1"

:finished
if "%errorlevel%"=="42" goto run
if errorlevel 1 (
    echo.
    echo Yt-dlp Downloader stopped because of an error.
    pause
)

endlocal
