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
READ_ONLY=false

# --- VFS cache tuning (override via environment before running the script) ---
# VFS_CACHE_MAX_SIZE      Hard-ish cap on cached file data (soft: see README).
# VFS_CACHE_MAX_AGE       Evict cached files untouched for this long.
# VFS_CACHE_MIN_FREE      Start evicting when the cache disk drops below this.
# VFS_CACHE_POLL_INTERVAL How often the cleaner runs (rclone default is 1m).
VFS_CACHE_MAX_SIZE="${VFS_CACHE_MAX_SIZE:-5G}"
VFS_CACHE_MAX_AGE="${VFS_CACHE_MAX_AGE:-1h}"
VFS_CACHE_MIN_FREE="${VFS_CACHE_MIN_FREE:-5G}"
VFS_CACHE_POLL_INTERVAL="${VFS_CACHE_POLL_INTERVAL:-1m}"

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

do_cache() {
    echo ""
    echo "=== VFS Cache Usage ==="
    VFS_DIR="${CACHE_DIR}/vfs"
    VFS_META_DIR="${CACHE_DIR}/vfsMeta"

    if [ ! -d "$VFS_DIR" ]; then
        echo "[i] No VFS cache directory at ${VFS_DIR} (nothing cached yet)."
        return 0
    fi

    # Cache files are SPARSE. `du --apparent-size` shows the full logical file
    # size, but only the downloaded chunks occupy real blocks. Plain `du`
    # reports real disk usage -- that is the number that matters.
    REAL=$(du -sh "$VFS_DIR" 2>/dev/null | cut -f1)
    APPARENT=$(du -sh --apparent-size "$VFS_DIR" 2>/dev/null | cut -f1)
    META=$(du -sh "$VFS_META_DIR" 2>/dev/null | cut -f1)

    echo "  Real disk used by cached data : ${REAL:-0}   <-- what fills your disk"
    echo "  Apparent (sparse) size        : ${APPARENT:-0}   <-- misleading, ignore"
    echo "  Metadata (vfsMeta)            : ${META:-0}"
    echo ""
    echo "  Filesystem holding the cache:"
    df -h "${CACHE_DIR}" | sed 's/^/    /'
    echo ""
    echo "  Largest cached files (real usage):"
    find "$VFS_DIR" -type f -printf '%b %p\0' 2>/dev/null \
        | sort -z -rn \
        | head -z -n 10 \
        | while IFS=' ' read -r -d '' blocks path; do
              # %b is 512-byte blocks actually allocated -> real bytes
              printf '    %6s  %s\n' \
                  "$(numfmt --to=iec --suffix=B $((blocks * 512)) 2>/dev/null || echo $((blocks * 512)))" \
                  "${path#"$VFS_DIR"/}"
          done
    echo ""
    echo ""
    echo "  Rclone's own view of the cache (last cleaner run):"
    if [ -f "${CACHE_DIR}/rclone.log" ]; then
        grep "vfs cache: cleaned:" "${CACHE_DIR}/rclone.log" | tail -n 3 | sed 's/^/    /' \
            || echo "    (no cleaner lines yet)"
    else
        echo "    (no log file yet)"
    fi
}

do_clear_cache() {
    echo ""
    echo "=== Clear VFS Cache ==="
    echo "[!] The cache can hold files that have NOT finished uploading to Drive."
    echo "    Deleting it while those are pending means DATA LOSS."
    echo ""

    if systemctl --user is-active --quiet "${SERVICE_NAME}.service"; then
        echo "[i] Service is running. Asking rclone to flush pending uploads first..."
        echo "    (stopping the service triggers a clean unmount + writeback)"
        read -p "Stop the mount and clear the cache now? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            return 0
        fi
        systemctl --user stop "${SERVICE_NAME}.service" || true
        # Give writeback a moment to settle after unmount.
        sleep 2
    else
        read -p "Service is stopped. Clear the cache directory now? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            return 0
        fi
    fi

    if [ -d "${CACHE_DIR}/vfs" ]; then
        rm -rf "${CACHE_DIR}/vfs" "${CACHE_DIR}/vfsMeta"
        echo "[✓] Cleared ${CACHE_DIR}/vfs and ${CACHE_DIR}/vfsMeta"
    else
        echo "[i] Nothing to clear."
    fi

    read -p "Restart the mount service? (Y/n): " RESTART
    if [[ ! "$RESTART" =~ ^[Nn]$ ]]; then
        systemctl --user start "${SERVICE_NAME}.service"
        echo "[✓] Service restarted."
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

    if [ "$READ_ONLY" = false ]; then
        read -p "Mount as read-only? (y/N): " ASK_READONLY
        if [[ "$ASK_READONLY" =~ ^[Yy]$ ]]; then
            READ_ONLY=true
        fi
    fi

    MOUNT_FLAGS=""
    if [ "$READ_ONLY" = true ]; then
        MOUNT_FLAGS=" --read-only"
        echo "[i] Mounting in read-only mode."
    else
        echo "[i] Mounting in read-write mode."
    fi

    # Type=notify makes systemd wait for the mount to be ready and surfaces
    # live VFS cache stats in `systemctl --user status`. rclone gained systemd
    # notify support in 1.52; fall back to `simple` on anything older.
    SERVICE_TYPE="simple"
    RCLONE_VER=$(rclone version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if [ -n "$RCLONE_VER" ]; then
        RC_MAJOR=${RCLONE_VER%%.*}
        RC_MINOR=${RCLONE_VER##*.}
        if [ "$RC_MAJOR" -gt 1 ] 2>/dev/null || \
           { [ "$RC_MAJOR" -eq 1 ] && [ "$RC_MINOR" -ge 52 ]; } 2>/dev/null; then
            SERVICE_TYPE="notify"
        fi
    fi
    echo "[i] Using systemd Type=${SERVICE_TYPE} (rclone ${RCLONE_VER:-unknown})"

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Rclone Mount for Google Drive (${REMOTE_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=${SERVICE_TYPE}
ExecStart=/usr/bin/rclone mount ${REMOTE_NAME}: ${MOUNT_DIR} \\
    --config ${RCLONE_CONF} \\
    --cache-dir ${CACHE_DIR} \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size ${VFS_CACHE_MAX_SIZE} \\
    --vfs-cache-max-age ${VFS_CACHE_MAX_AGE} \\
    --vfs-cache-min-free-space ${VFS_CACHE_MIN_FREE} \\
    --vfs-cache-poll-interval ${VFS_CACHE_POLL_INTERVAL} \\
    --allow-other \\
    --poll-interval 1m \\
    --dir-cache-time 1000h \\
    --attr-timeout 1000h \\
    --vfs-read-chunk-size 32M \\
    --vfs-read-chunk-size-limit 1G \\
    --buffer-size 32M \\
    --log-file ${CACHE_DIR}/rclone.log \\
    --log-level INFO${MOUNT_FLAGS}
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
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --readonly) READ_ONLY=true; shift ;;
                *) shift ;;
            esac
        done
        do_setup
        ;;
    unmount|stop)
        do_unmount
        ;;
    status)
        do_status
        ;;
    cache)
        do_cache
        ;;
    clear-cache)
        do_clear_cache
        ;;
    *)
        echo "=========================================="
        echo "   Google Drive Mount Manager & Setup"
        echo "=========================================="
        echo "1) Setup / Start Google Drive Mount"
        echo "2) Unmount Google Drive"
        echo "3) Check Mount Status & Logs"
        echo "4) Show VFS cache usage (real vs sparse)"
        echo "5) Safely clear VFS cache"
        echo "6) Exit"
        echo "=========================================="
        read -p "Select an action [1-6]: " ACTION_CHOICE

        case "$ACTION_CHOICE" in
            1) do_setup ;;
            2) do_unmount ;;
            3) do_status ;;
            4) do_cache ;;
            5) do_clear_cache ;;
            6) echo "Exiting."; exit 0 ;;
            *) echo "Invalid option."; exit 1 ;;
        esac
        ;;
esac
