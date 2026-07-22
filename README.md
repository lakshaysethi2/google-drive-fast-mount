# High-Performance Google Drive Rclone Mount for Linux

Automated installer and `systemd` user service configuration to mount Google Drive on Linux with sub-millisecond local caching performance.

## Features

- **Instant Directory Listings**: Uses `--attr-timeout 1000h` and `--dir-cache-time 1000h` so commands like `ls` finish in ~10 milliseconds.
- **Full VFS Read/Write Caching**: Uses `--vfs-cache-mode full` for seamless read prefetching and async writes.
- **Systemd User Service**: Starts automatically on boot, restarts on failure, and manages unmounting safely (`fusermount -u -z`).
- **User Linger Enabled**: Mount stays active in the background even after SSH logout (`loginctl enable-linger`).

---

## Quick Start (Automated Setup)

Clone this repository and run the setup script:

```bash
git clone https://github.com/lakshaysethi2/google-drive-fast-mount.git
cd google-drive-fast-mount
chmod +x setup_gdrive_mount.sh
./setup_gdrive_mount.sh
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

## Service Management Commands

- **Check Status**: `systemctl --user status rclone-gdrive.service`
- **Restart Mount**: `systemctl --user restart rclone-gdrive.service`
- **Stop Mount**: `systemctl --user stop rclone-gdrive.service`
- **View Logs**: `tail -f ~/.cache/rclone/rclone.log`

---

## Multi-Machine Replication

To copy your existing Google Drive authentication to another machine without re-authenticating:

1. Copy your `~/.config/rclone/rclone.conf` to the new machine:
   ```bash
   mkdir -p ~/.config/rclone
   scp user@source-server:~/.config/rclone/rclone.conf ~/.config/rclone/
   ```
2. Run `./setup_gdrive_mount.sh` on the new machine.
