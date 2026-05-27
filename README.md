# UniFi OS — Automatic Local Backup (Pull from NAS)

The most resilient approach: your NAS (or any Linux machine) pulls the backup file
from the UniFi console on a schedule. Nothing persistent needs to be configured on
the UniFi side, so firmware updates cannot break it.

---

## Prerequisites

- SSH enabled on the UniFi console: **Settings > System > Advanced > SSH**
- Docker and Docker Compose installed on your machine
- A machine on the same network as the UniFi console

---

## Step 1 — Enable SSH on the UniFi Console

1. Log into UniFi OS
2. Go to **Settings > System > Advanced**
3. Enable **SSH** and set a strong password (or use key auth — see Step 2)

---

## Step 2 — Set Up SSH Key Authentication

Run this on your **NAS / pull machine** (not on UniFi):

```bash
# Generate a key pair if you don't have one
ssh-keygen -t ed25519 -C "nas-unifi-backup" -f ~/.ssh/unifi_backup

# Copy the public key to the UniFi console
ssh-copy-id -i ~/.ssh/unifi_backup.pub root@<unifi-console-ip>
```

Test that it works without a password prompt:

```bash
ssh -i ~/.ssh/unifi_backup root@<unifi-console-ip> "echo connected"
```

> **Note:** On some UniFi OS versions `ssh-copy-id` may not work directly.
> If so, manually append the public key:
> ```bash
> cat ~/.ssh/unifi_backup.pub | ssh root@<unifi-console-ip> \
>   "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
> ```

---

## Step 3 — Find the Backup Location on UniFi

SSH in and confirm where backup files live:

```bash
ssh -i ~/.ssh/unifi_backup root@<unifi-console-ip> \
  "find /data -name '*.unf' 2>/dev/null"
```

Common locations:

| Device | Path |
|---|---|
| Dream Machine / UDM-Pro | `/data/autobackup/` |
| CloudKey Gen2+ | `/data/autobackup/` or `/srv/unifi-core/backups/` |

---

## Step 4 — Docker Setup (Recommended)

### 4.1 — Prepare SSH Key

```bash
mkdir -p ssh_keys
cp ~/.ssh/unifi_backup ssh_keys/unifi_backup
chmod 600 ssh_keys/unifi_backup
```

### 4.2 — Configure

Edit `docker-compose.yml` and update at minimum:

- `UNIFI_HOST` — your UniFi console IP address
- `CRON_SCHEDULE` — cron expression for backup schedule (default: `0 3 * * *`)

### 4.3 — Build and Run

```bash
docker compose up -d
```

### 4.4 — Verify

```bash
# Check logs
docker compose logs -f

# Verify backups were pulled
ls ./backups/
```

### How It Works

1. **List** — SSH into the UniFi console and list all `.unf` backup files
2. **Pull** — Download each file with `scp`, skipping ones already present locally
3. **Mirror deletions** — Remove local `.unf` files that no longer exist on the remote
4. **Optional Samba upload** — Upload each `.unf` file to a Samba share, one at a time
5. **Log summary** — Prints `pulled=N skipped=N errors=N`

### Configuration Reference

| Env Var | Default | Description |
|---|---|---|
| `CRON_SCHEDULE` | `0 3 * * *` | Cron expression (minute hour day month weekday) |
| `UNIFI_HOST` | *(required)* | UniFi console IP/hostname |
| `UNIFI_USER` | `root` | SSH username |
| `REMOTE_DIR` | `/data/autobackup` | Remote backup directory on UniFi |
| `LOG_PATH` | `/var/log/unifi-backup.log` | Log file location |
| `COPY_TO_SAMBA` | `false` | Enable copying backups to a Samba share |
| `SAMBA_SHARE` | — | Samba share URL (e.g. `//192.168.1.10/backups`) |
| `SAMBA_USER` | — | Samba username |
| `SAMBA_PASSWORD` | — | Samba password |
| `SAMBA_DOMAIN` | — | Samba domain (optional) |

### Example Schedules

| Schedule | Expression |
|---|---|
| Daily at 3:00 AM | `0 3 * * *` |
| Every 6 hours | `0 */6 * * *` |
| Every Sunday at 2:00 AM | `0 2 * * 0` |
| Every 12 hours | `0 */12 * * *` |

---

## Step 5 — Make Sure UniFi Auto-Backup Is Enabled

The pull script copies whatever files UniFi has already generated locally.
Make sure UniFi OS is actually creating them:

1. Go to **Settings > Control Plane > Backups**
2. Enable **System Backups**

UniFi will create a backup weekly and before major updates. The pull script
will grab the latest files each time it runs.

---

## Alternative: Manual NAS Setup (No Docker)

For users without Docker, the manual approach is also supported.

### Create the Pull Script on Your NAS

Create `/opt/scripts/pull-unifi-backup.sh` (or any path you prefer):

```bash
#!/bin/bash
set -uo pipefail

# --- Configuration ---
UNIFI_HOST="192.168.1.1"
UNIFI_USER="root"
UNIFI_KEY="/home/youruser/.ssh/unifi_backup"
REMOTE_DIR="/data/autobackup"
LOCAL_DIR="/volume1/backups/unifi"   # adjust to your NAS share path
LOG="/var/log/unifi-backup.log"

# --- Helpers ---
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG"
}

# --- Run ---
log "Starting UniFi backup pull from ${UNIFI_HOST}:${REMOTE_DIR} ..."

mkdir -p "$LOCAL_DIR"

SSH_CMD="ssh -i $UNIFI_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Get list of .unf files on remote
log "Fetching remote file list..."
remote_files=()
while IFS= read -r -d '' f; do
  remote_files+=("$f")
done < <($SSH_CMD "${UNIFI_USER}@${UNIFI_HOST}" "find ${REMOTE_DIR} -maxdepth 1 -name '*.unf' -type f -print0 2>/dev/null")

if [ ${#remote_files[@]} -eq 0 ]; then
  log "No .unf files found on remote. Nothing to do."
else
  pull_errors=0
  pulled=0
  skipped=0

  for remote_file in "${remote_files[@]}"; do
    fname=$(basename "$remote_file")
    local_file="$LOCAL_DIR/$fname"

    if [ -f "$local_file" ]; then
      log "Skipping $fname (already exists locally)."
      skipped=$((skipped + 1))
      continue
    fi

    log "Pulling $fname ..."
    scp_exit=0
    $SSH_CMD -q "${UNIFI_USER}@${UNIFI_HOST}:${remote_file}" "$local_file" >> "$LOG" 2>&1 || scp_exit=$?

    if [ $scp_exit -eq 0 ]; then
      log "Pulled $fname successfully."
      pulled=$((pulled + 1))
    else
      log "ERROR: Failed to pull $fname (exit code $scp_exit)."
      pull_errors=$((pull_errors + 1))
      rm -f "$local_file"
    fi
  done

  log "Summary: pulled=$pulled skipped=$skipped errors=$pull_errors"

  # Mirror deletions
  for local_file in "$LOCAL_DIR"/*.unf; do
    [ -f "$local_file" ] || continue
    fname=$(basename "$local_file")
    found=false
    for rf in "${remote_files[@]}"; do
      if [[ "$(basename "$rf")" == "$fname" ]]; then
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      log "Removing $fname (no longer on remote)."
      rm -f "$local_file"
    fi
  done
fi

log "Done."
```

Make it executable:

```bash
chmod +x /opt/scripts/pull-unifi-backup.sh
```

Test it manually first:

```bash
/opt/scripts/pull-unifi-backup.sh
cat /var/log/unifi-backup.log
```

### Schedule with Cron on the NAS

Open the crontab on your NAS:

```bash
crontab -e
```

Add a daily job at 3:00 AM:

```
0 3 * * * /opt/scripts/pull-unifi-backup.sh
```

> On Synology or QNAP NAS, you can alternatively use the built-in
> **Task Scheduler** UI to schedule the script — no crontab editing needed.

---

## Why This Approach Is Better

| Concern | fstab / push from UniFi | Pull from NAS |
|---|---|---|
| Survives firmware updates | ❌ fstab can be wiped | ✅ nothing on UniFi to wipe |
| Credentials stored safely | ⚠️ plaintext on console | ✅ on your NAS |
| Failure impact | Breaks on UniFi side | NAS logs the error, UniFi unaffected |
| Complexity on UniFi | Medium | Minimal (just SSH + key) |

---

## Troubleshooting

**scp fails with "Permission denied"**
- Confirm the SSH key works: `ssh -i ~/.ssh/unifi_backup root@<ip> "ls /data/autobackup/"`
- Check that `/data/autobackup/` contains `.unf` files

**No `.unf` files found**
- Trigger a manual backup: **Settings > Control Plane > Backups > Create Backup**
- Verify the path with: `find /data -name "*.unf"`

**Container won't start**
- Check logs: `docker compose logs`
- Ensure `UNIFI_HOST` is set and reachable from the Docker host

**SSH connection refused (Docker)**
- Confirm SSH is enabled on the UniFi console
- Verify SSH key permissions: `chmod 600 ssh_keys/unifi_backup`

**Cron doesn't run**
- Docker: check logs with `docker compose logs`
- Manual: check cron logs: `grep CRON /var/log/syslog`
- Confirm the script is executable: `ls -la /opt/scripts/pull-unifi-backup.sh`
