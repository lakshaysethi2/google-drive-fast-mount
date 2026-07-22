#!/usr/bin/env bash
set -e

# ==============================================================================
# Interactive Manager & Installer for Google Drive Rclone Mount
# ==============================================================================

MOUNT_DIR="${HOME}/mnt/google_drive"
REMOTE_NAME="gdrive"
SERVICE_NAME="rclone-gdrive"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
CACHE_DIR="${HOME}/.cache/rclone"
RCLONE_CONF_DIR="${HOME}/.config/rclone"
RCLONE_CONF="${RCLONE_CONF_DIR}/rclone.conf"

do_unmount() {
    echo ""
    echo "=== Unmount Options ==="
    echo "1) Stop mount service temporarily (systemctl --user stop)"
    echo "2) Stop AND disable auto-start on boot (systemctl --user disable --now)"
    echo "3) Force / Lazy unmount immediately (fusermount -u -z)"
    echo "4) Cancel"
    read -p "Select an option [1-4]: " UNMOUNT_CHOICE

    case "$UNMOUNT_CHOICE" in
        1)
            echo "[+] Stopping ${SERVICE_NAME}.service..."
            systemctl --user stop "${SERVICE_NAME}.service" || true
            echo "[✓] Mount service stopped successfully."
            ;;
        2)
            echo "[+] Stopping and disabling ${SERVICE_NAME}.service..."
            systemctl --user disable --now "${SERVICE_NAME}.service" || true
            echo "[✓] Mount service stopped and disabled."
            ;;
        3)
            echo "[+] Force unmounting ${MOUNT_DIR}..."
            systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null || true
            fusermount -u -z "${MOUNT_DIR}" 2>/dev/null || true
            echo "[✓] Force unmount executed."
            ;;
        4)
            echo "Operation cancelled."
            exit 0
            ;;
        *)
            echo "Invalid selection."
            exit 1
            ;;
    esac
}

do_status() {
    echo ""
    echo "=== Mount Status ==="
    systemctl --user status "${SERVICE_NAME}.service" --no-pager || true
    echo ""
    if mountpoint -q "${MOUNT_DIR}"; then
        echo "[✓] Mount point '${MOUNT_DIR}' is ACTIVE."
    else
        echo "[!] Mount point '${MOUNT_DIR}' is NOT mounted."
    fi
}

do_setup() {
    echo "=== Google Drive Fast Mount Setup ==="

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
}

# --- CLI Arguments or Main Menu ---
case "$1" in
    mount|setup)
        do_setup
        ;;
    unmount|stop)
        do_unmount
        ;;
    status)
        do_status
        ;;
    *)
        echo "=========================================="
        echo "   Google Drive Mount Manager & Setup"
        echo "=========================================="
        echo "1) Setup / Start Google Drive Mount"
        echo "2) Unmount Google Drive"
        echo "3) Check Mount Status & Logs"
        echo "4) Exit"
        echo "=========================================="
        read -p "Select an action [1-4]: " ACTION_CHOICE

        case "$ACTION_CHOICE" in
            1) do_setup ;;
            2) do_unmount ;;
            3) do_status ;;
            4) echo "Exiting."; exit 0 ;;
            *) echo "Invalid option."; exit 1 ;;
        esac
        ;;
esac
