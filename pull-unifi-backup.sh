#!/bin/bash
set -euo pipefail

# --- Configuration (all via environment variables) ---
UNIFI_HOST="${UNIFI_HOST:?UNIFI_HOST is required}"
UNIFI_USER="${UNIFI_USER:-root}"
UNIFI_KEY_PATH="${UNIFI_KEY_PATH:-/root/.ssh/unifi_backup}"
REMOTE_DIR="${REMOTE_DIR:-/data/autobackup}"
LOCAL_DIR="${LOCAL_DIR:-/backups}"
LOG_PATH="${LOG_PATH:-/var/log/unifi-backup.log}"

# --- Run ---
DATE=$(date +"%Y-%m-%d %H:%M:%S")
echo "[$DATE] Starting UniFi backup pull..." >> "$LOG_PATH"

mkdir -p "$LOCAL_DIR"

rsync -avz --progress \
  -e "ssh -i $UNIFI_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
  "${UNIFI_USER}@${UNIFI_HOST}:${REMOTE_DIR}/" \
  "$LOCAL_DIR/" >> "$LOG_PATH" 2>&1

if [ $? -eq 0 ]; then
  echo "[$DATE] Backup pulled successfully." >> "$LOG_PATH"
else
  echo "[$DATE] ERROR: rsync failed!" >> "$LOG_PATH"
fi

# --- Optional: Copy to Samba share ---
if [ "${COPY_TO_SAMBA:-false}" = "true" ]; then
  DATE=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$DATE] Copying backups to Samba share: $SAMBA_SHARE" >> "$LOG_PATH"

  if [ -n "${SAMBA_DOMAIN:-}" ]; then
    SMB_AUTH="-U ${SAMBA_USER}%${SAMBA_PASSWORD} -W ${SAMBA_DOMAIN}"
  else
    SMB_AUTH="-U ${SAMBA_USER}%${SAMBA_PASSWORD}"
  fi

  UNF_FILES=$(find "$LOCAL_DIR" -name "*.unf" -type f)
  if [ -n "$UNF_FILES" ]; then
    echo "$UNF_FILES" | sed 's|.*|mput &|' | smbclient "$SAMBA_SHARE" $SMB_AUTH --no-pass >> "$LOG_PATH" 2>&1
    if [ $? -eq 0 ]; then
      echo "[$DATE] Samba copy completed successfully." >> "$LOG_PATH"
    else
      echo "[$DATE] ERROR: Samba copy failed!" >> "$LOG_PATH"
    fi
  else
    echo "[$DATE] No .unf files found to copy to Samba." >> "$LOG_PATH"
  fi
fi
