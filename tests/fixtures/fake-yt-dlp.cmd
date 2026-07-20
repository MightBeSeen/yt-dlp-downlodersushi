@echo off
setlocal

echo %* | findstr /C:"--dump-single-json" >nul
if not errorlevel 1 (
    echo {"_type":"video","id":"yxf9w1gJea4","live_status":"not_live","is_live":false}
    exit /b 0
)

set "all_args=%*"
set "target=."
:parse_args
if "%~1"=="" goto run_download
if /I "%~1"=="-P" (
    set "target=%~2"
    shift
    shift
    goto parse_args
)
shift
goto parse_args

:run_download
if not exist "%target%" mkdir "%target%"
> "%target%\fake-output.mp4" echo fake media
echo ARGS:%all_args%
echo [download] 10.0%% of 1.00MiB at 1.00MiB/s ETA 00:01
echo [download] 50.0%% of 1.00MiB at 2.00MiB/s ETA 00:01
echo [download] 90.0%% of 1.00MiB at 3.00MiB/s ETA 00:00
echo [download] 100.0%% of 1.00MiB at 3.00MiB/s ETA 00:00
echo __SMART_DOWNLOADER_FILE__:%target%\fake-output.mp4
exit /b 0
