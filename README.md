# Raspy-to-Dropbox

Backup a full Raspberry Pi OS disk image and upload it to Dropbox via [rclone](https://rclone.org/).

## What it does

1. Detects the boot disk (or uses `SOURCE_DEVICE` from config)
2. Creates a compressed image with `dd` + `pigz`/`gzip`/`xz`/`zstd`
3. Uploads the image to Dropbox with `rclone`
4. Keeps the newest N remote backups and deletes older ones
5. Removes the local image by default (saves SD/SSD space)

> Imaging a **live** system can include briefly inconsistent open files. For critical data, stop services first or shut down and image the card from another machine.

## Requirements

On the Raspberry Pi:

```bash
sudo apt update
sudo apt install -y rclone pigz
```

## One-time Dropbox setup

```bash
rclone config
```

1. Choose **New remote**
2. Name it `dropbox` (or change `DROPBOX_REMOTE` in config)
3. Storage: **Dropbox**
4. Follow the browser auth flow (on a headless Pi use the remote-config / `rclone authorize` steps rclone prints)

Test:

```bash
rclone lsd dropbox:
rclone mkdir dropbox:RaspiBackups
```

## Install this script

```bash
git clone https://github.com/Luftloch80/Raspy-to-Dropbox.git
cd Raspy-to-Dropbox
cp config.example.env config.env
nano config.env    # adjust paths / retention / compression
chmod +x backup-raspi.sh
```

## Run a backup

```bash
sudo ./backup-raspi.sh
```

Useful overrides:

```bash
# Preview only
sudo DRY_RUN=1 ./backup-raspi.sh

# Image locally, do not upload
sudo SKIP_UPLOAD=1 KEEP_LOCAL=1 ./backup-raspi.sh

# Custom config path
sudo CONFIG_FILE=/home/pi/my-backup.env ./backup-raspi.sh
```

## Cron (weekly example)

```bash
sudo crontab -e
```

```cron
# Every Sunday at 03:30
30 3 * * 0 /path/to/Raspy-to-Dropbox/backup-raspi.sh >> /var/log/raspi-dropbox-backup.log 2>&1
```

Ensure the root user can use the same rclone remote (copy config if needed):

```bash
sudo mkdir -p /root/.config/rclone
sudo cp ~/.config/rclone/rclone.conf /root/.config/rclone/rclone.conf
```

## Restore overview

1. Download the `.img.gz` (or `.img.xz` / `.img.zst`) from Dropbox
2. Decompress it
3. Flash to an SD card / USB / SSD with Raspberry Pi Imager, balenaEtcher, or:

```bash
# Example: write to SD reader at /dev/sdX — double-check the device name!
gunzip -c hostname-YYYYMMDD-HHMMSS.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

## Config reference

| Variable | Default | Meaning |
|----------|---------|---------|
| `BACKUP_DIR` | `/var/tmp/raspi-backup` | Local working directory |
| `DROPBOX_REMOTE` | `dropbox` | rclone remote name |
| `DROPBOX_PATH` | `/RaspiBackups/<hostname>` | Destination folder in Dropbox |
| `KEEP_LOCAL` | `0` | Keep local image after upload |
| `KEEP_REMOTE` | `3` | Remote backups to retain |
| `COMPRESS` | `pigz` | `gzip` / `pigz` / `xz` / `zstd` / `none` |
| `SOURCE_DEVICE` | auto | e.g. `/dev/mmcblk0` |
| `DRY_RUN` | `0` | Log actions only |
| `SKIP_UPLOAD` | `0` | Create image, skip Dropbox |
| `LOG_FILE` | empty | Optional log path |

## Notes

- Free space: the script writes a compressed image under `BACKUP_DIR` before upload. Prefer a large USB disk or enough free rootfs space.
- Default remote path includes the hostname so multiple Pis do not overwrite each other when you set `DROPBOX_PATH=/RaspiBackups` and rely on the script default (`/RaspiBackups/<hostname>`). Override `DROPBOX_PATH` in `config.env` if you want a fixed folder.
- `config.env` is gitignored — do not commit secrets or machine-specific paths.
