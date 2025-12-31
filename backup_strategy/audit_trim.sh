#!/bin/bash

# --- CONFIGURATION ---
CONTAINER_NAME="postgres14"
DB_USER="myuser"
DB_PASS="mypassword"
DB_NAME="mydatabase"
TABLE_NAME="audit_logs"

# RETAIN POLICY: How many rows to keep in live DB and files on Server B
KEEP_ROWS=300000 
KEEP_BACKUPS=10

TEMP_TABLE="audit_logs_snapshot"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/home/vagrant/logs/audit_purge.log"
BACKUP_PATH="/home/vagrant/backups/audit_recent_$TIMESTAMP.sql.gz"

# REMOTE INFO
REMOTE_USER="vagrant"
REMOTE_HOST="192.168.56.12"
REMOTE_DIR="/home/vagrant/backups_from_server_a/audit_recent_snapshots"

# --- SAFETY SETTINGS ---
set -o pipefail
set +e 

# Ensure local directories exist
mkdir -p /home/vagrant/backups /home/vagrant/logs
exec > >(tee -a "$LOG_FILE") 2>&1

# --- CLEANUP TRAP ---
cleanup() {
    echo "-----------------------------------------------------"
    echo "Finalizing/Cleanup: $(date)"
    docker exec -e PGPASSWORD="$DB_PASS" $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "DROP TABLE IF EXISTS $TEMP_TABLE;" || true
    [ -f "$BACKUP_PATH" ] && rm -f "$BACKUP_PATH"
    echo "Cleanup complete."
}
trap cleanup EXIT

echo "-----------------------------------------------------"
echo "SQL BACKUP & PURGE START: $(date)"
echo "-----------------------------------------------------"

# 1. CALCULATE THRESHOLD
echo "Calculating Max ID from $TABLE_NAME..."
MAX_ID=$(docker exec -e PGPASSWORD="$DB_PASS" $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT max(id) FROM $TABLE_NAME;")
EXIT_CODE=$?
MAX_ID=$(echo "$MAX_ID" | xargs)

if [ $EXIT_CODE -ne 0 ] || ! [[ "$MAX_ID" =~ ^[0-9]+$ ]]; then
    echo "CRITICAL ERROR: Could not get a valid Max ID. Aborting."
    exit 1
fi

THRESHOLD_ID=$((MAX_ID - KEEP_ROWS))

if [ "$THRESHOLD_ID" -le 0 ]; then
    echo "Current total rows is less than $KEEP_ROWS. No action needed."
    exit 0
fi

set -e 
echo "Retention Goal: Keep latest $KEEP_ROWS rows (IDs >= $THRESHOLD_ID)."

# 2. CREATE SNAPSHOT (Postgres 14 Workaround)
echo "Staging rows into $TEMP_TABLE..."
docker exec -e PGPASSWORD="$DB_PASS" $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c \
    "DROP TABLE IF EXISTS $TEMP_TABLE; CREATE TABLE $TEMP_TABLE AS SELECT * FROM $TABLE_NAME WHERE id >= $THRESHOLD_ID;"

# 3. EXPORT SNAPSHOT
echo "Exporting snapshot to SQL format..."
docker exec -e PGPASSWORD="$DB_PASS" $CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME \
    -t "$TEMP_TABLE" \
    --clean --if-exists \
    | gzip -9 > "$BACKUP_PATH"

# 4. SYNC TO REMOTE SERVER
echo "Syncing backup to Remote Server ($REMOTE_HOST)..."
rsync -avz --timeout=30 --rsync-path="mkdir -p $REMOTE_DIR && rsync" "$BACKUP_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

# 5. PURGE ORIGINAL TABLE
echo "Transfer successful. Trimming $TABLE_NAME..."
docker exec -e PGPASSWORD="$DB_PASS" $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "DELETE FROM $TABLE_NAME WHERE id < $THRESHOLD_ID;"

# 6. RECLAIM SPACE (Standard Vacuum)
echo "Running standard VACUUM (safe for live traffic)..."
docker exec -e PGPASSWORD="$DB_PASS" $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "VACUUM $TABLE_NAME;"

# 7. REMOTE RETENTION POLICY (Count-based)
echo "Applying remote retention: Keeping only the latest $KEEP_BACKUPS files..."
# Sort oldest first, remove everything except the last $KEEP_BACKUPS
ssh "$REMOTE_USER@$REMOTE_HOST" "ls -1tr $REMOTE_DIR/audit_recent_*.sql.gz | head -n -$KEEP_BACKUPS | xargs -r rm --"

echo "PROCESS SUCCESSFUL: $(date)"
echo "-----------------------------------------------------"