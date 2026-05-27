FROM alpine:3.20

RUN apk add --no-cache \
    openssh-client \
    rsync \
    cron \
    bash \
    samba-client

WORKDIR /app

COPY pull-unifi-backup.sh /app/pull-unifi-backup.sh
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/pull-unifi-backup.sh /app/entrypoint.sh

VOLUME ["/backups"]

ENTRYPOINT ["/app/entrypoint.sh"]
