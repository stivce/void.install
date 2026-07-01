#!/usr/bin/env bash
#
# void-install.sh — minimal unattended Void Linux (glibc, UEFI) installer.
#
# Run as root from the Void live ISO. Reads hostname/user/timezone/keymap/
# password hashes from a config file (see void.cfg.example); the
# only interactive steps are picking the disk (TUI) and confirming the wipe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly MNT="/mnt"
readonly REPO="https://repo-default.voidlinux.org/current"

readonly REQUIRED_BINARIES=(sfdisk mkfs.btrfs mkfs.vfat xbps-install chroot blkid blockdev udevadm)
readonly REQUIRED_CONF_VARS=(HOSTNAME USERNAME USER_PASSWORD_HASH ROOT_PASSWORD_HASH TIMEZONE KEYMAP)
readonly CHROOT_PACKAGES=(sudo grub-x86_64-efi python3 openssh btrfs-progs fastfetch)

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() { set +e; umount -R "$MNT" 2>/dev/null; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

check_requirements() {
  [ "$(id -u)" -eq 0 ] || die "Run this as root."

  local bin
  for bin in "${REQUIRED_BINARIES[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || die "Missing tool: $bin (are you on the Void live ISO?)"
  done

  [ -d /sys/firmware/efi ] || die "Not booted in UEFI mode — this script only supports UEFI installs."
  [ -f "$SCRIPT_DIR/chroot-setup.sh" ] || die "chroot-setup.sh not found next to void-install.sh."
}

check_network() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsSL --max-time 10 "$REPO" -o /dev/null \
    || die "Could not reach $REPO — set up networking (dhcpcd/wpa_supplicant/iwctl) before running this script."
}

validate_hash() {
  local name="$1" hash="$2"
  [[ "$hash" =~ ^\$[0-9A-Za-z]+\$[^$]+\$.+$ ]] \
    || die "$name doesn't look like a crypt() hash (expected \$id\$salt\$hash, e.g. from 'openssl passwd -6')."
}

load_config() {
  CONF="${1:-$SCRIPT_DIR/void.cfg}"
  [ -f "$CONF" ] || die "Config file not found: $CONF (copy void.cfg.example and edit it)."
  # shellcheck disable=SC1090
  source "$CONF"

  local var
  for var in "${REQUIRED_CONF_VARS[@]}"; do
    [ -n "${!var:-}" ] || die "Missing $var in $CONF"
  done

  [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || die "Unknown timezone: $TIMEZONE"
  validate_hash "ROOT_PASSWORD_HASH" "$ROOT_PASSWORD_HASH"
  validate_hash "USER_PASSWORD_HASH" "$USER_PASSWORD_HASH"

  BOOT_SIZE_MB="${BOOT_SIZE_MB:-254}"
  SWAP_SIZE_MB="${SWAP_SIZE_MB:-8192}"
  MIN_ROOT_MB="${MIN_ROOT_MB:-4096}"
  readonly BOOT_SIZE_MB SWAP_SIZE_MB MIN_ROOT_MB
}

# ---------------------------------------------------------------------------
# Disk selection
# ---------------------------------------------------------------------------

disk_in_use() {
  local disk="$1" dev
  while read -r dev; do
    grep -qw "$dev" /proc/mounts && return 0
    grep -qw "$dev" /proc/swaps && return 0
  done < <(lsblk -lnpo NAME "$disk" 2>/dev/null)
  return 1
}

select_disk_dialog() {
  local line name rest
  local items=()
  for line in "${DISK_LINES[@]}"; do
    name=$(awk '{print $1}' <<<"$line")
    rest=$(cut -d' ' -f2- <<<"$line")
    items+=("$name" "$rest")
  done
  DISK=$(dialog --clear --stdout --menu "Select the disk to ERASE and install Void onto" 20 70 10 "${items[@]}") \
    || die "Cancelled."
  clear
}

select_disk_fallback() {
  local line idx i=1
  declare -A by_index
  echo "Available disks:"
  for line in "${DISK_LINES[@]}"; do
    printf "  %d) %s\n" "$i" "$line"
    by_index[$i]=$(awk '{print $1}' <<<"$line")
    i=$((i + 1))
  done
  read -rp "Select disk number: " idx
  DISK="${by_index[$idx]:-}"
}

select_disk() {
  log "Scanning disks..."
  local all_lines line dev
  mapfile -t all_lines < <(lsblk -dpno NAME,SIZE,MODEL -e7,11 2>/dev/null)
  [ "${#all_lines[@]}" -gt 0 ] || die "No disks found."

  DISK_LINES=()
  for line in "${all_lines[@]}"; do
    dev=$(awk '{print $1}' <<<"$line")
    disk_in_use "$dev" || DISK_LINES+=("$line")
  done
  [ "${#DISK_LINES[@]}" -gt 0 ] \
    || die "No unused disks found — every disk detected has a mounted partition or active swap (this is usually the boot media)."

  if command -v dialog >/dev/null 2>&1; then
    select_disk_dialog
  else
    select_disk_fallback
  fi

  [ -n "${DISK:-}" ] && [ -b "$DISK" ] || die "Invalid disk selection."
}

check_disk_size() {
  local disk_bytes disk_mb required_mb
  disk_bytes=$(lsblk -dnbo SIZE "$DISK")
  disk_mb=$((disk_bytes / 1024 / 1024))
  required_mb=$((BOOT_SIZE_MB + SWAP_SIZE_MB + MIN_ROOT_MB))
  [ "$disk_mb" -ge "$required_mb" ] \
    || die "$DISK is only ${disk_mb}MiB; need at least ${required_mb}MiB (${BOOT_SIZE_MB}MiB boot + ${SWAP_SIZE_MB}MiB swap + ${MIN_ROOT_MB}MiB minimum root)."
}

confirm_wipe() {
  local confirm
  read -rp "This will ERASE ALL DATA on $DISK ($(lsblk -dno SIZE "$DISK")). Continue? [y/N] " confirm
  case "$confirm" in
    y | Y | yes | YES) ;;
    *) die "Aborting, nothing touched." ;;
  esac
}

# ---------------------------------------------------------------------------
# Partition, format, mount
# ---------------------------------------------------------------------------

readonly GUID_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
readonly GUID_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
readonly GUID_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

compute_partition_layout() {
  local suffix=""
  case "$DISK" in
    *nvme* | *mmcblk*) suffix="p" ;;
  esac

  ESP_PART="${DISK}${suffix}1"
  if [ "$SWAP_SIZE_MB" -gt 0 ]; then
    SWAP_PART="${DISK}${suffix}2"
    ROOT_PART="${DISK}${suffix}3"
  else
    SWAP_PART=""
    ROOT_PART="${DISK}${suffix}2"
  fi
}

partition_disk() {
  disk_in_use "$DISK" && die "$DISK appears to be in use (mounted or active swap) — refusing to partition it."

  log "Partitioning $DISK (GPT: ${BOOT_SIZE_MB}MiB boot + ${SWAP_SIZE_MB}MiB swap + btrfs root)..."

  {
    echo "label: gpt"
    echo
    echo "size=${BOOT_SIZE_MB}MiB, type=${GUID_ESP}, name=\"ESP\""
    if [ -n "$SWAP_PART" ]; then
      echo "size=${SWAP_SIZE_MB}MiB, type=${GUID_SWAP}, name=\"swap\""
    fi
    echo "type=${GUID_LINUX}, name=\"root\""
  } | sfdisk "$DISK"

  blockdev --rereadpt "$DISK"
  udevadm settle
}

format_partitions() {
  log "Formatting partitions..."
  mkfs.vfat -F32 -n EFI "$ESP_PART"
  [ -n "$SWAP_PART" ] && mkswap -L swap "$SWAP_PART" >/dev/null
  mkfs.btrfs -f -L void "$ROOT_PART"
}

mount_filesystems() {
  log "Mounting filesystems..."
  mount "$ROOT_PART" "$MNT"
  mkdir -p "$MNT/boot/efi"
  mount "$ESP_PART" "$MNT/boot/efi"
}

# ---------------------------------------------------------------------------
# Base system
# ---------------------------------------------------------------------------

install_base_system() {
  log "Installing base-system via xbps (this takes a while)..."
  mkdir -p "$MNT/var/db/xbps/keys"
  cp /var/db/xbps/keys/* "$MNT/var/db/xbps/keys/"
  xbps-install -Sy -R "$REPO" -r "$MNT" base-system
}

write_fstab() {
  log "Writing fstab..."
  if command -v xgenfstab >/dev/null 2>&1; then
    xgenfstab -U "$MNT" >>"$MNT/etc/fstab"
  else
    {
      echo "UUID=$(blkid -s UUID -o value "$ROOT_PART") / btrfs defaults,noatime 0 1"
      echo "UUID=$(blkid -s UUID -o value "$ESP_PART") /boot/efi vfat defaults 0 2"
    } >>"$MNT/etc/fstab"
  fi
  [ -n "$SWAP_PART" ] && echo "UUID=$(blkid -s UUID -o value "$SWAP_PART") swap swap defaults 0 0" >>"$MNT/etc/fstab"
}

prepare_chroot_env() {
  cp /etc/resolv.conf "$MNT/etc/resolv.conf"
  local d
  for d in dev proc sys; do
    mount --rbind "/$d" "$MNT/$d"
    mount --make-rslave "$MNT/$d"
  done
}

# ---------------------------------------------------------------------------
# Chroot configuration
# ---------------------------------------------------------------------------

write_chroot_script() {
  cp "$SCRIPT_DIR/chroot-setup.sh" "$MNT/root/void-chroot-setup.sh"
  chmod +x "$MNT/root/void-chroot-setup.sh"
}

run_chroot_setup() {
  log "Configuring installed system..."
  write_chroot_script

  chroot "$MNT" /usr/bin/env \
    CHR_HOSTNAME="$HOSTNAME" CHR_USERNAME="$USERNAME" CHR_TIMEZONE="$TIMEZONE" CHR_KEYMAP="$KEYMAP" \
    CHR_ROOT_HASH="$ROOT_PASSWORD_HASH" CHR_USER_HASH="$USER_PASSWORD_HASH" \
    CHR_PACKAGES="${CHROOT_PACKAGES[*]}" \
    /bin/bash /root/void-chroot-setup.sh

  rm -f "$MNT/root/void-chroot-setup.sh"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

finish() {
  log "Unmounting..."
  trap - EXIT
  umount -R "$MNT"
  log "Done. Remove the install media and reboot into $DISK."
}

main() {
  check_requirements
  check_network
  load_config "${1:-}"
  select_disk
  check_disk_size
  confirm_wipe
  compute_partition_layout
  partition_disk
  format_partitions
  mount_filesystems
  install_base_system
  write_fstab
  prepare_chroot_env
  run_chroot_setup
  finish
}

main "$@"
