#!/usr/bin/env bash
# Arch Linux installer for Lenovo ThinkPad P52
# - 2x NVMe SSDs: ESP on NVMe1, LUKS+Btrfs root spanning both NVMes
# - 1x SATA  SSD: separate LUKS+Btrfs at /mnt/data
# - linux-lts, systemd-boot, NVIDIA Quadro (Pascal) + Intel UHD 630 hybrid
#
# Run from the Arch ISO live environment, booted in EFI mode.
# Place install.sh and chroot-config.sh in the same directory, then:
#   bash install.sh

set -euo pipefail

err() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root."
[[ -d /sys/firmware/efi ]] || err "Not booted in EFI mode."

# --- Prompts -----------------------------------------------------------------
echo "Available block devices:"
lsblk -dn -o NAME,SIZE,MODEL | grep -v -E 'loop|sr0'
echo

read -rp "NVMe 1 (ESP + root part 1, e.g. /dev/nvme0n1):  " NVME1
read -rp "NVMe 2 (root part 2, e.g. /dev/nvme1n1):        " NVME2
read -rp "SATA SSD (data drive, e.g. /dev/sda):           " SATA
read -rp "Hostname:  " HOSTNAME
read -rp "Username:  " USERNAME

while :; do
  read -rsp "User password: " USER_PASS; echo
  read -rsp "Confirm:       " USER_PASS2; echo
  [[ "$USER_PASS" == "$USER_PASS2" ]] && break
  echo "Mismatch, try again."
done

while :; do
  read -rsp "LUKS passphrase (used for ALL three drives): " LUKS_PASS; echo
  read -rsp "Confirm:                                      " LUKS_PASS2; echo
  [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
  echo "Mismatch, try again."
done

for d in "$NVME1" "$NVME2" "$SATA"; do
  [[ -b "$d" ]] || err "$d is not a block device"
done
[[ "$NVME1" != "$NVME2" && "$NVME1" != "$SATA" && "$NVME2" != "$SATA" ]] \
  || err "Drives must be distinct"

echo
echo "============================================================"
echo "  THIS WILL ERASE EVERYTHING ON $NVME1, $NVME2, AND $SATA"
echo "============================================================"
read -rp "Type YES (uppercase) to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || err "Aborted."

# --- Helpers -----------------------------------------------------------------
part_name() {
  local d=$1 n=$2
  if [[ "$d" =~ (nvme|mmcblk|loop) ]]; then echo "${d}p${n}"; else echo "${d}${n}"; fi
}

timedatectl set-ntp true

# --- Wipe + partition --------------------------------------------------------
echo "==> Partitioning"
wipefs -af "$NVME1" "$NVME2" "$SATA"
sgdisk -Zo "$NVME1"
sgdisk -Zo "$NVME2"
sgdisk -Zo "$SATA"

# NVMe1: 512 MiB ESP + remainder LUKS
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:EFI         "$NVME1"
sgdisk -n 2:0:0       -t 2:8309 -c 2:cryptroot1  "$NVME1"

# NVMe2: full disk LUKS
sgdisk -n 1:0:0       -t 1:8309 -c 1:cryptroot2  "$NVME2"

# SATA: full disk LUKS
sgdisk -n 1:0:0       -t 1:8309 -c 1:cryptdata   "$SATA"

partprobe "$NVME1" "$NVME2" "$SATA"
sleep 2

EFI_PART=$(part_name "$NVME1" 1)
LUKS1=$(part_name   "$NVME1" 2)
LUKS2=$(part_name   "$NVME2" 1)
LUKS3=$(part_name   "$SATA"  1)

# --- Format ESP --------------------------------------------------------------
echo "==> Formatting ESP at $EFI_PART"
mkfs.fat -F32 -n EFI "$EFI_PART"

# --- LUKS2 -------------------------------------------------------------------
echo "==> Creating LUKS2 containers"
for part in "$LUKS1" "$LUKS2" "$LUKS3"; do
  echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id \
    --key-file - "$part"
done

echo -n "$LUKS_PASS" | cryptsetup open --allow-discards --key-file - "$LUKS1" cryptroot1
echo -n "$LUKS_PASS" | cryptsetup open --allow-discards --key-file - "$LUKS2" cryptroot2
echo -n "$LUKS_PASS" | cryptsetup open --allow-discards --key-file - "$LUKS3" cryptdata

# --- Btrfs -------------------------------------------------------------------
echo "==> Creating Btrfs (root spans both NVMes)"
mkfs.btrfs -f -L arch -d single -m raid1 \
  /dev/mapper/cryptroot1 /dev/mapper/cryptroot2

echo "==> Creating Btrfs on SATA data drive"
mkfs.btrfs -f -L data /dev/mapper/cryptdata

# --- Subvolumes --------------------------------------------------------------
mount /dev/mapper/cryptroot1 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount /dev/mapper/cryptdata /mnt
btrfs subvolume create /mnt/@data
umount /mnt

BTRFS_OPTS="rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

mount -o "$BTRFS_OPTS,subvol=@"          /dev/mapper/cryptroot1 /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot,mnt/data}
mount -o "$BTRFS_OPTS,subvol=@home"      /dev/mapper/cryptroot1 /mnt/home
mount -o "$BTRFS_OPTS,subvol=@log"       /dev/mapper/cryptroot1 /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=@pkg"       /dev/mapper/cryptroot1 /mnt/var/cache/pacman/pkg
mount -o "$BTRFS_OPTS,subvol=@snapshots" /dev/mapper/cryptroot1 /mnt/.snapshots
mount -o "$BTRFS_OPTS,subvol=@data"      /dev/mapper/cryptdata  /mnt/mnt/data
mount "$EFI_PART" /mnt/boot

# --- Pacstrap ----------------------------------------------------------------
echo "==> Installing base system"
PKGS=(
  # Base
  base base-devel linux-lts linux-lts-headers linux-firmware
  btrfs-progs intel-ucode mkinitcpio
  # NVIDIA (Pascal Quadro -> proprietary 'nvidia', not nvidia-open)
  nvidia-lts nvidia-utils nvidia-prime libva-nvidia-driver
  # Intel video stack
  mesa intel-media-driver vulkan-intel
  libva-utils vulkan-icd-loader
  # Network / SSH / Bluetooth
  networkmanager network-manager-applet
  bluez bluez-utils blueman
  openssh
  # Power / ACPI / thermal
  acpi acpid tlp tlp-rdw thermald
  # Storage
  util-linux cryptsetup
  # Audio (Pipewire, recommended by Hyprland)
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
  pavucontrol alsa-utils
  # zram
  zram-generator
  # Firmware updates (LVFS works great on ThinkPads)
  fwupd
  # Hyprland + recommended additional software
  hyprland xdg-desktop-portal-hyprland xdg-desktop-portal
  hyprpaper hyprlock hypridle
  waybar wofi
  qt5-wayland qt6-wayland
  hyprpolkitagent
  grim slurp swappy wl-clipboard cliphist
  mako brightnessctl playerctl
  thunar thunar-archive-plugin file-roller gvfs
  alacritty
  # Fonts
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji noto-fonts-cjk
  ttf-liberation
  # Utilities
  sudo nano vim git curl wget rsync man-db man-pages
  reflector pacman-contrib
  xdg-user-dirs xdg-utils
  bash-completion zsh
)

pacstrap -K /mnt "${PKGS[@]}"

# --- fstab -------------------------------------------------------------------
genfstab -U /mnt >> /mnt/etc/fstab

# --- Hand off to chroot ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$SCRIPT_DIR/chroot-config.sh" ]] || err "chroot-config.sh missing next to install.sh"

cp "$SCRIPT_DIR/chroot-config.sh" /mnt/root/chroot-config.sh
chmod +x /mnt/root/chroot-config.sh

arch-chroot /mnt /root/chroot-config.sh \
  "$HOSTNAME" "$USERNAME" "$USER_PASS" "$LUKS1" "$LUKS2" "$LUKS3"

rm -f /mnt/root/chroot-config.sh

echo
echo "============================================================"
echo "  Install complete."
echo "  Run:   umount -R /mnt && \\"
echo "         cryptsetup close cryptroot1 && \\"
echo "         cryptsetup close cryptroot2 && \\"
echo "         cryptsetup close cryptdata   && reboot"
echo
echo "  After reboot, log in and run post-reboot.sh as your user."
echo "============================================================"
