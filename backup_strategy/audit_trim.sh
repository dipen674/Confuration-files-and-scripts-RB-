#!/bin/bash
CONTAINER_NAME="postgres14"
DB_USER="myuser"
DB_NAME="mydatabase"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE_PATH="/home/vagrant/archives/audit_history_$TIMESTAMP.sql.gz"

REMOTE_USER="vagrant"
REMOTE_HOST="192.168.56.12"
REMOTE_DIR="/home/vagrant/backups_from_server_a/audit_archives"

echo "Starting Audit Trim: $TIMESTAMP"

# 1. Find the ID threshold (Keep latest 50,000 logs)
MAX_ID=$(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT max(id) FROM audit_logs;")
MAX_ID=$(echo $MAX_ID | xargs)
THRESHOLD_ID=$((MAX_ID - 50000))

if [ $THRESHOLD_ID -gt 0 ]; then
    echo "Archiving logs older than ID: $THRESHOLD_ID"

    # 2. Export old logs to SQL
    docker exec $CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME \
        -t 'audit_logs' --data-only --column-inserts \
        --where="id < $THRESHOLD_ID" \
        | gzip -9 > "$ARCHIVE_PATH"

    # 3. Sync to Remote
    rsync -avz "$ARCHIVE_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
    
    if [ $? -eq 0 ]; then
        echo "Archive safe on Server B. Deleting old logs from Server A database..."
        # 4. TRIMMING: Actually remove the rows from the live database
        docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "DELETE FROM audit_logs WHERE id < $THRESHOLD_ID;"
        rm "$ARCHIVE_PATH"
    fi
else
    echo "Audit table small. No trimming needed."
fi