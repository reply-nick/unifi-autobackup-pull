#!/bin/bash
set -euo pipefail

# Generate crontab from CRON_SCHEDULE env variable
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * *}"

# Validate CRON_SCHEDULE format (5 fields for minute, hour, day, month, weekday)
read -r MIN HOUR DOM MON DOW <<< "$CRON_SCHEDULE"
if [[ ! "$MIN" =~ ^[0-9*,/\-]+$ ]] || [[ ! "$HOUR" =~ ^[0-9*,/\-]+$ ]] || \
   [[ ! "$DOM" =~ ^[0-9*,/\-]+$ ]] || [[ ! "$MON" =~ ^[0-9*,/\-]+$ ]] || \
   [[ ! "$DOW" =~ ^[0-9*,/\-]+$ ]]; then
  echo "ERROR: Invalid CRON_SCHEDULE format: $CRON_SCHEDULE"
  echo "Expected format: 'minute hour day month weekday' (e.g., '0 3 * * *')"
  exit 1
fi

# Write crontab
echo "$CRON_SCHEDULE /app/pull-unifi-backup.sh" | crontab -
echo "Cron schedule set to: $CRON_SCHEDULE"

# Run cron in foreground (foreground mode for Docker)
exec /usr/sbin/cron -f
