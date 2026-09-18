SERVER FARM USB TOOLKIT
======================

Double-click START_HERE.cmd for the main menu.
You can also run the individual buttons inside Tools.

COMMON ACTIONS
  First PC 2 setup      Tools\SETUP_NEW_PC.cmd
  Reinstall backup      Tools\INSTALL_USB_BACKUP.cmd
  Check backup status   Tools\USB_BACKUP_STATUS.cmd
  Recover backups       Tools\RESTORE_USB_BACKUP.cmd
  Install old watcher   Tools\RUN_ME.bat
  Disable USB backup    Tools\UNINSTALL_USB_BACKUP.cmd
  Remove old watcher    Tools\UNINSTALL.bat
  Create recovery key   Tools\PREPARE_RECOVERY_KEY.cmd (run first on PC 2)

USB BACKUP
  Install once locally on each farm account and type its computer name.
  Encrypted backups are saved on that PC, not this USB:
    %LOCALAPPDATA%\UsbVault\Backups
  Copy backups to the original recovery PC/account to decrypt them.
  This new drive starts without a key. On PC 2, run
  Tools\SETUP_NEW_PC.cmd. PC 2 keeps its private key, writes only its public
  key onto this USB, and then installs backup for that account.
  Keep the recovery Windows account/key intact. Losing it can make all
  backups unrecoverable.
  No admin is required. Background operation resumes after sign-in, not
  before login. The optional keep-alive task depends on local Windows policy.

FOLDER MAP
  Tools          Launchers, recovery and uninstall buttons
  Documentation  Detailed setup, encryption, recovery and watcher guides
  profiles       Collected PC specification reports
  RunScripts     Scripts run by the original installed USB watcher
  autorun        Original watcher's source
  UsbBackup      Backup implementation, public key and verification scripts
  autorun-logs   Original watcher logs (may be hidden in Explorer)

DETAILED GUIDES
  Documentation\USB_BACKUP_README.md
  Documentation\AUTORUN_README.txt

The root host_probe.ps1, RunScripts, profiles, autorun and USB identity files
remain at their original paths for compatibility with existing farm setups.
The deployment USB is excluded from backups by .usbvault-ignore.
Existing system/hidden files and collected data have been left intact.
