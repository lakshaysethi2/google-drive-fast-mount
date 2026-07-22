#!/usr/bin/env bash
set -e

# ==============================================================================
# Automated Setup Script for High-Performance Google Drive Mount via Rclone
# ==============================================================================

MOUNT_DIR="${HOME}/mnt/google_drive"
REMOTE_NAME="gdrive"
SERVICE_NAME="rclone-gdrive"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
CACHE_DIR="${HOME}/.cache/rclone"
RCLONE_CONF_DIR="${HOME}/.config/rclone"
RCLONE_CONF="${RCLONE_CONF_DIR}/rclone.conf"

echo "=== Google Drive Fast Mount Installer ==="

# 1. Ensure rclone is installed
if ! command -v rclone &> /dev/null; then
    echo "[+] Installing rclone..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq rclone
    else
        curl -s https://rclone.org/install.sh | sudo bash
    fi
else
    echo "[✓] rclone is already installed ($(rclone version | head -n 1))"
fi

# 2. Ensure fuse / fusermount is available
if ! command -v fusermount &> /dev/null && ! command -v fusermount3 &> /dev/null; then
    echo "[+] Installing fuse..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get install -y -qq fuse3 || sudo apt-get install -y -qq fuse
    fi
fi

# Enable user_allow_other in /etc/fuse.conf if needed
if [ -f /etc/fuse.conf ]; then
    if ! grep -q "^user_allow_other" /etc/fuse.conf; then
        echo "[+] Enabling user_allow_other in /etc/fuse.conf..."
        echo "user_allow_other" | sudo tee -a /etc/fuse.conf > /dev/null
    fi
fi

# 3. Handle Rclone Configuration & Optional SCP Import
mkdir -p "${RCLONE_CONF_DIR}"

if [ -f "$RCLONE_CONF" ]; then
    echo "[✓] Existing rclone configuration found at ${RCLONE_CONF}."
    read -p "Do you want to re-import/overwrite rclone config via SCP from another server? (y/N): " USE_SCP
else
    read -p "No rclone config found. Do you want to SCP your existing rclone config from another server? (y/N): " USE_SCP
fi

if [[ "$USE_SCP" =~ ^[Yy]$ ]]; then
    read -p "Enter source SSH user and server (e.g. ubuntu@192.168.1.50 or my-server): " REMOTE_SERVER
    if [ -n "$REMOTE_SERVER" ]; then
        echo "[+] Fetching ${RCLONE_CONF} from ${REMOTE_SERVER}:~/.config/rclone/rclone.conf..."
        scp "${REMOTE_SERVER}:~/.config/rclone/rclone.conf" "${RCLONE_CONF}"
        echo "[✓] Successfully copied rclone.conf via SCP!"
    else
        echo "[!] No server specified. Skipping SCP."
    fi
fi

# If rclone.conf is still missing or remote doesn't exist, prompt for rclone config
if [ ! -f "$RCLONE_CONF" ] || ! grep -q "\[${REMOTE_NAME}\]" "$RCLONE_CONF"; then
    echo "[!] Remote '${REMOTE_NAME}' not found in ${RCLONE_CONF}."
    echo "[+] Running 'rclone config' to set up '${REMOTE_NAME}'..."
    echo "    Please create a remote named '${REMOTE_NAME}' during configuration."
    rclone config
fi

# 4. Create directories
echo "[+] Creating mount and cache directories..."
mkdir -p "${MOUNT_DIR}"
mkdir -p "${SYSTEMD_USER_DIR}"
mkdir -p "${CACHE_DIR}"

# 5. Create optimized systemd user service
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}.service"
echo "[+] Writing systemd user service to ${SERVICE_FILE}..."

cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Rclone Mount for Google Drive (${REMOTE_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/rclone mount ${REMOTE_NAME}: ${MOUNT_DIR} \\
    --config ${RCLONE_CONF} \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 10G \\
    --vfs-cache-max-age 24h \\
    --allow-other \\
    --poll-interval 1m \\
    --dir-cache-time 1000h \\
    --attr-timeout 1000h \\
    --vfs-read-chunk-size 32M \\
    --vfs-read-chunk-size-limit 1G \\
    --buffer-size 32M \\
    --log-file ${CACHE_DIR}/rclone.log \\
    --log-level INFO
ExecStop=/bin/fusermount -u -z ${MOUNT_DIR}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

# 6. Enable linger so mount persists after SSH logout
if command -v loginctl &> /dev/null; then
    echo "[+] Enabling user linger..."
    loginctl enable-linger "${USER}" || true
fi

# 7. Enable and start the systemd user service
echo "[+] Enabling and starting ${SERVICE_NAME}.service..."
systemctl --user daemon-reload
systemctl --user enable --now "${SERVICE_NAME}.service"

echo "=========================================================="
echo " [✓] Google Drive Mount Setup Complete!"
echo " Mount location: ${MOUNT_DIR}"
echo " Service status: systemctl --user status ${SERVICE_NAME}.service"
echo " Logs:           ${CACHE_DIR}/rclone.log"
echo "=========================================================="
