#!/bin/bash

# Configuration variables
EXTERNAL_DRIVE_PATH="/mnt/external"  # Change this to your external drive mount point
REMOTE_NAME="gdrive"                 # The name of your rclone remote
LOG_FILE="/var/log/rclone_backup.log"
CONFIG_DIR="/root/.config/rclone"    # Where rclone config is stored

# Google Drive Service Account variables
# Place your service account JSON file on the server
SERVICE_ACCOUNT_FILE="/path/to/your-service-account.json"  # Update this path
SHARED_FOLDER_ID="your-shared-folder-id"  # Update this with your shared folder ID

# Set drive UUID
DRIVE_UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # Replace with your drive's UUID

# Define multiple source directories and their respective remote subdirectories
declare -A SOURCE_DIRS
SOURCE_DIRS=(
  ["$EXTERNAL_DRIVE_PATH/photos"]="photos_backup"
  ["$EXTERNAL_DRIVE_PATH/videos"]="videos_backup"
  ["$EXTERNAL_DRIVE_PATH/documents"]="documents_backup"
)

send_email() {
  local subject="$1"
  local body="$2"
  local to_email="your-email@example.com"
  local from_email="your-sendgrid-verified-email@example.com"
  local api_key="your-sendgrid-api-key"

  curl -X POST \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    -d '{
      "personalizations": [{
        "to": [{"email": "'"$to_email"'"}]
      }],
      "from": {"email": "'"$from_email"'"},
      "subject": "'"$subject"'",
      "content": [{
        "type": "text/plain",
        "value": "'"$body"'"
      }]
    }' \
    https://api.sendgrid.com/v3/mail/send
}

# Mount using UUID
mount_drive() {
  if ! mountpoint -q "$EXTERNAL_DRIVE_PATH"; then
    echo "$(date): External drive not mounted. Attempting to mount..." >> "$LOG_FILE"
    
    # Mount by UUID instead of device name
    mount UUID="$DRIVE_UUID" "$EXTERNAL_DRIVE_PATH" 2>> "$LOG_FILE"
    
    if [ $? -ne 0 ]; then
      echo "$(date): Failed to mount external drive. Exiting." >> "$LOG_FILE"
      exit 1
    fi
    echo "$(date): External drive mounted successfully." >> "$LOG_FILE"
  else
    echo "$(date): External drive already mounted." >> "$LOG_FILE"
  fi
}

# Configure rclone automatically
configure_rclone() {
  echo "$(date): Setting up rclone configuration..." >> "$LOG_FILE"
  
  # Create config directory if it doesn't exist
  mkdir -p "$CONFIG_DIR"
  
  # Check if service account file exists
  if [ ! -f "$SERVICE_ACCOUNT_FILE" ]; then
    echo "$(date): Service account file not found at $SERVICE_ACCOUNT_FILE. Exiting." >> "$LOG_FILE"
    exit 1
  fi
  
  # Create rclone config file with Google Drive service account
  cat > "$CONFIG_DIR/rclone.conf" << EOL
[$REMOTE_NAME]
type = drive
scope = drive
service_account_file = $SERVICE_ACCOUNT_FILE
root_folder_id = $SHARED_FOLDER_ID
EOL

  echo "$(date): Rclone configured with Google Drive service account." >> "$LOG_FILE"
}


# Check Google Drive storage usage and compare with required space
check_drive_usage() {
  echo "$(date): Checking Google Drive storage usage..." >> "$LOG_FILE"
  
  STORAGE_INFO=$(rclone about "$REMOTE_NAME": --json 2>> "$LOG_FILE")
  
  if [ $? -ne 0 ]; then
    echo "$(date): Failed to retrieve storage usage." >> "$LOG_FILE"
    return 1
  fi

  # Extract total and used storage in bytes
  TOTAL_BYTES=$(echo "$STORAGE_INFO" | jq -r '.quota.total')
  USED_BYTES=$(echo "$STORAGE_INFO" | jq -r '.quota.used')

  if [[ "$TOTAL_BYTES" == "null" || "$USED_BYTES" == "null" ]]; then
    echo "$(date): Failed to parse storage information." >> "$LOG_FILE"
    return 1
  fi

  AVAILABLE_BYTES=$((TOTAL_BYTES - USED_BYTES))
  echo "$(date): Google Drive Available Space: $AVAILABLE_BYTES bytes" >> "$LOG_FILE"
  export AVAILABLE_BYTES
}

# Calculate the total size of files to be uploaded
calculate_upload_size() {
  local total_size=0
  for LOCAL_PATH in "${!SOURCE_DIRS[@]}"; do
    REMOTE_SUBDIR="${SOURCE_DIRS[$LOCAL_PATH]}"
    
    # Use rclone to simulate the copy and calculate the size of new files
    new_files_size=$(rclone copy --dry-run --stats-one-line --stats-unit bytes --stats 0 "$LOCAL_PATH" "$REMOTE_NAME:$REMOTE_SUBDIR" 2>/dev/null | grep -oP '\d+(?= Bytes)')
    
    if [ -n "$new_files_size" ]; then
      total_size=$((total_size + new_files_size))
    fi
  done
  echo "$(date): Total size of new files to be uploaded: $total_size bytes" >> "$LOG_FILE"
  export REQUIRED_BYTES=$total_size
}

# Run backup if there is enough space
perform_backup() {
  echo "$(date): Starting backup..." >> "$LOG_FILE"
  

  # Proceed with backup
  for LOCAL_PATH in "${!SOURCE_DIRS[@]}"; do
    REMOTE_SUBDIR="${SOURCE_DIRS[$LOCAL_PATH]}"
    echo "$(date): Backing up $LOCAL_PATH to $REMOTE_NAME:$REMOTE_SUBDIR" >> "$LOG_FILE"
    
    rclone copy "$LOCAL_PATH" "$REMOTE_NAME:$REMOTE_SUBDIR" \
      --progress \
      --log-file="$LOG_FILE" \
      --log-level=INFO \
      --transfers=4 \
      --checkers=8 \
      --tpslimit=10 \
      --stats=10s
  done

  echo "$(date): Backup completed." >> "$LOG_FILE"
}

# Run backup
perform_backup() {
  echo "$(date): Starting backup..." >> "$LOG_FILE"

  # Check storage usage
  check_drive_usage
  calculate_upload_size

  # Ensure storage info was retrieved
  if [[ -z "$AVAILABLE_BYTES" || -z "$REQUIRED_BYTES" ]]; then
    echo "$(date): Skipping backup due to missing storage data." >> "$LOG_FILE"
    return 1
  fi

  # Compare available space with required space
  if (( REQUIRED_BYTES > AVAILABLE_BYTES )); then
    echo "$(date): Not enough space on Google Drive! Required: $REQUIRED_BYTES bytes, Available: $AVAILABLE_BYTES bytes." >> "$LOG_FILE"
    return 1
  fi
  
  for LOCAL_PATH in "${!SOURCE_DIRS[@]}"; do
    REMOTE_SUBDIR="${SOURCE_DIRS[$LOCAL_PATH]}"
    echo "$(date): Backing up $LOCAL_PATH to $REMOTE_NAME:$REMOTE_SUBDIR" >> "$LOG_FILE"
    
    rclone copy "$LOCAL_PATH" "$REMOTE_NAME:$REMOTE_SUBDIR" \
      --progress \
      --log-file="$LOG_FILE" \
      --log-level=INFO \
      --transfers=4 \
      --checkers=8 \
      --tpslimit=10 \
      --stats=10s
  done
  
  # Check storage usage after backup
  check_drive_usage

  echo "$(date): Backup completed." >> "$LOG_FILE"
}

# Create systemd service for auto-start
create_systemd_service() {
  # Get the absolute path of this script
  SCRIPT_PATH=$(readlink -f "$0")
  
  cat > /etc/systemd/system/rclone-backup.service << EOL
[Unit]
Description=Rclone Backup Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

  # Create timer to run the service periodically (e.g., daily)
  cat > /etc/systemd/system/rclone-backup.timer << EOL
[Unit]
Description=Run Rclone Backup daily

[Timer]
OnBootSec=15min
OnUnitActiveSec=1d
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOL

  # Enable and start the timer
  systemctl daemon-reload
  systemctl enable rclone-backup.timer
  systemctl start rclone-backup.timer
  
  echo "$(date): Systemd service and timer created and enabled." >> "$LOG_FILE"
}

# Main execution
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Check if rclone is installed
if ! command -v rclone &> /dev/null; then
  echo "$(date): Rclone not found. Installing..." >> "$LOG_FILE"
  curl https://rclone.org/install.sh | bash
  if [ $? -ne 0 ]; then
    echo "$(date): Failed to install rclone. Exiting." >> "$LOG_FILE"
    exit 1
  fi
  echo "$(date): Rclone installed successfully." >> "$LOG_FILE"
fi

# Check if rclone is configured, if not configure it
if [ ! -f "$CONFIG_DIR/rclone.conf" ] || ! grep -q "\[$REMOTE_NAME\]" "$CONFIG_DIR/rclone.conf"; then
  configure_rclone
fi

# Run the backup process
mount_drive
perform_backup
create_systemd_service

echo "Setup complete. The backup will run automatically on system boot and daily thereafter."
