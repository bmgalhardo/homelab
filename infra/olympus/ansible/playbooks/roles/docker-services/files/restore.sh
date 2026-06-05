#!/bin/sh
set -e

BACKUP_FILE=$(ls -t /root/backups/daily/all_pg_daily_*.sql.gz | head -n1)
echo "[INFO] Testing restore from: $BACKUP_FILE"

docker run -d --rm \
  --name pg_restore_test \
  -e POSTGRES_PASSWORD=test123 \
  -v /backups:/backups \
  -p "5430":"5432" \
  postgres:17.6-alpine3.22

# Wait for Postgres to start
sleep 5

# Attempt restore
if gunzip -c $BACKUP_FILE | docker exec -i pg_restore_test psql -U postgres; then
  echo "[SUCCESS] Backup file restored successfully"
else
  echo "[ERROR] Backup restore failed!"
  docker logs pg_restore_test
  exit 1
fi

# Wait to kill the container
read -p "Press Enter to terminate restoration test..."

# Clean up
docker stop pg_restore_test
