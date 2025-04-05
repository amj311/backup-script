#!/bin/bash

# SECRET VARAIBLES

# Load env vars - don't commit ssecrets to git!
parent_path=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )

cd "$parent_path"
ENV_FILE=.env

if [[ -f $ENV_FILE ]]; then
  . $ENV_FILE
fi

SERVICE_ACCOUNT_FILE=$SERVICE_ACCOUNT_FILE # e.g. "/path/to/your-service-account.json"
SHARED_FOLDER_ID=$SHARED_FOLDER_ID         # e.g. "your-shared-folder-id"
DRIVE_UUID=$DRIVE_UUID                     # e.g. "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ALERT_EMAIL=$ALERT_EMAIL
SENDGRID_SENDER_EMAIL=$SENDGRID_SENDER_EMAIL
SENDGRID_API_KEY=$SENDGRID_API_KEY


# Configuration variables
EXTERNAL_DRIVE_PATH="/Media"                   # Change this to your external drive mount point
REMOTE_NAME="gdrive"                           # The name of your rclone remote
LOG_FILE="/var/log/rclone_backup.log"          # The logs location
CONFIG_PATH="/root/.config/rclone/rclone.conf" # Where rclone config is stored

# Define multiple source directories and their respective remote subdirectories
declare -A SOURCE_DIRS
SOURCE_DIRS=(
  ["$EXTERNAL_DRIVE_PATH/Media/Photos"]="photos_backup"
  ["/home/arthur/backups"]="db_backups"
)

send_email() {
  local subject="$1"
  local message="$2"
  local to_email="$ALERT_EMAIL"
  local from_email="$SENDGRID_SENDER_EMAIL"
  local api_key="$SENDGRID_API_KEY"
  local login_reminder="P.S. Don't forget to log in to Sendgrid so your account doesn't deactivate!"
  local body="$message\n\n----------------\n$login_reminder"

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

# Log function to send output to both stdout and log file
log_message() {
  local message="$1"
  echo "$message" | tee -a "$LOG_FILE"
}

setup_rclone() {
  # Check if rclone is installed
  if ! command -v rclone &>/dev/null; then
    log_message "Rclone not found. Installing..."
    curl https://rclone.org/install.sh | bash
    if [ $? -ne 0 ]; then
      log_message "Failed to install rclone. Exiting."
	  send_email "Hearthstone Backup Failed" "Failed to install rclone."
      exit 1
    fi
    log_message "Rclone installed successfully."
  fi

  # Check if rclone is configured, if not configure it
  if [ ! -f "$CONFIG_PATH" ] || ! grep -q "\[$REMOTE_NAME\]" "$CONFIG_PATH"; then
    configure_rclone
  fi
}

# Mount using UUID
mount_drive() {
  if ! mountpoint -q "$EXTERNAL_DRIVE_PATH"; then
    log_message "External drive not mounted. Attempting to mount..."

    # Mount by UUID instead of device name
    mount UUID="$DRIVE_UUID" "$EXTERNAL_DRIVE_PATH" 2>>"$LOG_FILE"

    if [ $? -ne 0 ]; then
      log_message "Failed to mount external drive. Exiting."
	  send_email "Hearthstone Backup Failed" "Failed to mount external drive. Check logs for errors."
      exit 1
    fi
    log_message "External drive mounted successfully."
  else
    log_message "External drive already mounted."
  fi
}

# Configure rclone automatically
configure_rclone() {
  log_message "Setting up rclone configuration..."

  # Create config directory if it doesn't exist
  mkdir -p "$(dirname "$CONFIG_PATH")"
  touch "$CONFIG_PATH"

  # Check if service account file exists
  if [ ! -f "$SERVICE_ACCOUNT_FILE" ]; then
    log_message "Service account file not found at $SERVICE_ACCOUNT_FILE. Exiting."
	send_email "Hearthstone Backup Failed" "Service account file not found."
    exit 1
  fi

  # Create rclone config file with Google Drive service account
  cat >"$CONFIG_PATH" <<EOL
[$REMOTE_NAME]
type = drive
scope = drive
service_account_file = $SERVICE_ACCOUNT_FILE
root_folder_id = $SHARED_FOLDER_ID
EOL

  log_message "Rclone configured with Google Drive service account."
}

# Check Google Drive storage usage and compare with required space
check_drive_usage() {
  log_message "Checking Google Drive storage usage..."

  STORAGE_INFO=$(rclone about "$REMOTE_NAME": --json 2>>"$LOG_FILE")

  if [ $? -ne 0 ]; then
    log_message "Failed to retrieve storage usage."
	send_email "Hearthstone Backup Failed" "Failed to retrieve storage usage."
    return 1
  fi

  # Extract total and used storage in bytes
  TOTAL_BYTES=$(echo "$STORAGE_INFO" | jq -r '.total')
  USED_BYTES=$(echo "$STORAGE_INFO" | jq -r '.used')

  if [[ "$TOTAL_BYTES" == "null" || "$USED_BYTES" == "null" ]]; then
    log_message "Failed to parse storage information."
	send_email "Hearthstone Backup Failed" "Failed to parse storage information."
    return 1
  fi

  AVAILABLE_BYTES=$((TOTAL_BYTES - USED_BYTES))
  AVAILABLE_GIGS=$((AVAILABLE_BYTES / 1024 / 1024 / 1024))
  PERCENT_USED=$((USED_BYTES * 100 / TOTAL_BYTES))
  log_message "Google Drive Available Space: $AVAILABLE_GIGS GB (Used: $PERCENT_USED%)"
  export AVAILABLE_BYTES
}

convert_to_bytes() {
  local input="$1"
  local value=$(echo "$input" | sed -E 's/([0-9\.]+).*/\1/')
  local unit=$(echo "$input" | sed -E 's/[0-9\.]+//' | tr -d ' ')
  
  case "${unit,,}" in
    "b"|"bytes"|"")
      multiplier=1
      ;;
    "kib"|"ki")
      multiplier=1024
      ;;
    "mib"|"mi")
      multiplier=$((1024*1024))
      ;;
    "gib"|"gi")
      multiplier=$((1024*1024*1024))
      ;;
    "tib"|"ti")
      multiplier=$((1024*1024*1024*1024))
      ;;
    "pib"|"pi")
      multiplier=$((1024*1024*1024*1024*1024))
      ;;
    *)
      echo "Unknown unit: $unit" >&2
      return 1
      ;;
  esac
  
  # Use bc for floating point calculation
  echo "$value * $multiplier" | bc
}

# Calculate the total size of files to be uploaded
calculate_upload_size() {
  local total_size=0
  for LOCAL_PATH in "${!SOURCE_DIRS[@]}"; do
    REMOTE_SUBDIR="${SOURCE_DIRS[$LOCAL_PATH]}"

    output=$(rclone copy --dry-run --stats-one-line --stats-unit bytes --stats 0 "$LOCAL_PATH" "$REMOTE_NAME:$REMOTE_SUBDIR" 2>&1)

    # Loop through each line of the output
    while IFS= read -r line; do
      # Extract the number using grep and regex (adjust regex as needed)
      size=$(echo "$line" | grep -oP '(?<=\(size )\d+(\.\d+)?[KMGTP]i?')
      #   If a number was found, add it to the total sum
      if [[ -n "$size" ]]; then
        size_in_bytes=$(convert_to_bytes "$size")
        size_in_bytes=$(echo "$total_size + $size_in_bytes" | bc)
        total_size=$size_in_bytes
      fi
    done <<<"$output"
  done

# round to nearest whole number
  total_size=$(echo "($total_size + 0.5) / 1" | bc)
  total_megabytes=$((total_size / 1024 / 1024))
  log_message "Total size of new files to be uploaded: $total_megabytes MB"
  export REQUIRED_BYTES=$total_size
}

# Run backup
perform_backup() {
  log_message "Starting backup..."

  # Check storage usage
  check_drive_usage
  calculate_upload_size

  # Ensure storage info was retrieved
  if [[ -z "$AVAILABLE_BYTES" || -z "$REQUIRED_BYTES" ]]; then
    log_message "Skipping backup due to missing storage data."
	send_email "Hearthstone Backup Failed" "Skipping backup due to missing storage data."
    return 1
  fi

  # Compare available space with required space
  if ((REQUIRED_BYTES > AVAILABLE_BYTES)); then
    log_message "Not enough space on Google Drive! Required: $REQUIRED_BYTES bytes, Available: $AVAILABLE_BYTES bytes."
	send_email "Hearthstone Backup Failed" "Not enough space on Google Drive! Required: $REQUIRED_BYTES bytes, Available: $AVAILABLE_BYTES bytes."
    return 1
  fi

    for LOCAL_PATH in "${!SOURCE_DIRS[@]}"; do
      REMOTE_SUBDIR="${SOURCE_DIRS[$LOCAL_PATH]}"
      log_message "Backing up $LOCAL_PATH to $REMOTE_NAME:$REMOTE_SUBDIR"

      rclone copy "$LOCAL_PATH" "$REMOTE_NAME:$REMOTE_SUBDIR" \
        --progress \
        --log-file="$LOG_FILE" \
        --log-level=INFO \
        --transfers=4 \
        --checkers=8 \
        --tpslimit=10 \
        --stats=10s
    done

	log_message "Backup complete: $(date)."


	MOUNTED_DRIVE_INFO=$(df -h "$EXTERNAL_DRIVE_PATH" | tail -1)
	log_message "Mounted drive space: $MOUNTED_DRIVE_INFO"

  # Send summary on first of month
 if [ "$(date +%d)" == "05" ]; then
	log_message "Sending summary email..."
	# Get available space on mounted drive
	MOUNTED_DRIVE_SECTION="External Drive\n--------------\n$MOUNTED_DRIVE_INFO"
	GOOGLE_SECTION="Google Drive\n------------\nUsed: $PERCENT_USED%, Available: $AVAILABLE_GIGS GB."
	send_email "Hearthstone Backup Summary" "Backup completed successfully.\n\n$GOOGLE_SECTION\n\n$MOUNTED_DRIVE_SECTION"
	log_message "Summary email sent."
 fi
}

# Create systemd service for auto-start
create_systemd_service() {
  # Get the absolute path of this script
  SCRIPT_PATH=$(readlink -f "$0")

  cat >/etc/systemd/system/rclone-backup.service <<EOL
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
  cat >/etc/systemd/system/rclone-backup.timer <<EOL
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

  log_message "Systemd service and timer created and enabled."
}

# Main execution
log_message ""
log_message "-------------------------"
log_message "Beginning backup script... $(date)"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Do preparations
setup_rclone
mount_drive

# Run the backup process
perform_backup
create_systemd_service
