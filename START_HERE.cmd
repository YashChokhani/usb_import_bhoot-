@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
:menu
cls
echo ==========================================================
echo                  SERVER FARM USB TOOLKIT
echo ==========================================================
echo.
echo   1  FIRST SETUP on PC 2 (create separate key + install)
echo   2  Check USB backup status
echo   3  Probe this PC's specs now
echo   4  Install the original script watcher
echo   5  Recover encrypted backups on the recovery PC
echo   6  Read the instructions
echo   7  Open all tools / uninstall options
echo   0  Exit
echo.
echo Backup installation requires a local computer-name confirmation.
echo Specs and autorun logs stay on this USB. Backups stay on each PC.
echo.
choice /c 12345670 /n /m "Choose an option: "
if errorlevel 8 goto done
if errorlevel 7 goto tools
if errorlevel 6 goto docs
if errorlevel 5 goto restore
if errorlevel 4 goto watcher
if errorlevel 3 goto probe
if errorlevel 2 goto status
if errorlevel 1 goto install
goto done
:install
call "%ROOT%Tools\SETUP_NEW_PC.cmd"
goto menu
:status
call "%ROOT%Tools\USB_BACKUP_STATUS.cmd"
goto menu
:probe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%host_probe.ps1" -OutDir "%ROOT%profiles"
pause
goto menu
:watcher
call "%ROOT%Tools\RUN_ME.bat"
goto menu
:restore
call "%ROOT%Tools\RESTORE_USB_BACKUP.cmd"
goto menu
:docs
start "" notepad.exe "%ROOT%README.txt"
goto menu
:tools
start "" explorer.exe "%ROOT%Tools"
goto menu
:done
endlocal
exit /b 0
