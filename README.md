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
