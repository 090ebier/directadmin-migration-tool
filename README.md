# DirectAdmin Migration Tool

A production-ready Bash wizard to **migrate DirectAdmin accounts** from a source server to a destination server using this workflow:

1. **Backup (multi-user)** on the source server (DirectAdmin task queue)
2. **Transfer backups** to destination (rsync, resumable)
3. **Restore (multi-backup)** on the destination server (DirectAdmin task queue)
4. **Post-restore rsync** of heavy data (`domains/` + `imap/`) for speed and reliability
5. **Ownership fixes** on destination after syncing

Designed for real-world migrations to a newer server / infrastructure.

---

## Repository

- Repo: `directadmin-migration-tool`
- Script: `da-backup-restore-migrate.sh`

---

## Quick Run (One-liner)

Run directly on the **source** server:

```bash
bash <(curl -kL --progress-bar https://raw.githubusercontent.com/090ebier/directadmin-migration-tool/refs/heads/main/da-backup-restore-migrate.sh)
````

### Notes

* This downloads and executes the script in one step.
* Run as **root** (recommended).
* A detailed log is saved under:

  * `/var/log/da_backup_restore_YYYYMMDD_HHMMSS.log`

---

## Features

* Multi-user backup/restore using **one DirectAdmin task** per phase
* **Resumable rsync** (great for large mailboxes)
* Human-readable progress (KB/MB/GB) + detailed `--stats`
* Clean terminal UI (sections, colors, spinner, consistent prompts)
* Quiet SSH behavior (no `known_hosts` spam / no “Permanently added …” messages)
* SSH warm-up and connectivity validation before heavy steps
* Automatic destination backup directory creation + permission preparation for restore

---

## Requirements

### Source server

* `bash`, `ssh`, `sshpass`, `rsync`
* DirectAdmin installed and working:

  * `/usr/local/directadmin/directadmin`

### Destination server

* DirectAdmin installed and working
* SSH access (typically `root`) to:

  * create/write backup path
  * write to DirectAdmin `task.queue`
  * run `directadmin taskq`
  * fix permissions/ownership after restore

---

## What the script syncs

After DirectAdmin restore is triggered, the script does a heavy-data sync for each selected user:

* `/home/<user>/domains/`
* `/home/<user>/imap/`

Then it fixes ownership:

* `domains` → `<user>:<user>`
* `imap` → `<user>:mail` if group `mail` exists, otherwise `<user>:<user>`

---

## Important Behavior (Read This)

### rsync mirrors data (can delete extra files on destination)

The script uses rsync with a delete behavior (`--delete-delay`).
That means **destination is treated as a mirror** for the synced paths:

* If a file exists on destination but not on source, it may be removed on destination.

This is usually the desired behavior for **clean migrations to a fresh server**.

If you want **merge-only** behavior (never delete destination extras), remove `--delete-delay` from the rsync options in the script.

### Destination should be clean for best results

If users/domains already exist on destination, restore may fail due to conflicts (e.g., symlinks already exist).
For smooth migrations, migrate into a clean environment or remove conflicts before restore.

---

## Usage (Interactive Wizard)

When you run the script, it will ask for:

* Destination server IP/hostname
* SSH port
* SSH username
* Destination backup path
* Restore IP (auto if destination input is an IP)
* SSH password
* Account selection (single number, range, reseller, or select all)

---

## Logging & Troubleshooting

### Main log file

The script prints the log path at startup and writes everything to:

* `/var/log/da_backup_restore_*.log`

### If restore fails

Check DirectAdmin logs on the destination server (common locations):

* `/usr/local/directadmin/data/admin/backup_restore.log`
* `/usr/local/directadmin/data/admin/backup.log`

---

## Security Notes

* The script uses `sshpass` (password-based SSH) for automation.
* SSH host key storage is disabled for clean output (no `known_hosts` writes).
* For long-term production usage, consider switching to SSH keys.

