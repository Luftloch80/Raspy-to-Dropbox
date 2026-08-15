#!/usr/bin/env bash
# backup-raspi.sh — Create a compressed Raspberry Pi OS disk image and upload it to Dropbox.
#
# Requirements (on the Pi):
#   - root privileges (sudo)
#   - rclone configured with a Dropbox remote
#   - pigz or gzip, and dd
#
# Quick start:
#   1. cp config.example.env config.env && edit config.env
#   2. rclone config   # create remote named "dropbox" (or match DROPBOX_REMOTE)
#   3. sudo ./backup-raspi.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"

# ---------------------------------------------------------------------------
# Defaults (overridden by config.env / environment)
# ---------------------------------------------------------------------------
HOSTNAME_LABEL="$(hostname -s 2>/dev/null || echo raspi)"
BACKUP_DIR="${BACKUP_DIR:-/var/tmp/raspi-backup}"
DROPBOX_REMOTE="${DROPBOX_REMOTE:-dropbox}"
DROPBOX_PATH="${DROPBOX_PATH:-/RaspiBackups/${HOSTNAME_LABEL}}"
KEEP_LOCAL="${KEEP_LOCAL:-0}"
KEEP_REMOTE="${KEEP_REMOTE:-3}"
COMPRESS="${COMPRESS:-gzip}"          # gzip | pigz | xz | zstd | none
DD_BS="${DD_BS:-4M}"
SOURCE_DEVICE="${SOURCE_DEVICE:-}"    # empty = auto-detect
DRY_RUN="${DRY_RUN:-0}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
LOG_FILE="${LOG_FILE:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] $*"
  if [[ -n "${LOG_FILE}" ]]; then
    echo "[${ts}] $*" >> "${LOG_FILE}"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${CONFIG_FILE}"
    set +a
    log "Loaded config: ${CONFIG_FILE}"
  else
    log "No config file at ${CONFIG_FILE}; using defaults / environment"
  fi
}

require_root() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN=1 — root not required"
    return
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root (e.g. sudo $0)"
  fi
}

detect_source_device() {
  if [[ -n "${SOURCE_DEVICE}" ]]; then
    if [[ ! -b "${SOURCE_DEVICE}" && "${DRY_RUN}" != "1" ]]; then
      die "SOURCE_DEVICE is not a block device: ${SOURCE_DEVICE}"
    fi
    echo "${SOURCE_DEVICE}"
    return
  fi

  # Prefer the device that holds root (/)
  local root_src root_disk
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ -n "${root_src}" ]]; then
    root_disk="$(lsblk -no PKNAME "${root_src}" 2>/dev/null || true)"
    if [[ -z "${root_disk}" ]]; then
      # Already a whole disk (e.g. /dev/sda) or partition naming edge case
      if [[ -b "${root_src}" ]]; then
        # Strip partition suffix: mmcblk0p2 -> mmcblk0, nvme0n1p2 -> nvme0n1, sda2 -> sda
        root_disk="$(echo "${root_src}" | sed -E 's|^/dev/||; s/p?[0-9]+$//')"
      fi
    fi
    if [[ -n "${root_disk}" && -b "/dev/${root_disk}" ]]; then
      echo "/dev/${root_disk}"
      return
    fi
  fi

  # Fallbacks common on Raspberry Pi
  for candidate in /dev/mmcblk0 /dev/nvme0n1 /dev/sda; do
    if [[ -b "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "/dev/mmcblk0"
    return
  fi

  die "Could not auto-detect source disk. Set SOURCE_DEVICE in config.env"
}

compress_ext() {
  case "${COMPRESS}" in
    gzip|pigz) echo "gz" ;;
    xz)        echo "xz" ;;
    zstd)      echo "zst" ;;
    none)      echo "" ;;
    *)         die "Unsupported COMPRESS='${COMPRESS}' (use gzip|pigz|xz|zstd|none)" ;;
  esac
}

compress_pipeline() {
  case "${COMPRESS}" in
    gzip)
      need_cmd gzip
      gzip -c
      ;;
    pigz)
      need_cmd pigz
      pigz -c
      ;;
    xz)
      need_cmd xz
      xz -T0 -c
      ;;
    zstd)
      need_cmd zstd
      zstd -T0 -c
      ;;
    none)
      cat
      ;;
  esac
}

remote_path() {
  # rclone path: remote:path
  echo "${DROPBOX_REMOTE}:${DROPBOX_PATH#/}"
}

check_disk_space() {
  local device="$1"
  local dest_dir="$2"
  local device_bytes free_bytes needed

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN=1 — skipping disk space check"
    return
  fi

  device_bytes="$(blockdev --getsize64 "${device}")"
  free_bytes="$(df -B1 --output=avail "${dest_dir}" | tail -1 | tr -d ' ')"

  # Compressed images are usually much smaller; still require ~15% of raw size locally
  # unless KEEP_LOCAL=0 and we stream… we write a local file first for reliability.
  needed=$(( device_bytes / 7 ))
  if [[ "${needed}" -lt 536870912 ]]; then
    needed=536870912  # at least 512 MiB free
  fi

  if [[ "${free_bytes}" -lt "${needed}" ]]; then
    die "Not enough free space in ${dest_dir} (need ~$((needed / 1024 / 1024)) MiB, have $((free_bytes / 1024 / 1024)) MiB)"
  fi
}

create_image() {
  local device="$1"
  local outfile="$2"

  log "Imaging ${device} -> ${outfile}"
  log "Block size ${DD_BS}, compression=${COMPRESS}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN=1 — skipping image creation"
    return
  fi

  # Sync filesystems before imaging a live system
  sync

  if [[ "${COMPRESS}" == "none" ]]; then
    dd if="${device}" of="${outfile}" bs="${DD_BS}" status=progress conv=fsync
  else
    # Stream compress to reduce peak disk usage vs writing raw then compressing
    dd if="${device}" bs="${DD_BS}" status=progress | compress_pipeline > "${outfile}"
  fi

  sync
  local size
  size="$(du -h "${outfile}" | awk '{print $1}')"
  log "Image created (${size}): ${outfile}"
}

upload_to_dropbox() {
  local outfile="$1"
  local remote
  remote="$(remote_path)"

  log "Uploading to ${remote}/"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN=1 — would run: rclone copy ${outfile} ${remote}/ --progress"
    return
  fi

  if [[ "${SKIP_UPLOAD}" == "1" ]]; then
    log "SKIP_UPLOAD=1 — leaving image local only"
    return
  fi

  need_cmd rclone

  # Large Pi images benefit from Dropbox chunked upload defaults in rclone
  rclone copy "${outfile}" "${remote}/" \
    --progress \
    --retries 5 \
    --low-level-retries 10 \
    --timeout 1h \
    --contimeout 60s

  log "Upload finished"
}

prune_remote() {
  local remote
  remote="$(remote_path)"

  if [[ "${KEEP_REMOTE}" -le 0 ]]; then
    log "KEEP_REMOTE=${KEEP_REMOTE} — not pruning remote backups"
    return
  fi

  if [[ "${DRY_RUN}" == "1" || "${SKIP_UPLOAD}" == "1" ]]; then
    log "Skipping remote prune (dry-run or skip-upload)"
    return
  fi

  need_cmd rclone

  log "Pruning remote backups; keeping newest ${KEEP_REMOTE}"

  # List image files only, newest first, delete older ones beyond KEEP_REMOTE
  mapfile -t remote_files < <(
    rclone lsf "${remote}/" --files-only 2>/dev/null \
      | grep -E '\.img(\.(gz|xz|zst))?$' \
      | sort -r
  ) || true

  local count="${#remote_files[@]}"
  if [[ "${count}" -le "${KEEP_REMOTE}" ]]; then
    log "Remote has ${count} backup(s); nothing to prune"
    return
  fi

  local i
  for ((i = KEEP_REMOTE; i < count; i++)); do
    log "Deleting old remote backup: ${remote_files[$i]}"
    rclone deletefile "${remote}/${remote_files[$i]}"
  done
}

cleanup_local() {
  local outfile="$1"

  if [[ "${KEEP_LOCAL}" == "1" ]]; then
    log "KEEP_LOCAL=1 — keeping ${outfile}"
    return
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN=1 — would remove ${outfile}"
    return
  fi

  if [[ -f "${outfile}" ]]; then
    rm -f "${outfile}"
    log "Removed local image ${outfile}"
  fi
}

print_summary() {
  cat <<EOF

============================================================
 Raspberry Pi → Dropbox backup
============================================================
 Host:          ${HOSTNAME_LABEL}
 Source device: ${DETECTED_DEVICE}
 Output:        ${OUTPUT_FILE}
 Dropbox:       $(remote_path)/
 Keep local:    ${KEEP_LOCAL}
 Keep remote:   ${KEEP_REMOTE}
 Compress:      ${COMPRESS}
 Dry run:       ${DRY_RUN}
============================================================

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  load_config
  require_root

  need_cmd dd
  need_cmd lsblk
  need_cmd findmnt
  need_cmd blockdev
  need_cmd df
  need_cmd du

  mkdir -p "${BACKUP_DIR}"
  if [[ -n "${LOG_FILE}" ]]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"
  fi

  DETECTED_DEVICE="$(detect_source_device)"
  local stamp ext outfile
  stamp="$(date '+%Y%m%d-%H%M%S')"
  ext="$(compress_ext)"
  if [[ -n "${ext}" ]]; then
    outfile="${BACKUP_DIR}/${HOSTNAME_LABEL}-${stamp}.img.${ext}"
  else
    outfile="${BACKUP_DIR}/${HOSTNAME_LABEL}-${stamp}.img"
  fi
  OUTPUT_FILE="${outfile}"

  print_summary
  check_disk_space "${DETECTED_DEVICE}" "${BACKUP_DIR}"

  create_image "${DETECTED_DEVICE}" "${outfile}"
  upload_to_dropbox "${outfile}"
  prune_remote
  cleanup_local "${outfile}"

  log "Backup completed successfully"
}

main "$@"
