#!/bin/bash

set -uo pipefail

# --- Configuration (all via environment variables) ---
UNIFI_HOST="${UNIFI_HOST:?UNIFI_HOST is required}"
UNIFI_USER="${UNIFI_USER:-root}"
REMOTE_DIR="${REMOTE_DIR:-/data/autobackup}"
LOG_PATH="${LOG_PATH:-/var/log/unifi-backup.log}"

# Backup destination (matches volume mount: /backups)
LOCAL_DIR="/backups"

# --- Helpers ---
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_PATH"
}

# --- Run ---
log "Starting UniFi backup pull from ${UNIFI_HOST}:${REMOTE_DIR} ..."

mkdir -p "$LOCAL_DIR"

rsync_exit=0
rsync -avz --delete --progress \
  -e "ssh -i /root/.ssh/unifi_backup -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
  "${UNIFI_USER}@${UNIFI_HOST}:${REMOTE_DIR}/" \
  "$LOCAL_DIR/" >> "$LOG_PATH" 2>&1 || rsync_exit=$?

if [ $rsync_exit -eq 0 ]; then
  log "Backup pulled successfully."
else
  log "ERROR: rsync failed with exit code $rsync_exit."
fi

# --- Optional: Copy to Samba share ---
if [ "${COPY_TO_SAMBA:-false}" = "true" ]; then

  SAMBA_SHARE="${SAMBA_SHARE:?SAMBA_SHARE is required when COPY_TO_SAMBA=true}"
  SAMBA_USER="${SAMBA_USER:?SAMBA_USER is required when COPY_TO_SAMBA=true}"
  SAMBA_PASSWORD="${SAMBA_PASSWORD:?SAMBA_PASSWORD is required when COPY_TO_SAMBA=true}"

  log "Copying backups to Samba share: $SAMBA_SHARE"

  if [ -n "${SAMBA_DOMAIN:-}" ]; then
    SMB_AUTH="-U ${SAMBA_USER}%${SAMBA_PASSWORD} -W ${SAMBA_DOMAIN}"
  else
    SMB_AUTH="-U ${SAMBA_USER}%${SAMBA_PASSWORD}"
  fi

  samba_errors=0
  while IFS= read -r -d '' f; do
    fname=$(basename "$f")
    log "Uploading $fname to Samba..."
    smbclient "$SAMBA_SHARE" $SMB_AUTH -c "put $f $fname" >> "$LOG_PATH" 2>&1 || {
      log "ERROR: Failed to upload $fname to Samba."
      samba_errors=$((samba_errors + 1))
    }
  done < <(find "$LOCAL_DIR" -name "*.unf" -type f -print0)

  if [ $samba_errors -eq 0 ]; then
    log "Samba copy completed successfully."
  else
    log "ERROR: Samba copy finished with $samba_errors failed file(s)."
  fi
fi

log "Done."