#!/bin/bash
set -e

PGHOST=postgres
PGUSER=postgres
BACKUP_BASE=/backups

TODAY=$(date +%F)
WEEK=$(date +%V)
MONTH=$(date +%Y-%m)

DAILY_DIR=$BACKUP_BASE/daily
WEEKLY_DIR=$BACKUP_BASE/weekly
MONTHLY_DIR=$BACKUP_BASE/monthly

mkdir -p $DAILY_DIR $WEEKLY_DIR $MONTHLY_DIR

echo "[INFO] Starting full PostgreSQL instance backup"

# Daily full backup (all databases)
DAILY_FILE=$DAILY_DIR/all_pg_daily_${TODAY}.sql.gz
pg_dumpall -h $PGHOST -U $PGUSER | gzip > $DAILY_FILE
echo "[INFO] Daily backup created: $DAILY_FILE"

# Weekly backup (Sunday)
if [ "$(date +%u)" -eq 7 ]; then
  WEEKLY_FILE=$WEEKLY_DIR/all_pg_weekly_$(date +%G-W%V).sql.gz
  cp $DAILY_FILE $WEEKLY_FILE
  echo "[INFO] Weekly backup saved: $WEEKLY_FILE"
fi

# Monthly backup (1st of month)
if [ "$(date +%d)" -eq 1 ]; then
  MONTHLY_FILE=$MONTHLY_DIR/all_pg_monthly_${MONTH}.sql.gz
  cp $DAILY_FILE $MONTHLY_FILE
  echo "[INFO] Monthly backup saved: $MONTHLY_FILE"
fi

# Cleanup policy
find $DAILY_DIR -type f -mtime +7 -delete
find $WEEKLY_DIR -type f -mtime +28 -delete
find $MONTHLY_DIR -type f -mtime +365 -delete

echo "[INFO] Backup rotation complete."
