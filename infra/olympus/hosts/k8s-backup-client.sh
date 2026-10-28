#!/bin/sh
# Run on hades. Creates an SFTP-only, chrooted backup target for one client:
#   user <client>, writes to /odin/k8s-backups/<client>, key auth only.
# Usage: k8s-backup-client.sh <client> <public-key-file>
set -eu

CLIENT=$1
PUBKEY=$2
ROOT=/odin/k8s-backups
HOME_DIR=/var/lib/k8s-backup/$CLIENT

zfs list odin/k8s-backups >/dev/null 2>&1 || zfs create -o quota=200G odin/k8s-backups
chown root:root "$ROOT"
chmod 755 "$ROOT"

getent group k8s-backup >/dev/null || groupadd --system k8s-backup
id "$CLIENT" >/dev/null 2>&1 ||
  useradd --system --gid k8s-backup --home-dir "$HOME_DIR" --shell /usr/sbin/nologin "$CLIENT"

install -d -o "$CLIENT" -g k8s-backup -m 700 "$ROOT/$CLIENT"
install -d -o "$CLIENT" -g k8s-backup -m 700 "$HOME_DIR" "$HOME_DIR/.ssh"
install -o "$CLIENT" -g k8s-backup -m 600 "$PUBKEY" "$HOME_DIR/.ssh/authorized_keys"

sshd -t
systemctl reload ssh
echo "ok: sftp $CLIENT@$(hostname) -> $ROOT/$CLIENT"
