@echo off
setlocal EnableExtensions
echo ==========================================================
echo      NEW INDEPENDENT USBVAULT - FIRST PC SETUP
echo ==========================================================
echo.
echo This creates this drive's private recovery key on this PC/account,
echo writes only its public key onto the USB, then installs USB backup.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\UsbBackup\Prepare-Recovery.ps1"
if errorlevel 1 (
    echo.
    echo RECOVERY KEY SETUP FAILED. Backup was not installed.
    pause
    exit /b 1
)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\UsbBackup\Install.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo INSTALLATION FAILED or cancelled. Review the error above.
pause
exit /b %RESULT%
