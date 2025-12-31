#!/bin/bash

CONTAINER_NAME="postgres14"
DB_USER="myuser"
DB_NAME="mydatabase"
BACKUP_DIR="/home/vagrant/backups"
ARCHIVE_DIR="/home/vagrant/archives"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOCKFILE="/tmp/db_backup_safe.lock"

# Remote Server B Details
REMOTE_USER="vagrant"
REMOTE_HOST="192.168.56.12"
REMOTE_DIR="/home/vagrant/backups_from_server_a"

if [ -e "$LOCKFILE" ]; then
    echo "ERROR: Backup already in progress. Exiting."
    exit 1
fi
touch "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# Create local directories if they don't exist
mkdir -p "$BACKUP_DIR" "$ARCHIVE_DIR"

echo "--- STARTING BACKUP PROCESS: $TIMESTAMP ---"

echo "Step 1: Backing up table structures and audit logs..."
docker exec $CONTAINER_NAME pg_dump -U $DB_USER \
    -t 'users' -t 'audit_logs' $DB_NAME \
    | gzip -1 > "$BACKUP_DIR/metadata_$TIMESTAMP.sql.gz"


# Get the max ID and subtract 10,000 to find our archive point
LATEST_ID=$(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT max(id) FROM orders;")
# Remove spaces from the result
LATEST_ID=$(echo $LATEST_ID | xargs)

if [[ -n "$LATEST_ID" && "$LATEST_ID" =~ ^[0-9]+$ ]]; then
    THRESHOLD_ID=$((LATEST_ID - 10000))
    
    if [ $THRESHOLD_ID -gt 0 ]; then
        echo "Step 2: Archiving orders (ID < $THRESHOLD_ID) to SQL..."
        
        # We use pg_dump with a WHERE clause to export specific rows as SQL
        docker exec $CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME \
            -t 'orders' --data-only --column-inserts \
            --where="id < $THRESHOLD_ID" \
            | gzip -1 > "$ARCHIVE_DIR/orders_archive_$TIMESTAMP.sql.gz"
            
        echo "Archive file created successfully."
    else
        echo "Step 2: Not enough data to archive yet (Threshold not met)."
    fi
else
    echo "Step 2: Could not determine LATEST_ID. Skipping orders archive."
fi

echo "Step 3: Transferring files to Server B ($REMOTE_HOST)..."

ssh -o ConnectTimeout=5 $REMOTE_USER@$REMOTE_HOST "mkdir -p $REMOTE_DIR"

if [ $? -eq 0 ]; then
    rsync -avz "$BACKUP_DIR/" "$ARCHIVE_DIR/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

    if [ $? -eq 0 ]; then
        echo "SUCCESS: Server B updated. Cleaning up local files."
        rm -f "$BACKUP_DIR"/* "$ARCHIVE_DIR"/*
    else
        echo "FAILURE: rsync failed. Keeping local files for safety."
    fi
else
    echo "FAILURE: Could not reach Server B. Keeping local files."
fi

echo "--- PROCESS COMPLETE ---"