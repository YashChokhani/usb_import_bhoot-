@echo off
setlocal enableextensions

rem ===========================================================================
rem  UNINSTALL.bat  -  remove the per-user USB autorun from THIS PC.
rem  Deletes the keep-alive Scheduled Task, stops the running watcher, removes
rem  the logon entry, and deletes the installed copy. Logs/profiles already on
rem  the stick are left alone.
rem ===========================================================================

set "APP=%LOCALAPPDATA%\UsbAutorun"
set "LAUNCH=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\UsbAutorun.cmd"
set "TASK=UsbAutorunWatcher"

echo Removing USB autorun for %USERNAME% on %COMPUTERNAME%...

rem --- (1) delete the keep-alive task so it can't relaunch the watcher ---
schtasks /Delete /TN "%TASK%" /F >nul 2>nul

rem --- (2) stop the running watcher via its PID file ---
if exist "%APP%\watcher.pid" (
    for /f "usebackq tokens=1" %%P in ("%APP%\watcher.pid") do taskkill /pid %%P /f >nul 2>nul
)

rem --- (3) fallback: stop any powershell process running our watcher.ps1 ---
rem     (done inside PowerShell to avoid batch mangling '='; excludes this
rem      helper's own PID so the matching command line does not kill itself)
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*UsbAutorun*watcher.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>nul

rem --- (4) remove the logon entry and the installed copy ---
if exist "%LAUNCH%" del /f /q "%LAUNCH%" >nul 2>nul
if exist "%APP%"    rmdir /s /q "%APP%"   >nul 2>nul

echo Done. Autorun is removed from this account on %COMPUTERNAME%.
echo (Files, logs, and profiles already on the stick are untouched.)
echo.
pause
endlocal
