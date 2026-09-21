@echo off
rem Minimal gallery-dl stand-in for offline tests. It reads -D <dir>, writes two
rem fake media files there, prints their paths (as real gallery-dl does), and
rem honours control env vars:
rem   FAKE_GDL_EXIT    - process exit code (default 0)
rem   FAKE_GDL_BLOCK   - if set, emit a rate-limit line to stderr
rem   FAKE_GDL_EMPTY   - if set, download nothing
rem   FAKE_GDL_VERSION - printed for --version (default 1.32.13)
setlocal enabledelayedexpansion

if "%~1"=="--version" (
    if defined FAKE_GDL_VERSION ( echo !FAKE_GDL_VERSION! ) else ( echo 1.32.13 )
    exit /b 0
)

rem Destination is the argument right after -D.
set "DEST="
set "PREV="
for %%A in (%*) do (
    if "!PREV!"=="-D" set "DEST=%%~A"
    set "PREV=%%~A"
)

if defined FAKE_GDL_BLOCK (
    echo urllib.error.HTTPError: HTTP Error 429: Too Many Requests 1>&2
)

if not defined FAKE_GDL_EMPTY (
    if defined DEST (
        if not exist "!DEST!" mkdir "!DEST!"
        echo fake-image-bytes> "!DEST!\001_media.jpg"
        echo fake-video-bytes> "!DEST!\002_media.mp4"
        echo !DEST!\001_media.jpg
        echo !DEST!\002_media.mp4
    )
)

if defined FAKE_GDL_EXIT ( exit /b %FAKE_GDL_EXIT% )
exit /b 0
