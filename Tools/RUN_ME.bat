@echo off
setlocal enableextensions

rem ===========================================================================
rem  RUN_ME.bat  -  ONE-TIME autorun setup for THIS Windows account (no admin)
rem
rem  Run once per PC. Installs a small per-user watcher that auto-runs every
rem  script in this stick's \RunScripts\ folder whenever you plug THIS drive in.
rem
rem  "Always on" for this account is achieved with TWO per-user mechanisms:
rem    * a Startup-folder entry  -> starts the watcher instantly at logon
rem    * a Scheduled Task (every 3 min) -> restarts it if it is ever killed or
rem      crashes, and re-arms it after a reboot+logon
rem  A mutex inside the watcher means only one copy ever runs.
rem
rem  No admin, no registry changes, no machine-wide AutoRun change. It runs only
rem  while this account is logged in (running before login needs a service +
rem  admin, which this kit deliberately avoids). Remove with UNINSTALL.bat.
rem ===========================================================================

set "STICK=%~d0"
set "HERE=%~dp0..\"
set "APP=%LOCALAPPDATA%\UsbAutorun"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "LAUNCH=%STARTUP%\UsbAutorun.cmd"
set "TASK=UsbAutorunWatcher"

echo ==========================================================
echo   USB Autorun - one-time setup (per-user, no admin)
echo   Drive: %STICK%   Account: %USERNAME%   PC: %COMPUTERNAME%
echo ==========================================================
echo.

if not exist "%HERE%autorun\watcher.ps1" (
    echo [ERROR] autorun\watcher.ps1 is missing on the stick. The stick is
    echo         incomplete - cannot set up autorun.
    goto :end
)

rem --- make sure the stick has the expected pieces ---
if not exist "%HERE%RunScripts" mkdir "%HERE%RunScripts"
if not exist "%HERE%profiles"   mkdir "%HERE%profiles"
rem A unique token binds this installed watcher to this physical toolkit.
if not exist "%HERE%.usb_autorun_v2_id" (
    echo [ERROR] This drive's unique autorun token is missing. Setup aborted.
    goto :end
)

rem --- install the watcher + a small detached launcher into this profile ---
if not exist "%APP%" mkdir "%APP%"
copy /y "%HERE%autorun\watcher.ps1" "%APP%\watcher.ps1" >nul
if errorlevel 1 (
    echo [ERROR] Could not copy the watcher to "%APP%". Setup aborted.
    goto :end
)
copy /y "%HERE%.usb_autorun_v2_id" "%APP%\drive-token.txt" >nul
if errorlevel 1 (
    echo [ERROR] Could not install this drive's identity token. Setup aborted.
    goto :end
)
> "%APP%\launch.cmd" echo @echo off
>> "%APP%\launch.cmd" echo start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%%~dp0watcher.ps1"

rem --- (1) start at logon: visible Startup-folder entry ---
> "%LAUNCH%" echo @echo off
>> "%LAUNCH%" echo call "%APP%\launch.cmd"

rem --- (2) stay alive: per-user Scheduled Task relaunches every 3 min ---
rem     (interactive, least-privilege; the watcher's mutex makes relaunch a
rem      no-op when it is already running, and restarts it if it died)
schtasks /Create /SC MINUTE /MO 3 /TN "%TASK%" /TR "\"%APP%\launch.cmd\"" /IT /RL LIMITED /F >nul 2>nul
if errorlevel 1 (
    echo [note] Could not create the keep-alive Scheduled Task on this PC.
    echo        Autorun will still start at each logon via the Startup entry,
    echo        but it will not auto-restart if killed mid-session.
) else (
    echo Keep-alive task installed: %TASK% ^(every 3 min, this account^)
)

rem --- start it right now (profiles this PC immediately) ---
call "%APP%\launch.cmd"

echo.
echo Setup complete on %COMPUTERNAME% - autorun is now ALWAYS ON for %USERNAME%.
echo.
echo Whenever you plug THIS drive into this account:
echo    every script in  %STICK%\RunScripts\  runs automatically,
echo    output/logs land in  %STICK%\autorun-logs\%COMPUTERNAME%\
echo.
echo   Watcher     : %APP%\watcher.ps1
echo   Starts at   : logon (%LAUNCH%)
echo   Kept alive  : Scheduled Task "%TASK%" every 3 min
echo   Activity log: %APP%\watcher.log
echo.
echo To turn this off on this PC, run  UNINSTALL.bat  from the stick.
echo (Repeat this setup once on each PC you want autorun on.)

:end
echo.
pause
endlocal
