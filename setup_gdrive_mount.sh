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
FORCE_CLEAR=false

# --- VFS cache tuning (override via environment before running the script) ---
# VFS_CACHE_MAX_SIZE      Hard-ish cap on cached file data (soft: see README).
# VFS_CACHE_MAX_AGE       Evict cached files untouched for this long.
# VFS_CACHE_MIN_FREE      Start evicting when the cache disk drops below this.
# VFS_CACHE_POLL_INTERVAL How often the cleaner runs (rclone default is 1m).
VFS_CACHE_MAX_SIZE="${VFS_CACHE_MAX_SIZE:-5G}"
VFS_CACHE_MAX_AGE="${VFS_CACHE_MAX_AGE:-1h}"
VFS_CACHE_MIN_FREE="${VFS_CACHE_MIN_FREE:-5G}"
VFS_CACHE_POLL_INTERVAL="${VFS_CACHE_POLL_INTERVAL:-1m}"

# --- Upload throughput tuning ---
# DRIVE_CHUNK_SIZE  Upload chunk size. rclone's default is 8M, which stalls on
#                   high-latency links: each chunk is a separate HTTP request
#                   and the connection idles during the round trip. Larger
#                   chunks keep the pipe full. Costs RAM: chunk x transfers.
# TRANSFERS         Parallel uploads. Drive throttles per-stream, so a few
#                   concurrent transfers beat one fast one.
# DRIVE_PACER_MIN_SLEEP  Delay between API calls (rclone default 100ms).
DRIVE_CHUNK_SIZE="${DRIVE_CHUNK_SIZE:-64M}"
TRANSFERS="${TRANSFERS:-4}"
DRIVE_PACER_MIN_SLEEP="${DRIVE_PACER_MIN_SLEEP:-10ms}"
DRIVE_PACER_BURST="${DRIVE_PACER_BURST:-200}"

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

do_speedcheck() {
    echo ""
    echo "=========================================================="
    echo "  Upload Throughput Check"
    echo "=========================================================="

    # ---------------------------------------------------------------
    # 1. Own client_id. Without one you share rclone's global OAuth
    #    client with every other rclone user, and Google's per-client
    #    rate limiting is what throttles you.
    # ---------------------------------------------------------------
    echo ""
    echo "--- 1. OAuth client_id ---"
    if [ -f "$RCLONE_CONF" ] && \
       awk -v r="[${REMOTE_NAME}]" '$0==r{f=1;next} /^\[/{f=0} f' "$RCLONE_CONF" | grep -q "^client_id *= *[^ ]"; then
        echo "  [OK] Using your own client_id."
    else
        echo "  [!!] NO client_id - THIS IS USUALLY THE #1 CAUSE OF SLOW UPLOADS."
        echo ""
        echo "       You are sharing rclone's global OAuth client with every"
        echo "       other rclone user on the planet. Google rate-limits per"
        echo "       client, so you inherit everyone else's traffic."
        echo ""
        echo "       Creating your own is free and takes ~10 minutes:"
        echo "         https://rclone.org/drive/#making-your-own-client-id"
        echo "       Then: rclone config  ->  edit '${REMOTE_NAME}'  ->  set client_id/secret"
        echo "       Your existing files and token are unaffected."
    fi

    # ---------------------------------------------------------------
    # 2. Effective upload flags on the running process.
    # ---------------------------------------------------------------
    echo ""
    echo "--- 2. Upload flags in effect ---"
    RCLONE_PID=$(pgrep -u "$(id -u)" -f "rclone mount" | head -n1)
    if [ -z "$RCLONE_PID" ]; then
        echo "  (no running mount)"
    else
        ARGS=$(tr '\0' ' ' < "/proc/${RCLONE_PID}/cmdline" 2>/dev/null)
        for F in --drive-chunk-size --drive-upload-cutoff --transfers --drive-pacer-min-sleep --bwlimit; do
            V=$(echo "$ARGS" | grep -oE -- "${F}[= ][^ ]+" | head -n1 | awk '{print $2}')
            if [ -n "$V" ]; then
                printf '    %-26s %s\n' "$F" "$V"
            else
                case "$F" in
                    --drive-chunk-size)     printf '    %-26s %s\n' "$F" "8M (default)  <-- too small, see below" ;;
                    --drive-upload-cutoff)  printf '    %-26s %s\n' "$F" "8M (default)" ;;
                    --transfers)            printf '    %-26s %s\n' "$F" "4 (default)" ;;
                    --drive-pacer-min-sleep) printf '    %-26s %s\n' "$F" "100ms (default)" ;;
                    --bwlimit)              printf '    %-26s %s\n' "$F" "unset (no cap - good)" ;;
                esac
            fi
        done

        if echo "$ARGS" | grep -q -- "--bwlimit"; then
            echo ""
            echo "  [!!] --bwlimit is set. This caps your speed directly."
        fi
    fi

    # ---------------------------------------------------------------
    # 3. Measured throughput from the log.
    # ---------------------------------------------------------------
    echo ""
    echo "--- 3. Recent measured upload speed ---"
    LOG="${CACHE_DIR}/rclone.log"
    if [ -f "$LOG" ]; then
        SPEEDS=$(grep -oE "[0-9.]+ [KMG]i?Bytes/s" "$LOG" 2>/dev/null | tail -n 5)
        if [ -n "$SPEEDS" ]; then
            echo "$SPEEDS" | sed 's/^/    /'
        else
            echo "    (no transfer stats in log; add --stats 30s to see them)"
        fi
        RL=$(grep -ciE "rateLimitExceeded|userRateLimitExceeded|429" "$LOG" 2>/dev/null || echo 0)
        echo ""
        echo "    Rate-limit responses in log: ${RL}"
        if [ "$RL" -gt 0 ] 2>/dev/null; then
            echo "    [!] Google is actively throttling you. An own client_id"
            echo "        (section 1) is the fix; raising --transfers will not help."
        fi
    else
        echo "    (no log file)"
    fi

    # ---------------------------------------------------------------
    # 4. Guidance
    # ---------------------------------------------------------------
    echo ""
    echo "--- 4. What actually moves the needle ---"
    echo "  Google Drive throttles each upload STREAM, so a single transfer"
    echo "  rarely saturates a fast line no matter how it is tuned. Throughput"
    echo "  comes from parallelism plus large chunks:"
    echo ""
    echo "    --drive-chunk-size 64M   bigger HTTP requests, fewer round trips"
    echo "    --transfers 4            parallel streams (total = chunk x transfers RAM)"
    echo "    --drive-pacer-min-sleep 10ms   less idle time between API calls"
    echo ""
    echo "  Apply by re-running setup (values are overridable):"
    echo "      DRIVE_CHUNK_SIZE=64M TRANSFERS=4 ./setup_gdrive_mount.sh setup"
    echo ""
    echo "  RAM cost: --drive-chunk-size x --transfers is buffered in memory."
    echo "  64M x 4 = 256MB. Do not set 1G x 8 on a small machine."
    echo ""
    echo "  Note: Drive's ~750GB/day upload cap is separate. Hitting it causes"
    echo "  errors, not slowness - check with: ./setup_gdrive_mount.sh uploads"
    echo ""
}

do_uploads() {
    LOG="${CACHE_DIR}/rclone.log"

    echo ""
    echo "=========================================================="
    echo "  Pending Upload Analysis"
    echo "=========================================================="

    # Live queue via the rc interface, if the mount was started with --rc.
    echo ""
    echo "--- Live upload queue ---"
    if command -v rclone &> /dev/null && rclone rc vfs/queue --json 2>/dev/null | head -c 1 | grep -q .; then
        rclone rc vfs/queue 2>/dev/null | head -n 40
    else
        echo "  (rclone rc unavailable - mount not started with --rc. Using log instead.)"
    fi

    if [ ! -f "$LOG" ]; then
        echo ""
        echo "[!] No log file at ${LOG}"
        return 0
    fi

    # ---------------------------------------------------------------
    # Distinct upload errors, most recent first. This is the payload:
    # the actual reason Drive is rejecting the writes.
    # ---------------------------------------------------------------
    echo ""
    echo "--- Recent upload failures ---"
    FAILS=$(grep -iE "vfs cache: failed to (upload|transfer)|failed to copy|Post \"https" "$LOG" 2>/dev/null | tail -n 200)
    if [ -z "$FAILS" ]; then
        echo "  No upload failures logged."
        echo "  If files are still pending, uploads may simply be slow or queued"
        echo "  behind --transfers. Watch progress with:"
        echo "      tail -f ${LOG} | grep -i 'vfs cache'"
    else
        echo "$FAILS" | tail -n 8 | sed 's/^/    /'
        echo ""
        echo "  Most common error signatures found:"
        echo "$FAILS" \
            | grep -oiE "storageQuotaExceeded|quotaExceeded|userRateLimitExceeded|rateLimitExceeded|teamDriveFileLimitExceeded|invalid_grant|token expired|401|403|404|500|502|503|couldn't fetch token|no space left|permission denied|context deadline exceeded|connection reset" \
            | sort | uniq -c | sort -rn | head -n 8 | sed 's/^/    /'
    fi

    # ---------------------------------------------------------------
    # Map the signature to a cause + fix. Infinite retry means a
    # permanent error will never clear on its own.
    # ---------------------------------------------------------------
    echo ""
    echo "--- Diagnosis ---"
    MATCHED=0

    if echo "$FAILS" | grep -qi "storageQuotaExceeded"; then
        MATCHED=1
        echo "  [X] GOOGLE DRIVE IS FULL (storageQuotaExceeded)."
        echo "      This is permanent - rclone retries forever but can never"
        echo "      succeed. Free space in Drive (or buy more), then restart"
        echo "      the mount. Uploads resume automatically."
        echo "      Check usage:  rclone about gdrive:"
    fi

    if echo "$FAILS" | grep -qiE "userRateLimitExceeded|rateLimitExceeded"; then
        MATCHED=1
        echo "  [!] RATE / QUOTA LIMIT HIT."
        echo "      Google Drive caps uploads at ~750GB/day per account. Once"
        echo "      tripped it clears after ~24h. Reduce concurrency so the"
        echo "      backlog drains without re-tripping it:"
        echo "          --transfers 2 --tpslimit 8 --drive-pacer-min-sleep 100ms"
    fi

    if echo "$FAILS" | grep -qiE "invalid_grant|token expired|couldn't fetch token|401"; then
        MATCHED=1
        echo "  [X] OAUTH TOKEN EXPIRED OR REVOKED."
        echo "      Every upload will keep failing until you re-authorise:"
        echo "          rclone config reconnect ${REMOTE_NAME}:"
        echo "      Then restart the mount. Do NOT delete the cache first."
    fi

    # Only report a bare 403 if a more specific 403 cause (quota/rate) didn't
    # already match, otherwise it is just noise.
    if echo "$FAILS" | grep -qiE "403|permission denied" \
       && ! echo "$FAILS" | grep -qiE "storageQuotaExceeded|userRateLimitExceeded|rateLimitExceeded"; then
        MATCHED=1
        echo "  [!] PERMISSION DENIED (403)."
        echo "      The account may lack write access to the target folder,"
        echo "      or the file is owned by someone else. Verify with:"
        echo "          rclone lsd ${REMOTE_NAME}:"
    fi

    if echo "$FAILS" | grep -qi "no space left"; then
        MATCHED=1
        echo "  [X] LOCAL DISK FULL."
        echo "      rclone cannot stage uploads with a full disk, so the queue"
        echo "      is deadlocked. Free local space first - see 'Rescue' below."
    fi

    if [ "$MATCHED" -eq 0 ] && [ -n "$FAILS" ]; then
        echo "  Errors present but unrecognised. Full context:"
        echo "      grep -i 'vfs cache' ${LOG} | tail -50"
    fi

    # ---------------------------------------------------------------
    # Always tell the user how to protect the data.
    # ---------------------------------------------------------------
    echo ""
    echo "--- Protecting the pending data ---"
    echo "  These 35GB-style backlogs exist ONLY in the cache. Before any"
    echo "  troubleshooting that risks the cache, copy them somewhere safe:"
    echo "      ./setup_gdrive_mount.sh rescue-pending /path/to/backup"
    echo ""
    echo "  rclone retries failed uploads forever (5 min max backoff), so a"
    echo "  permanent error like a full Drive will never resolve by waiting."
    echo ""
}

do_rescue_pending() {
    DEST="$1"
    VFS_DIR="${CACHE_DIR}/vfs"
    VFS_META_DIR="${CACHE_DIR}/vfsMeta"

    echo ""
    echo "=== Rescue Pending Uploads ==="

    if [ -z "$DEST" ]; then
        echo "Copies every not-yet-uploaded file out of the cache to a normal"
        echo "directory, so the data survives regardless of what happens next."
        echo ""
        echo "Usage: ./setup_gdrive_mount.sh rescue-pending /path/to/backup"
        return 1
    fi

    if [ ! -d "$VFS_META_DIR" ]; then
        echo "[i] No cache metadata directory; nothing pending."
        return 0
    fi

    mkdir -p "$DEST" || { echo "[!] Cannot create ${DEST}"; return 1; }

    COUNT=0
    BYTES=0
    while IFS= read -r META; do
        grep -q '"Dirty": true' "$META" 2>/dev/null || continue
        REL="${META#"$VFS_META_DIR"/}"
        SRC="${VFS_DIR}/${REL}"
        [ -f "$SRC" ] || continue
        mkdir -p "${DEST}/$(dirname "$REL")"
        # --sparse keeps holes; dirty files are normally fully written anyway.
        if cp --sparse=always --preserve=timestamps "$SRC" "${DEST}/${REL}" 2>/dev/null; then
            B=$(( $(stat -c %b "$SRC" 2>/dev/null || echo 0) * 512 ))
            BYTES=$((BYTES + B))
            COUNT=$((COUNT + 1))
            printf '    %8s  %s\n' \
                "$(numfmt --to=iec --suffix=B "$B" 2>/dev/null || echo "$B")" "$REL"
        else
            echo "    [!] FAILED to copy ${REL}"
        fi
    done < <(find "$VFS_META_DIR" -type f 2>/dev/null)

    echo ""
    if [ "$COUNT" -eq 0 ]; then
        echo "[i] No pending files found - everything has uploaded."
    else
        echo "[✓] Rescued ${COUNT} file(s), $(numfmt --to=iec --suffix=B "$BYTES" 2>/dev/null || echo "$BYTES") to ${DEST}"
        echo ""
        echo "    Verify the copies look right, then you can re-upload later with:"
        echo "        rclone copy ${DEST} ${REMOTE_NAME}:/ --progress"
        echo ""
        echo "    Keep this backup until the files are confirmed on Drive."
    fi
}

do_diagnose() {
    VFS_DIR="${CACHE_DIR}/vfs"
    VFS_META_DIR="${CACHE_DIR}/vfsMeta"

    echo ""
    echo "=========================================================="
    echo "  VFS Cache Diagnosis"
    echo "=========================================================="

    if [ ! -d "$VFS_DIR" ]; then
        echo "[i] No VFS cache directory at ${VFS_DIR}."
        return 0
    fi

    REAL_KB=$(du -sk "$VFS_DIR" 2>/dev/null | cut -f1)
    REAL_H=$(du -sh "$VFS_DIR" 2>/dev/null | cut -f1)
    echo ""
    echo "Real disk used: ${REAL_H}"

    # ---------------------------------------------------------------
    # 1. What flags is the RUNNING process actually using?
    #    A unit file edited but never reloaded/restarted is the single
    #    most common reason limits appear to be ignored.
    # ---------------------------------------------------------------
    echo ""
    echo "--- 1. Flags of the RUNNING rclone process ---"
    RCLONE_PID=$(pgrep -u "$(id -u)" -f "rclone mount" | head -n1)
    if [ -z "$RCLONE_PID" ]; then
        echo "  [!] No running 'rclone mount' process found for this user."
        echo "      A stopped mount cannot evict anything, so the cache just sits there."
    else
        echo "  PID: ${RCLONE_PID}  (started: $(ps -o lstart= -p "$RCLONE_PID" 2>/dev/null | xargs))"
        RUNNING_ARGS=$(tr '\0' '\n' < "/proc/${RCLONE_PID}/cmdline" 2>/dev/null | tr '\n' ' ')
        for FLAG in --vfs-cache-max-size --vfs-cache-max-age --vfs-cache-min-free-space --vfs-cache-poll-interval --cache-dir; do
            VAL=$(echo "$RUNNING_ARGS" | grep -oE -- "${FLAG}[= ][^ ]+" | head -n1 | awk '{print $2}')
            if [ -n "$VAL" ]; then
                printf '    %-28s %s\n' "$FLAG" "$VAL"
            else
                printf '    %-28s %s\n' "$FLAG" "NOT SET  <-- unbounded!"
            fi
        done
        echo ""
        echo "  If these differ from your unit file, the service was never restarted:"
        echo "      systemctl --user daemon-reload && systemctl --user restart ${SERVICE_NAME}.service"
    fi

    # ---------------------------------------------------------------
    # 2. Dirty items: pending upload. These are NEVER evicted, by
    #    design, and deleting them loses data.
    # ---------------------------------------------------------------
    echo ""
    echo "--- 2. Dirty items (pending upload, NEVER evicted) ---"
    DIRTY_COUNT=0
    DIRTY_BYTES=0
    if [ -d "$VFS_META_DIR" ]; then
        while IFS= read -r META; do
            if grep -q '"Dirty": true' "$META" 2>/dev/null; then
                REL="${META#"$VFS_META_DIR"/}"
                DATA_FILE="${VFS_DIR}/${REL}"
                if [ -f "$DATA_FILE" ]; then
                    B=$(( $(stat -c %b "$DATA_FILE" 2>/dev/null || echo 0) * 512 ))
                    DIRTY_BYTES=$((DIRTY_BYTES + B))
                    if [ "$DIRTY_COUNT" -lt 15 ]; then
                        printf '    %8s  %s\n' \
                            "$(numfmt --to=iec --suffix=B "$B" 2>/dev/null || echo "$B")" "$REL"
                    fi
                fi
                DIRTY_COUNT=$((DIRTY_COUNT + 1))
            fi
        done < <(find "$VFS_META_DIR" -type f 2>/dev/null)
    fi
    if [ "$DIRTY_COUNT" -eq 0 ]; then
        echo "    None. Nothing is waiting to upload (safe to clear the cache)."
    else
        echo ""
        echo "    ${DIRTY_COUNT} dirty file(s), $(numfmt --to=iec --suffix=B "$DIRTY_BYTES" 2>/dev/null || echo "$DIRTY_BYTES") pinned."
        echo "    [!] DO NOT 'rm -rf' the cache - these have not reached Drive yet."
        echo "        Check for upload errors:"
        echo "          grep -iE 'vfs cache: (failed|error)' ${CACHE_DIR}/rclone.log | tail -20"
    fi

    # ---------------------------------------------------------------
    # 3. Orphans: data files with no metadata. Rclone does not count
    #    these toward the quota, so they are never evicted.
    # ---------------------------------------------------------------
    echo ""
    echo "--- 3. Orphaned files (untracked, never counted or evicted) ---"
    ORPHAN_COUNT=0
    ORPHAN_BYTES=0
    while IFS= read -r DATA_FILE; do
        REL="${DATA_FILE#"$VFS_DIR"/}"
        if [ ! -f "${VFS_META_DIR}/${REL}" ]; then
            B=$(( $(stat -c %b "$DATA_FILE" 2>/dev/null || echo 0) * 512 ))
            ORPHAN_BYTES=$((ORPHAN_BYTES + B))
            if [ "$ORPHAN_COUNT" -lt 15 ]; then
                printf '    %8s  %s\n' \
                    "$(numfmt --to=iec --suffix=B "$B" 2>/dev/null || echo "$B")" "$REL"
            fi
            ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        fi
    done < <(find "$VFS_DIR" -type f 2>/dev/null)
    if [ "$ORPHAN_COUNT" -eq 0 ]; then
        echo "    None. Every cached file has tracking metadata."
    else
        echo ""
        echo "    ${ORPHAN_COUNT} orphan(s), $(numfmt --to=iec --suffix=B "$ORPHAN_BYTES" 2>/dev/null || echo "$ORPHAN_BYTES") invisible to the quota."
        echo "    These are leftovers (crash, kill -9, or a previously unbounded mount)."
        echo "    They have no pending data and are safe to delete while stopped."
    fi

    # ---------------------------------------------------------------
    # 4. Currently open files - cannot be evicted while held.
    # ---------------------------------------------------------------
    echo ""
    echo "--- 4. Cache files held open right now ---"
    if [ -n "$RCLONE_PID" ] && [ -d "/proc/${RCLONE_PID}/fd" ]; then
        OPEN_LIST=$(find "/proc/${RCLONE_PID}/fd" -type l 2>/dev/null \
            | xargs -r readlink 2>/dev/null | grep "^${VFS_DIR}/" || true)
        if [ -z "$OPEN_LIST" ]; then
            echo "    None. Nothing is pinned by an open handle."
        else
            echo "$OPEN_LIST" | sort -u | head -n 15 | sed "s|^${VFS_DIR}/|    |"
            echo "    (open files cannot be evicted until the reader closes them)"
        fi
    else
        echo "    (cannot inspect - no running process)"
    fi

    # ---------------------------------------------------------------
    # 5. Verdict
    # ---------------------------------------------------------------
    RECLAIM=$((ORPHAN_BYTES / 1024))
    echo ""
    echo "=========================================================="
    echo "  Summary"
    echo "=========================================================="
    printf '  Real usage        : %s\n' "$REAL_H"
    printf '  Pending upload    : %s (must keep)\n' \
        "$(numfmt --to=iec --suffix=B "$DIRTY_BYTES" 2>/dev/null || echo "$DIRTY_BYTES")"
    printf '  Orphaned          : %s (safe to reclaim)\n' \
        "$(numfmt --to=iec --suffix=B "$ORPHAN_BYTES" 2>/dev/null || echo "$ORPHAN_BYTES")"
    echo ""
    if [ "$ORPHAN_COUNT" -gt 0 ] && [ "$RECLAIM" -gt $((REAL_KB / 2)) ]; then
        echo "  => Most of your cache is ORPHANED and invisible to rclone's quota."
        echo "     That is why the size limit never kicks in. Reclaim it with:"
        echo "         ./setup_gdrive_mount.sh clear-cache"
    elif [ "$DIRTY_COUNT" -gt 0 ] && [ "$DIRTY_BYTES" -gt $((REAL_KB * 1024 / 2)) ]; then
        echo "  => Most of your cache is PENDING UPLOAD and cannot be evicted."
        echo "     Fix the uploads (check the log above); do not delete the cache."
    else
        echo "  => No single dominant cause found above. The most likely"
        echo "     explanation is the running process lacking the limits"
        echo "     (see section 1) - restart the service to apply them."
    fi
    echo ""
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

do_purge_orphans() {
    VFS_DIR="${CACHE_DIR}/vfs"
    VFS_META_DIR="${CACHE_DIR}/vfsMeta"

    echo ""
    echo "=== Purge Orphaned Cache Files ==="
    echo "Removes ONLY cache files with no tracking metadata. Files pending"
    echo "upload are left untouched, so this cannot lose data."
    echo ""

    if [ ! -d "$VFS_DIR" ]; then
        echo "[i] No VFS cache directory."
        return 0
    fi

    if systemctl --user is-active --quiet "${SERVICE_NAME}.service"; then
        echo "[!] The mount is running. Stop it first so rclone is not writing"
        echo "    to these files while we delete them:"
        echo "        systemctl --user stop ${SERVICE_NAME}.service"
        return 1
    fi

    ORPHANS=$(mktemp)
    TOTAL=0
    COUNT=0
    while IFS= read -r DATA_FILE; do
        REL="${DATA_FILE#"$VFS_DIR"/}"
        if [ ! -f "${VFS_META_DIR}/${REL}" ]; then
            B=$(( $(stat -c %b "$DATA_FILE" 2>/dev/null || echo 0) * 512 ))
            TOTAL=$((TOTAL + B))
            COUNT=$((COUNT + 1))
            printf '%s\n' "$DATA_FILE" >> "$ORPHANS"
        fi
    done < <(find "$VFS_DIR" -type f 2>/dev/null)

    if [ "$COUNT" -eq 0 ]; then
        echo "[i] No orphaned files found."
        rm -f "$ORPHANS"
        return 0
    fi

    echo "Found ${COUNT} orphaned file(s) totalling $(numfmt --to=iec --suffix=B "$TOTAL" 2>/dev/null || echo "$TOTAL"):"
    head -n 10 "$ORPHANS" | sed "s|^${VFS_DIR}/|    |"
    [ "$COUNT" -gt 10 ] && echo "    ... and $((COUNT - 10)) more"
    echo ""
    read -p "Delete these ${COUNT} file(s)? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        rm -f "$ORPHANS"
        return 0
    fi

    while IFS= read -r F; do rm -f "$F"; done < "$ORPHANS"
    rm -f "$ORPHANS"
    find "$VFS_DIR" -type d -empty -delete 2>/dev/null || true
    echo "[✓] Reclaimed $(numfmt --to=iec --suffix=B "$TOTAL" 2>/dev/null || echo "$TOTAL")."
    echo "    Cache is now: $(du -sh "$VFS_DIR" 2>/dev/null | cut -f1)"
}

do_clear_cache() {
    echo ""
    echo "=== Clear VFS Cache ==="
    echo "[!] The cache can hold files that have NOT finished uploading to Drive."
    echo "    Deleting it while those are pending means DATA LOSS."
    echo ""

    # Hard stop if anything is still pending upload. Counting dirty items is
    # cheap and prevents the single most destructive mistake available here.
    VFS_META_DIR="${CACHE_DIR}/vfsMeta"
    DIRTY_N=0
    DIRTY_B=0
    if [ -d "$VFS_META_DIR" ]; then
        while IFS= read -r META; do
            if grep -q '"Dirty": true' "$META" 2>/dev/null; then
                REL="${META#"$VFS_META_DIR"/}"
                SRC="${CACHE_DIR}/vfs/${REL}"
                if [ -f "$SRC" ]; then
                    DIRTY_B=$((DIRTY_B + $(( $(stat -c %b "$SRC" 2>/dev/null || echo 0) * 512 )) ))
                fi
                DIRTY_N=$((DIRTY_N + 1))
            fi
        done < <(find "$VFS_META_DIR" -type f 2>/dev/null)
    fi

    if [ "$DIRTY_N" -gt 0 ]; then
        echo "  ######################################################"
        echo "  #  REFUSING TO CLEAR - DATA WOULD BE LOST            #"
        echo "  ######################################################"
        echo ""
        echo "  ${DIRTY_N} file(s) totalling $(numfmt --to=iec --suffix=B "$DIRTY_B" 2>/dev/null || echo "$DIRTY_B") have NOT reached Google Drive."
        echo "  They exist ONLY here. Deleting the cache destroys them."
        echo ""
        echo "  Do this instead:"
        echo "    1. Find out why uploads are failing:"
        echo "         ./setup_gdrive_mount.sh uploads"
        echo "    2. Copy the pending data somewhere safe:"
        echo "         ./setup_gdrive_mount.sh rescue-pending ~/drive-backup"
        echo "    3. Only then, if you still want to wipe the cache, re-run"
        echo "       this command with the override:"
        echo "         ./setup_gdrive_mount.sh clear-cache --force"
        echo ""
        if [ "$FORCE_CLEAR" != true ]; then
            return 1
        fi
        echo "  [!] --force given: proceeding despite ${DIRTY_N} pending file(s)."
        read -p "  Type DELETE to confirm permanent loss: " FORCE_CONFIRM
        if [ "$FORCE_CONFIRM" != "DELETE" ]; then
            echo "  Cancelled."
            return 1
        fi
    fi

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
    --transfers ${TRANSFERS} \\
    --drive-chunk-size ${DRIVE_CHUNK_SIZE} \\
    --drive-upload-cutoff ${DRIVE_CHUNK_SIZE} \\
    --drive-pacer-min-sleep ${DRIVE_PACER_MIN_SLEEP} \\
    --drive-pacer-burst ${DRIVE_PACER_BURST} \\
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
    diagnose)
        do_diagnose
        ;;
    purge-orphans)
        do_purge_orphans
        ;;
    uploads)
        do_uploads
        ;;
    speedcheck)
        do_speedcheck
        ;;
    rescue-pending)
        shift
        do_rescue_pending "$1"
        ;;
    clear-cache)
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --force) FORCE_CLEAR=true; shift ;;
                *) shift ;;
            esac
        done
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
        echo "5) Diagnose why the cache is too big"
        echo "6) Analyse pending uploads / failures"
        echo "7) Check upload speed & throttling"
        echo "8) Purge orphaned files only (data-safe)"
        echo "9) Safely clear entire VFS cache"
        echo "10) Exit"
        echo "=========================================="
        read -p "Select an action [1-10]: " ACTION_CHOICE

        case "$ACTION_CHOICE" in
            1) do_setup ;;
            2) do_unmount ;;
            3) do_status ;;
            4) do_cache ;;
            5) do_diagnose ;;
            6) do_uploads ;;
            7) do_speedcheck ;;
            8) do_purge_orphans ;;
            9) do_clear_cache ;;
            10) echo "Exiting."; exit 0 ;;
            *) echo "Invalid option."; exit 1 ;;
        esac
        ;;
esac
