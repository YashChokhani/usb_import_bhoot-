@echo off
rem ---------------------------------------------------------------------------
rem  10-profile.cmd  -  sample autorun payload: run the system profiler.
rem  Placed in \RunScripts\ so the watcher runs it automatically on insertion.
rem  USB_AUTORUN_ROOT is set by the watcher to this drive (e.g. "E:").
rem  Add your own scripts alongside this one; they run in filename order.
rem ---------------------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%USB_AUTORUN_ROOT%\host_probe.ps1" -OutDir "%USB_AUTORUN_ROOT%\profiles"
