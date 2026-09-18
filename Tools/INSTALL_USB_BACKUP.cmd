@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\UsbBackup\Install.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo INSTALLATION FAILED or cancelled. Review the error above.
pause
exit /b %RESULT%
