#!/bin/bash

# --- CONFIGURATION ---
CONTAINER_NAME="postgres14"
DB_USER="myuser"
DB_PASS="mypassword" 
DB_NAME="mydatabase"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/home/vagrant/logs/crucial_backup.log"
BACKUP_PATH="/home/vagrant/backups/crucial_metadata_$TIMESTAMP.sql.gz"
TABLE_NAME="audit_logs" # The table to EXCLUDE

# REMOTE INFO
REMOTE_USER="vagrant"
REMOTE_HOST="192.168.56.12"
REMOTE_DIR="/home/vagrant/backups_from_server_a/crucial"
KEEP_BACKUPS=10  # Number of latest backups to keep on Server B

# --- SAFETY SETTINGS ---
set -o pipefail 
set +e 

# --- LOCAL SETUP ---
mkdir -p /home/vagrant/backups /home/vagrant/logs
exec > >(tee -a "$LOG_FILE") 2>&1

# --- CLEANUP TRAP ---
cleanup() {
    [ -f "$BACKUP_PATH" ] && rm -f "$BACKUP_PATH"
}
trap cleanup EXIT

echo "-----------------------------------------------------"
echo "CRUCIAL BACKUP START: $(date)"
echo "-----------------------------------------------------"

# 1. Verification
if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "ERROR: Container $CONTAINER_NAME is not running. Aborting."
    exit 1
fi

# 2. SQL Export (Users & Orders)
echo "Step 1: Exporting database (Excluding $TABLE_NAME)..."
if docker exec -e PGPASSWORD="$DB_PASS" $CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME \
    -T "$TABLE_NAME" \
    --clean --if-exists \
    | gzip -9 > "$BACKUP_PATH"; then
    echo "Export successful. Size: $(du -h "$BACKUP_PATH" | cut -f1)"
else
    echo "CRITICAL ERROR: pg_dump failed."
    exit 1
fi

# 3. Transfer to Server B
echo "Step 2: Syncing to Remote Server ($REMOTE_HOST)..."
if rsync -avz --timeout=30 --rsync-path="mkdir -p $REMOTE_DIR && rsync" "$BACKUP_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"; then
    echo "SUCCESS: Sync complete."
else
    echo "CRITICAL ERROR: rsync failed."
    exit 1
fi

# 4. REMOTE RETENTION POLICY (Count-based)
echo "Step 3: Cleaning up remote backups (Keeping only latest $KEEP_BACKUPS)..."
# Lists files oldest-first, picks all EXCEPT the last 10, and removes them.
ssh "$REMOTE_USER@$REMOTE_HOST" "ls -1tr $REMOTE_DIR/crucial_metadata_*.sql.gz | head -n -$KEEP_BACKUPS | xargs -r rm --"

if [ $? -eq 0 ]; then
    echo "Remote retention applied: Latest $KEEP_BACKUPS files preserved."
else
    echo "WARNING: Remote cleanup encountered an error or no files to delete."
fi

echo "CRUCIAL BACKUP FINISHED: $(date)"
echo "-----------------------------------------------------"