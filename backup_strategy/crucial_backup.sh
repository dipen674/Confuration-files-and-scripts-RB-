#!/bin/bash

# --- CONFIGURATION ---
CONTAINER_NAME="postgres14"
DB_USER="myuser"
DB_NAME="mydatabase"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/home/vagrant/logs/crucial_backup.log"
BACKUP_PATH="/home/vagrant/backups/crucial_metadata_$TIMESTAMP.sql.gz"

# REMOTE INFO
REMOTE_USER="vagrant"
REMOTE_HOST="192.168.56.12"
REMOTE_DIR="/home/vagrant/backups_from_server_a/crucial"

# --- LOCAL SETUP ---
mkdir -p /home/vagrant/backups
mkdir -p /home/vagrant/logs
# Captures output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "-----------------------------------------------------"
echo "CRUCIAL BACKUP START: $(date)"
echo "-----------------------------------------------------"

# 1. Verification: Check if Docker container is actually running
if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "ERROR: Container $CONTAINER_NAME is not running. Aborting."
    exit 1
fi

# 2. SQL Export (Users & Orders)
echo "Step 1: Exporting 'users' and 'orders' tables..."
docker exec $CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME \
    -t 'users' -t 'orders' \
    | gzip -9 > "$BACKUP_PATH"

if [ -s "$BACKUP_PATH" ]; then
    echo "Export successful. File size: $(du -h "$BACKUP_PATH" | cut -f1)"
else
    echo "ERROR: Backup file is empty or was not created."
    exit 1
fi

# 3. Transfer to Server B
# We use --rsync-path to ensure the directory exists on the remote side
echo "Step 2: Syncing to Remote Server ($REMOTE_HOST)..."
rsync -avz --rsync-path="mkdir -p $REMOTE_DIR && rsync" "$BACKUP_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

if [ $? -eq 0 ]; then
    echo "SUCCESS: Sync complete. Cleaning up local file."
    rm "$BACKUP_PATH"
else
    echo "CRITICAL ERROR: rsync failed. Check remote permissions or SSH connection."
    exit 1
fi

echo "CRUCIAL BACKUP FINISHED: $(date)"
echo "-----------------------------------------------------"