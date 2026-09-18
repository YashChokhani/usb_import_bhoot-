# Encrypted USB backup kit

The existing `Tools\RUN_ME.bat`, profiler and USB autorun kit are unchanged. This is a
separate, opt-in backup installation. It is deliberately **not in RunScripts**.

## Start using it

1. On this drive's new recovery PC (PC 2), run `Tools\SETUP_NEW_PC.cmd`.
   It creates a new, non-exportable
   RSA-3072 recovery key in
   that Windows account's CNG key store. Only `UsbBackup\public-key.xml` goes on
   this USB. Re-running on the original account verifies/reuses the same key;
   a kit containing another public key will not be silently re-keyed. This
   drive is assigned its own key name, separate from the original toolkit.
   This replica was re-keyed: it ships with a fresh key identity and **no**
   public key, so the first `SETUP_NEW_PC.cmd` run binds it to a new
   recovery key on that PC. Backups from other kits cannot be restored here.
2. For any additional farm PC, sign in to the non-admin account that will use the drives.
   Double-click **Tools\INSTALL_USB_BACKUP.cmd** and type that computer's displayed
   name. No credentials, elevation or downloaded software are required.
3. Connect data drives. Backups go to
   **%LOCALAPPDATA%\UsbVault\Backups** on that farm PC's local NTFS disk.
   Run **Tools\USB_BACKUP_STATUS.cmd** to see progress, incomplete scans and errors.
   Keep the source connected until its scan completes without errors.

The installer blocks the existing autorun watcher's environment, redirected
stdin, noninteractive execution and RDP sessions. This is an intentional local
confirmation gate, **not proof of physical presence**: remote desktop-control
software and a user who can change scripts can bypass software-only gates.

This deployment USB is excluded by the root `.usbvault-ignore` marker. To back
it up too, remove that marker. Any other volume with this marker is also skipped.
Do not put the installer in `RunScripts`.

## What is backed up

Readable files in mounted, drive-letter USB volumes, including hidden files.
Removable volumes are detected without CIM; USB devices reported as fixed disks
also work when Windows permits disk/partition CIM queries. Status/logs report
when CIM is unavailable and detection is limited to removable volumes.

Detection polls roughly every five seconds; Windows device queries can make it
slower. Each connected volume gets a separate background worker, so a stalled
device does not block copying from other volumes. Workers scan again every
60 seconds. A reconnect/restart checks source content hashes against the local
index; unchanged content with unchanged timestamps reuses its encrypted object.
Within one connection, polling uses size and last-write time to avoid repeatedly
reading every file. A same-size change with its timestamp deliberately preserved
is detected on the next reconnect/restart. A changed timestamp can create a new
version even if contents match.

Changed files get new encrypted objects. Old versions remain. Deleted source
files do not delete backups. Failed files retry after ten minutes; inaccessible
directories retry on the next scan. A worker with no I/O heartbeat for five
minutes is restarted. A recorded failed-file cooldown lets other files proceed
after a stalled read. Unreadable sectors cannot be repaired by this software.

Junctions/symlinks/reparse points, root System Volume Information and $RECYCLE.BIN
are excluded. This is file-content backup: it does not preserve empty folders,
NTFS alternate streams, ACLs, file attributes, hard-link relationships, boot
sectors or a disk image. Last-write timestamps and relative paths are preserved.
Files inaccessible to the account, unsupported/overlong Windows paths, locked
files and read failures remain incomplete; check the counts and logs. No USB
content is executed by this backup kit.

## Encryption and recovery

Each `.uvf` object uses independent random AES-256 and HMAC-SHA256 keys. RSA-3072
OAEP-SHA256 wraps those keys with the recovery public key. AES-CBC encrypts the
relative path, volume identity, timestamp, length and file bytes. An
encrypt-then-MAC construction authenticates the complete header and ciphertext.
Recovery authenticates the entire object before creating any plaintext file.
Ciphertext filenames are random GUIDs. Source plaintext is streamed in memory;
there is no plaintext staging copy or plaintext archive on a farm PC.

The private key is kept in the **recovery account's Windows CNG software key
store**, with private export disabled. It is not on this stick and is never
distributed to farm machines. This is Windows-protected software key storage,
not a TPM/HSM guarantee against an administrator or compromised recovery PC.
Protect the original Windows installation and account: **losing that key/profile
can make every backup permanently unrecoverable.** The kit intentionally offers
no portable private-key export or password recovery.

To recover:

1. Copy the farm PC's `Backups` folder onto a local fixed disk on the original
   recovery PC. Keep farm-PC backups in separate folders when collecting them.
   `.uvf` files are self-contained; neither `State` nor the farm account is needed.
2. Sign in to the recovery account and run **Tools\RESTORE_USB_BACKUP.cmd**.
3. Enter the copied backup folder and a new/empty local output folder outside it.
   Recovery creates volume-ID subfolders and reconstructs the original paths.
   Multiple versions of a path get `.version-<random-id>` suffixes; the first
   unsuffixed version is **not guaranteed to be the newest**. Use preserved
   last-write timestamps to identify versions. No recovered file is overwritten.

Recovery tools are also copied to `%LOCALAPPDATA%\UsbVaultRecovery` during key
preparation, so the USB is not needed to decrypt:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\UsbVaultRecovery\Restore.ps1" -InputFolder 'C:\CollectedBackups' -OutputFolder 'C:\RecoveredUSB'
```

The public key alone cannot decrypt. Recovery rejects tampering, truncation,
wrong keys and unsafe paths. RSA/public-key encryption does not authenticate who
created a backup: someone with the public key can create another valid object.

## Persistence, disk space and removal

Requirements: Windows 10/11 or compatible Windows Server, Windows PowerShell 5.1,
.NET Framework 4.7.2 or newer, and a writable local NTFS user profile. Application
control/Constrained Language policies can block execution; this kit does not
circumvent them.

Installation copies the scripts and public key into `%LOCALAPPDATA%\UsbVault`.
The folder ACL grants access to this account, SYSTEM and Administrators. It adds
a visible **UsbVault.lnk** in this account's Startup folder and attempts a
least-privilege, interactive-only **UsbVault-<account SID>** scheduled task every
three minutes. Some non-admin policies forbid task creation; installation
explicitly reports that fallback. Startup still works and the supervisor still
restarts failed workers, but a killed supervisor then waits for the next sign-in.
One named mutex per component prevents duplicate active workers.

**Reboot persistence means restart after this account signs in.** There is no
pre-login/logged-off service without administrator installation. Sleep suspends
copying. A user or administrator can disable the watcher. This is visible backup
software, not tamper-proof persistence.

The default free-space reserve is 2 GiB. A file is postponed if there is not
enough room for the whole encrypted object plus that reserve. Other applications
or simultaneous copies can still consume free space; write failures are retried.
There is no automatic retention deletion or upload. Monitor storage and collect
the encrypted objects regularly; backup disks can fail too. Index files contain
path hashes, content hashes, sizes, times and object references (not raw names or
file contents); folder ACLs protect them. Logs omit source paths but report
hashed file identifiers and error classes. Process logs rotate at 1 MiB each;
logs from old processes are retained for troubleshooting.

Committed objects use atomic rename; incomplete ciphertext ends in `.partial`
and is never treated as a recovered backup. Index updates use atomic replacement.
A crash before index completion may leave an extra valid version, never a
plaintext backup. Source drives are never modified or deleted by the watcher.

Run **Tools\UNINSTALL_USB_BACKUP.cmd** on a farm account to disable it and remove its
Startup entry/task. A stop marker prevents further launches. Encrypted backups,
scripts, state and logs are retained for recovery; the recovery key is untouched.
Re-run the interactive installer to re-enable it.

## Verification

`UsbBackup\tests\Test-Vault.ps1` exercises encryption/recovery with ephemeral test
keys, boundary-size and large binary files, timestamps, tampering, truncation,
wrong/public-only keys, unsafe paths, file locking, space reservation and version
preservation. `Test-Worker.ps1` uses a temporary fixture directory and no startup
installation to test initial copying, reconnect deduplication, changed files,
cooldowns, retries, interrupted partial cleanup and recovery of every version.
Test fixtures and ephemeral keys are removed after the run. Result files record
the most recent successful runs. `Test-Recovery.ps1` additionally checks the
deployed public key against the installed recovery tool using generated test
data on the recovery PC. It uses the existing key and creates no new key.
Actual USB unplug/replug, standard-account
policy and sign-out/reboot acceptance should be checked on the first farm PC.

Cryptography API references:

- [Microsoft CNG key creation parameters](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.cngkeycreationparameters)
- [Microsoft RSA encryption padding API](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.encrypt)
- [Microsoft Task Scheduler command options](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create)
