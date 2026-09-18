USB AUTORUN KIT  (per-user, no admin)
=====================================

ENCRYPTED USB BACKUP (separate opt-in kit)
  See USB_BACKUP_README.md. Run Tools\INSTALL_USB_BACKUP.cmd locally on each farm
  account to enable encrypted backup of data USB drives. This is separate from
  Tools\RUN_ME.bat and is not automatically deployed by RunScripts.

WHAT IT DOES
  Run Tools\RUN_ME.bat ONCE on a PC. After that, every time you plug THIS drive into
  that account, every script in \RunScripts\ runs automatically - no clicking.
  A sample payload (the system profiler) is already in \RunScripts\.

  Repeat the one-time Tools\RUN_ME.bat on each PC you want autorun on. The watcher is
  per-user, so it runs when that account is logged in.

FIRST-TIME SETUP (once per PC)
  1. Plug in the stick (any drive letter).
  2. Double-click Tools\RUN_ME.bat.
  3. It installs a small watcher for your account and starts it now. Done.

ALWAYS ON (survives restarts and crashes)
  Setup keeps the watcher running for your account with two per-user pieces,
  neither needing admin:
    * a Startup-folder entry     -> starts it instantly when you log on
    * a Scheduled Task (3 min)   -> restarts it if it is ever killed/crashes,
                                    and re-arms it after a reboot + logon
  A mutex ensures only one watcher runs at a time. It runs whenever this
  account is logged in. (Running before login / while logged off would require
  a Windows service and admin rights, which this kit intentionally avoids.)

AFTER THAT
  Just plug the drive in. \RunScripts\ runs automatically on insertion and at
  each logon while the drive is present.

ADDING YOUR OWN SCRIPTS
  Drop .ps1, .bat, or .cmd files into \RunScripts\. They run in filename order
  (number them: 10-, 20-, ...). Each script gets two environment variables:
      USB_AUTORUN_ROOT    the drive, e.g. "E:"
      USB_AUTORUN_OUTPUT  a per-run output/log folder on the drive
  Output and logs land in  \autorun-logs\<COMPUTERNAME>\<timestamp>\.

FILES ON THE STICK
  Tools\RUN_ME.bat          <- run once per PC to enable autorun
  Tools\UNINSTALL.bat       <- run on a PC to disable autorun there
  autorun\watcher.ps1 <- the watcher (plain text; copied to your profile on setup)
  RunScripts\         <- put scripts here; they auto-run (10-profile.cmd sample)
  host_probe.ps1      <- the system profiler used by the sample
  profiles\           <- profiler output, one JSON per PC
  autorun-logs\       <- per-run logs from autorun executions
  .usb_autorun_v2_id  <- unique token that scopes the watcher to THIS drive
  README.txt          <- this file

TURNING IT OFF
  Run Tools\UNINSTALL.bat on the PC. It deletes the keep-alive Scheduled Task, stops
  the watcher, removes the logon entry, and deletes the installed copy from
  %LOCALAPPDATA%\UsbAutorun. Logs and profiles already on the stick are left
  alone.

WHAT IT DOES / DOES NOT TOUCH
  * Per-user only; no administrator rights required.
  * Does NOT modify the registry or the machine-wide AutoRun/AutoPlay policy.
  * Scoped: only the drive carrying the matching .usb_autorun_v2_id token is
    acted on; other USB drives and older toolkit drives are ignored.
  * Visible and reversible: a Startup-folder entry (UsbAutorun.cmd), a
    Scheduled Task ("UsbAutorunWatcher", visible in Task Scheduler), a folder
    in %LOCALAPPDATA%\UsbAutorun (watcher + launch.cmd + watcher.log +
    watcher.pid), and Tools\UNINSTALL.bat.

LIMITS / NOTES
  * Runs at logon, not before login; only while the account is signed in.
  * Detection polls every ~2s; keep the drive connected until scripts finish.
  * -ExecutionPolicy Bypass is per-invocation and changes nothing persistent.
  * Anyone who can copy this drive's identity token + scripts can trigger this
    account. Enable it only on machines you administer.
  * Everything here is plain text - open Tools\RUN_ME.bat or watcher.ps1 to read it.

RUN THE PROFILER BY HAND (optional, without autorun)
  powershell -NoProfile -ExecutionPolicy Bypass -File host_probe.ps1 ^
             -OutDir profiles
