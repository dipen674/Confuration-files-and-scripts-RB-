#!/bin/bash

# --- CONFIGURATION ---
CONTAINER_NAME="postgres14"
DB_USER="myuser"
DB_NAME="mydatabase"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/home/vagrant/logs/audit_purge.log"
BACKUP_PATH="/home/vagrant/backups/latest_100k_snapshot_$TIMESTAMP.sql.gz"

# REMOTE INFO (Only for the 100k New Logs)
REMOTE_USER="vagrant"
REMOTE_HOST="192.168.56.12"
REMOTE_DIR="/home/vagrant/backups_from_server_a/audit_recent_snapshots"

# --- LOCAL SETUP ---
mkdir -p /home/vagrant/backups || true
mkdir -p /home/vagrant/logs || true
# Captures all output and errors to the log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "-----------------------------------------------------"
echo "PURGE & RECENT SNAPSHOT START: $(date)"
echo "-----------------------------------------------------"

# 1. Calculate the Threshold (Keep latest 100,000)
MAX_ID=$(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT max(id) FROM audit_logs;")
MAX_ID=$(echo $MAX_ID | xargs)
THRESHOLD_ID=$((MAX_ID - 100000))

if [ $THRESHOLD_ID -gt 0 ]; then
    echo "Current Max ID: $MAX_ID. Threshold: $THRESHOLD_ID"

    # 2. STEP 1: Backup ONLY the LATEST 100,000 logs
    echo "Backing up latest 100,000 logs (ID >= $THRESHOLD_ID)..."
    docker exec $CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME \
        -t 'audit_logs' \
        --where="id >= $THRESHOLD_ID" \
        | gzip -9 > "$BACKUP_PATH"

    # 3. STEP 2: Sync to Server B (Includes automatic remote directory creation)
    echo "Syncing snapshot to Remote Server ($REMOTE_HOST)..."
    rsync -avz --rsync-path="mkdir -p $REMOTE_DIR && rsync" "$BACKUP_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
    
    if [ $? -eq 0 ]; then
        echo "Snapshot safe on Server B."
        
        # 4. STEP 3: DESTROY THE OLD DATA
        echo "Permanently deleting all logs older than ID $THRESHOLD_ID..."
        docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "DELETE FROM audit_logs WHERE id < $THRESHOLD_ID; VACUUM audit_logs;"
        
        echo "Cleanup complete. Only the latest 100,000 rows remain."
        rm "$BACKUP_PATH"
    else
        echo "CRITICAL ERROR: Snapshot sync failed. Skipping deletion for safety."
    fi
else
    echo "Table has fewer than 100,000 rows. No action needed."
fi

echo "PROCESS FINISHED: $(date)"
echo "-----------------------------------------------------"