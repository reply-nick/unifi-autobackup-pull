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

SSH_CMD="ssh -i /root/.ssh/unifi_backup -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# Get list of .unf files on remote
log "Fetching remote file list..."
remote_files=$($SSH_CMD "${UNIFI_USER}@${UNIFI_HOST}" "ls ${REMOTE_DIR}/*.unf 2>/dev/null") || true

if [ -z "$remote_files" ]; then
  log "No .unf files found on remote. Nothing to do."
else
  pull_errors=0
  pulled=0
  skipped=0

  for remote_file in $remote_files; do
    fname=$(basename "$remote_file")
    local_file="$LOCAL_DIR/$fname"

    if [ -f "$local_file" ]; then
      log "Skipping $fname (already exists locally)."
      skipped=$((skipped + 1))
      continue
    fi

    log "Pulling $fname ..."
    scp_exit=0
    $SSH_CMD -q "${UNIFI_USER}@${UNIFI_HOST}:${remote_file}" "$local_file" >> "$LOG_PATH" 2>&1 || scp_exit=$?

    if [ $scp_exit -eq 0 ]; then
      log "Pulled $fname successfully."
      pulled=$((pulled + 1))
    else
      log "ERROR: Failed to pull $fname (exit code $scp_exit)."
      pull_errors=$((pull_errors + 1))
      rm -f "$local_file"  # remove partial file
    fi
  done

  log "Summary: pulled=$pulled skipped=$skipped errors=$pull_errors"

  # Mirror deletions: remove local files no longer on remote
  for local_file in "$LOCAL_DIR"/*.unf; do
    [ -f "$local_file" ] || continue
    fname=$(basename "$local_file")
    if ! echo "$remote_files" | grep -qF "$fname"; then
      log "Removing $fname (no longer on remote)."
      rm -f "$local_file"
    fi
  done
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