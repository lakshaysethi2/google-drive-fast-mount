# High-Performance Google Drive Rclone Mount for Linux

Automated installer and `systemd` user service configuration to mount Google Drive on Linux with sub-millisecond local caching performance.

## Features

- **Instant Directory Listings**: Uses `--attr-timeout 1000h` and `--dir-cache-time 1000h` so commands like `ls` finish in ~10 milliseconds.
- **Full VFS Read/Write Caching**: Uses `--vfs-cache-mode full` for seamless read prefetching and async writes.
- **Read-Only Mode**: Option to mount as read-only to prevent accidental modifications.
- **Systemd User Service**: Starts automatically on boot, restarts on failure, and manages unmounting safely (`fusermount -u -z`).
- **User Linger Enabled**: Mount stays active in the background even after SSH logout (`loginctl enable-linger`).
- **Bounded Disk Cache**: Size, age, and free-space limits keep the VFS cache from filling your disk, with built-in tooling to inspect and clear it.

---

## Quick Start (Automated Setup)

Clone this repository and run the setup script:

```bash
git clone https://github.com/lakshaysethi2/google-drive-fast-mount.git
cd google-drive-fast-mount
chmod +x setup_gdrive_mount.sh
./setup_gdrive_mount.sh
```

During setup, you will be prompted whether to mount as read-only. You can also pass the flag directly:

```bash
./setup_gdrive_mount.sh setup --readonly
```

---

## Manual Setup / Step-by-Step

### 1. Install Dependencies
```bash
sudo apt-get update && sudo apt-get install -y rclone fuse3
```

Ensure `user_allow_other` is enabled in `/etc/fuse.conf`:
```bash
echo "user_allow_other" | sudo tee -a /etc/fuse.conf
```

### 2. Configure Rclone Remote
When running `./setup_gdrive_mount.sh`, the script will ask:
```text
No rclone config found. Do you want to SCP your existing rclone config from another server? (y/N):
```
- **If you answer `y`**: Enter your source server (e.g. `ubuntu@192.168.1.50` or `my-server`). The script automatically copies `~/.config/rclone/rclone.conf` from the remote machine via `scp`.
- **If you answer `n`**: The script launches `rclone config` so you can set up Google Drive interactively.

### 3. Deploy Systemd User Service
Copy the service file:
```bash
mkdir -p ~/.config/systemd/user
cp rclone-gdrive.service ~/.config/systemd/user/
```

Reload systemd and start the service:
```bash
systemctl --user daemon-reload
systemctl --user enable --now rclone-gdrive.service
loginctl enable-linger $USER
```

---

## Managing the VFS Cache (Disk Usage)

With `--vfs-cache-mode full`, every byte you read or write passes through a
local cache at `~/.cache/rclone/vfs`. This section explains how to measure it
and how to keep it bounded.

### First: measure it correctly

**Most "my rclone cache is huge" reports are a measurement artifact.** Cache
files are [sparse files](https://en.wikipedia.org/wiki/Sparse_file): rclone
creates them at the *full* size of the remote file, but only the chunks you
actually read occupy real disk blocks. A 4 GB movie you watched 12 MB of
occupies 12 MB on disk while *appearing* to be 4 GB.

Use the built-in report, which shows both numbers side by side:

```bash
./setup_gdrive_mount.sh cache
```

```text
=== VFS Cache Usage ===
  Real disk used by cached data : 15M   <-- what fills your disk
  Apparent (sparse) size        : 4.1G   <-- misleading, ignore
```

Equivalently, by hand — note that **`du` tells the truth and
`du --apparent-size` does not**:

```bash
du -sh  ~/.cache/rclone/vfs                 # real blocks used  <-- trust this
du -sh --apparent-size ~/.cache/rclone/vfs  # inflated sparse size
df -h ~/.cache                              # actual free space on the disk
```

If `du -sh` is comfortably under your `--vfs-cache-max-size`, **nothing is
wrong** — you are looking at sparse-file accounting, not real consumption.
`ls -l`, `ncdu` (by default), and most file managers report the inflated
apparent size and will mislead you here.

### How the limits actually behave

| Flag | Effect |
| --- | --- |
| `--vfs-cache-max-size 5G` | Evicts least-recently-used files once cached **data** exceeds 5 G. |
| `--vfs-cache-max-age 1h` | Evicts files not *accessed* for 1 h. The timer resets on each access. |
| `--vfs-cache-min-free-space 5G` | Evicts early if the cache disk drops below 5 G free. Good safety net. |
| `--vfs-cache-poll-interval 1m` | How often the cleaner runs. **1m is already rclone's default.** |

Both size limits are **soft**, and the rclone docs are explicit about the two
reasons the cache can exceed them:

> If using `--vfs-cache-max-size` or `--vfs-cache-min-free-space` note that the
> cache may exceed these quotas for two reasons. Firstly because it is only
> checked every `--vfs-cache-poll-interval`. Secondly because **open files
> cannot be evicted** from the cache.
>
> — [rclone mount docs](https://rclone.org/commands/rclone_mount/#vfs-file-caching)

So streaming a single 30 GB file through a 5 GB cache can still use 30 GB while
that file is held open. The limits govern *eviction of idle files*, not a hard
ceiling during active use.

### When the cache really is too big

If `du -sh ~/.cache/rclone/vfs` genuinely exceeds your `--vfs-cache-max-size`,
run the diagnostic — it identifies which of the four causes applies:

```bash
./setup_gdrive_mount.sh diagnose
```

It reports the flags of the **running** process, then classifies every cached
file as pending-upload, orphaned, or open:

```text
--- 1. Flags of the RUNNING rclone process ---
    --vfs-cache-max-size         NOT SET  <-- unbounded!

--- 3. Orphaned files (untracked, never counted or evicted) ---
        20MB  gdrive/Movies/orphan1.mkv
    2 orphan(s), 34MB invisible to the quota.

  => Most of your cache is ORPHANED and invisible to rclone's quota.
```

The four real causes:

1. **The running process doesn't have the limits.** Editing the unit file does
   nothing until you `daemon-reload` *and* `restart`. A mount started before
   you added `--vfs-cache-max-size` runs unbounded until restarted. Section 1
   of the diagnostic shows what the live process is actually using — this is
   the most common cause by far, and the easiest to miss.
2. **Orphaned files.** Cache data whose `vfsMeta/` entry is missing is
   **invisible to rclone's accounting** — `updateUsed()` sums only tracked
   items, so orphans are never counted toward the quota and never evicted.
   They accumulate from crashes, `kill -9`, or a previously unbounded mount,
   and the cache grows without limit regardless of your settings.
3. **Pending uploads.** Dirty files are *never* evicted by design — evicting
   them would lose data. A stalled upload pins space indefinitely:
   ```bash
   grep -iE "vfs cache: (failed|error)" ~/.cache/rclone/rclone.log | tail -20
   ```
4. **Files held open** by a long-running reader (media server, indexer,
   backup job) cannot be evicted while the handle is open.

### Reclaiming space safely

If the diagnostic reports orphans, purge just those — pending uploads are left
untouched, so this cannot lose data:

```bash
systemctl --user stop rclone-gdrive.service
./setup_gdrive_mount.sh purge-orphans
systemctl --user start rclone-gdrive.service
```

It refuses to run while the mount is active, lists what it will delete, and
asks before removing anything.

### Clearing the cache safely

> [!WARNING]
> Do **not** blindly `rm -rf` the cache directory. It can contain files that
> have not finished uploading to Drive; deleting those loses data permanently.

Stop the service first so rclone flushes pending uploads on unmount, then clear:

```bash
./setup_gdrive_mount.sh clear-cache
```

This stops the mount (triggering writeback), confirms with you, removes both
`vfs/` and `vfsMeta/`, and offers to restart. The manual equivalent:

```bash
systemctl --user stop rclone-gdrive.service   # flushes pending uploads
rm -rf ~/.cache/rclone/vfs ~/.cache/rclone/vfsMeta
systemctl --user start rclone-gdrive.service
```

Note that `vfsMeta/` holds small JSON files (a few hundred bytes each) tracking
which byte ranges are cached. It is *not* a significant consumer of space, and
removing `vfs/` without `vfsMeta/` leaves stale metadata behind.

### Tuning the limits

Override the defaults at setup time via environment variables:

```bash
VFS_CACHE_MAX_SIZE=20G VFS_CACHE_MAX_AGE=6h VFS_CACHE_MIN_FREE=10G \
  ./setup_gdrive_mount.sh setup
```

A very low `--vfs-cache-max-age` (e.g. `2h` or less) is usually
counterproductive on a mount you use daily: it evicts files you are about to
reopen, forcing re-downloads that cost bandwidth, Drive API quota, and latency.
Prefer a generous age with a firm `--vfs-cache-max-size`, and let LRU eviction
do the work. If disk space is the real constraint, `--vfs-cache-min-free-space`
is the flag that directly protects the disk.

If you want to cap disk usage absolutely rather than softly, use
`--vfs-cache-mode writes` (reads stream straight from Drive and are never cached
to disk) at the cost of slower repeat reads and seeks.

---

## Upload Speed

Downloads usually saturate a connection easily; uploads to Google Drive often
do not. Check what is limiting yours:

```bash
./setup_gdrive_mount.sh speedcheck
```

### Watching a backlog drain

If files are queued for upload, track progress live:

```bash
./setup_gdrive_mount.sh watch
```

```text
TIME         FILES    REMAINING         RATE ETA
14:02:38       119        35GB          ... --
14:03:08       117        34GB      12MB/s 0h48m
```

It samples every 30s, reports rate and ETA, exits `0` when the backlog clears,
and exits `1` if nothing moves for 15 minutes so a genuinely stalled queue is
distinguishable from a merely slow one.

### Is it safe to restart mid-upload?

**Yes.** Stopping the service is a clean shutdown, not a data loss event:

- `ExecStop` runs `fusermount -u`, which flushes the VFS writeback queue.
- Anything that doesn't finish stays in the cache marked dirty, and rclone
  **resumes it automatically** on the next start. Nothing is dropped.
- Partial chunked uploads are restarted from the beginning of the file, so you
  lose in-flight progress on the current file, not the file itself.

The one thing you must never do is `rm -rf` the cache while files are pending.
Stopping the service is fine; deleting their only copy is not.

### The three real causes of slow uploads

**1. No personal `client_id` — usually the biggest factor.** By default rclone
uses a single OAuth client shared by every rclone user worldwide, and Google
rate-limits *per client*. You are queueing behind everyone else's traffic.
Creating your own is free and takes about ten minutes; it does not affect your
files or require re-uploading anything:
[Making your own client_id](https://rclone.org/drive/#making-your-own-client-id).

**2. `--drive-chunk-size` too small.** rclone's default is 8M. Each chunk is a
separate HTTP request, and the connection sits idle during each round trip. On
a link with any latency this caps throughput well below the line rate,
regardless of bandwidth. Raising it to 64M means fewer, larger requests.

**3. Per-stream throttling.** Google throttles each upload *stream*, so one
transfer rarely saturates a fast connection no matter how it's tuned. Several
parallel transfers beat one.

### Tuning

The defaults now applied are `--drive-chunk-size 64M`, `--transfers 4`, and
`--drive-pacer-min-sleep 10ms`. Override them:

```bash
DRIVE_CHUNK_SIZE=128M TRANSFERS=8 ./setup_gdrive_mount.sh setup
```

> [!IMPORTANT]
> **RAM cost is `--drive-chunk-size` × `--transfers`**, because each chunk is
> buffered in memory. `64M × 4` = 256 MB. Don't set `1G × 8` on a small
> machine — rclone will be OOM-killed mid-upload.

Raising `--transfers` past ~8 is usually counterproductive: Google starts
rate-limiting and everything slows down. If `speedcheck` reports rate-limit
responses, a personal `client_id` is the fix — more parallelism is not.

Also note Drive's ~750 GB/day upload cap. Exceeding it produces *errors*, not
slowness; `./setup_gdrive_mount.sh uploads` will identify that case.

---

## Service Management & Unmounting

- **Check Status**: `systemctl --user status rclone-gdrive.service`
- **Restart Mount**: `systemctl --user restart rclone-gdrive.service`
- **Stop/Unmount Service**: `systemctl --user stop rclone-gdrive.service`
- **Disable Auto-Start**: `systemctl --user disable --now rclone-gdrive.service`
- **View Logs**: `tail -f ~/.cache/rclone/rclone.log`
- **Cache Usage**: `./setup_gdrive_mount.sh cache`
- **Diagnose Cache Bloat**: `./setup_gdrive_mount.sh diagnose`
- **Pending Uploads / Failures**: `./setup_gdrive_mount.sh uploads`
- **Upload Speed Check**: `./setup_gdrive_mount.sh speedcheck`
- **Watch Backlog Drain**: `./setup_gdrive_mount.sh watch`
- **Rescue Pending Data**: `./setup_gdrive_mount.sh rescue-pending <dir>`
- **Purge Orphans (data-safe)**: `./setup_gdrive_mount.sh purge-orphans`
- **Clear Cache**: `./setup_gdrive_mount.sh clear-cache`

Because the unit uses `Type=notify`, `systemctl --user status` also shows live
VFS cache statistics reported by rclone itself, e.g.:

```text
Status: "[14:32] vfs cache: objects 12 (was 14) in use 1, to upload 0, uploading 0, total size 3.1Gi"
```

`to upload` / `uploading` are the counters to watch before clearing the cache —
both should be `0`.

### Manual Unmount Commands

If you ever need to manually unmount outside of `systemd`:
```bash
# Normal unmount
fusermount -u ~/mnt/google_drive

# Force / Lazy unmount (if busy)
fusermount -u -z ~/mnt/google_drive
```

---

## Multi-Machine Replication

To copy your existing Google Drive authentication to another machine without re-authenticating:

1. Copy your `~/.config/rclone/rclone.conf` to the new machine:
   ```bash
   mkdir -p ~/.config/rclone
   scp user@source-server:~/.config/rclone/rclone.conf ~/.config/rclone/
   ```
2. Run `./setup_gdrive_mount.sh` on the new machine.
