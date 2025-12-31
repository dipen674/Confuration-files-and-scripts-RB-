#!/bin/bash
CONTAINER_NAME="postgres14"
DB_USER="myuser"
DB_NAME="mydatabase"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="/home/vagrant/backups/crucial_metadata_$TIMESTAMP.sql.gz"

# REMOTE INFO
REMOTE_USER="vagrant"
REMOTE_HOST="192.168.56.12"
REMOTE_DIR="/home/vagrant/backups_from_server_a/crucial"

# Use pg_dump for everything in users and orders
# -Z 9 uses maximum gzip compression level
echo "Starting Crucial Backup: $TIMESTAMP"
docker exec $CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME \
    -t 'users' -t 'orders' \
    | gzip -9 > "$BACKUP_PATH"

# Sync to Remote
rsync -avz "$BACKUP_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/" && rm "$BACKUP_PATH"

echo "Crucial Sync Complete."