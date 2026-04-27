#!/usr/bin/env bash
# Arch Linux installer for 2012 non-retina MacBook Pro (9,1 / 9,2)
# Two SSDs, LUKS2 + Btrfs spanning both, systemd-boot, linux-lts.
# Run from the Arch ISO live environment, booted in EFI mode.
#
# Place install.sh and chroot-config.sh in the same directory, then:
#   bash install.sh

set -euo pipefail

err() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root."
[[ -d /sys/firmware/efi ]] || err "Not booted in EFI mode. On 2012 MBP, hold Option/Alt at boot and pick the EFI USB."

# --- Prompt for user input ---------------------------------------------------
echo "Available block devices:"
lsblk -dn -o NAME,SIZE,MODEL | grep -v -E 'loop|sr0'
echo

read -rp "Disk 1 (will hold EFI + part of root, e.g. /dev/sda): " DISK1
read -rp "Disk 2 (entire disk for root span, e.g. /dev/sdb):     " DISK2
read -rp "Hostname:  " HOSTNAME
read -rp "Username:  " USERNAME

while :; do
  read -rsp "User password: " USER_PASS; echo
  read -rsp "Confirm:       " USER_PASS2; echo
  [[ "$USER_PASS" == "$USER_PASS2" ]] && break
  echo "Mismatch, try again."
done

while :; do
  read -rsp "LUKS passphrase (used for BOTH disks): " LUKS_PASS; echo
  read -rsp "Confirm:                                " LUKS_PASS2; echo
  [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
  echo "Mismatch, try again."
done

[[ -b "$DISK1" ]] || err "$DISK1 is not a block device"
[[ -b "$DISK2" ]] || err "$DISK2 is not a block device"
[[ "$DISK1" != "$DISK2" ]] || err "Disks must be different"

echo
echo "============================================================"
echo "  THIS WILL ERASE EVERYTHING ON $DISK1 AND $DISK2"
echo "============================================================"
read -rp "Type YES (uppercase) to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || err "Aborted."

# --- Helpers -----------------------------------------------------------------
part_name() {
  # Append 'p' for nvme/mmcblk style names, otherwise nothing
  local d=$1 n=$2
  if [[ "$d" =~ (nvme|mmcblk|loop) ]]; then echo "${d}p${n}"; else echo "${d}${n}"; fi
}

# --- Time --------------------------------------------------------------------
timedatectl set-ntp true

# --- Wipe + partition --------------------------------------------------------
echo "==> Partitioning"
wipefs -af "$DISK1" "$DISK2"
sgdisk -Zo "$DISK1"
sgdisk -Zo "$DISK2"

# DISK1: 512 MiB ESP + remainder LUKS
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:EFI         "$DISK1"
sgdisk -n 2:0:0       -t 2:8309 -c 2:cryptroot1  "$DISK1"

# DISK2: full disk LUKS
sgdisk -n 1:0:0       -t 1:8309 -c 1:cryptroot2  "$DISK2"

partprobe "$DISK1" "$DISK2"
sleep 2

EFI_PART=$(part_name "$DISK1" 1)
LUKS1=$(part_name   "$DISK1" 2)
LUKS2=$(part_name   "$DISK2" 1)

# --- Format ESP --------------------------------------------------------------
echo "==> Formatting ESP at $EFI_PART"
mkfs.fat -F32 -n EFI "$EFI_PART"

# --- LUKS2 on both root partitions ------------------------------------------
echo "==> Creating LUKS2 containers"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id \
  --key-file - "$LUKS1"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id \
  --key-file - "$LUKS2"

echo -n "$LUKS_PASS" | cryptsetup open --allow-discards --key-file - "$LUKS1" cryptroot1
echo -n "$LUKS_PASS" | cryptsetup open --allow-discards --key-file - "$LUKS2" cryptroot2

# --- Btrfs spanning both unlocked devices ------------------------------------
# data=single (concatenation across devices, ~512 GiB usable)
# metadata=raid1 (each metadata block on both devices for redundancy)
echo "==> Creating Btrfs across both devices"
mkfs.btrfs -f -L arch -d single -m raid1 \
  /dev/mapper/cryptroot1 /dev/mapper/cryptroot2

# --- Subvolumes --------------------------------------------------------------
mount /dev/mapper/cryptroot1 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

BTRFS_OPTS="rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

mount -o "$BTRFS_OPTS,subvol=@"          /dev/mapper/cryptroot1 /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot}
mount -o "$BTRFS_OPTS,subvol=@home"      /dev/mapper/cryptroot1 /mnt/home
mount -o "$BTRFS_OPTS,subvol=@log"       /dev/mapper/cryptroot1 /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=@pkg"       /dev/mapper/cryptroot1 /mnt/var/cache/pacman/pkg
mount -o "$BTRFS_OPTS,subvol=@snapshots" /dev/mapper/cryptroot1 /mnt/.snapshots
mount "$EFI_PART" /mnt/boot

# --- Pacstrap ----------------------------------------------------------------
echo "==> Installing base system"
PKGS=(
  # Base
  base base-devel linux-lts linux-lts-headers linux-firmware
  btrfs-progs intel-ucode mkinitcpio
  # Network / SSH / Bluetooth
  networkmanager network-manager-applet
  bluez bluez-utils
  openssh
  # Power / ACPI
  acpi acpid tlp tlp-rdw
  # Storage
  util-linux cryptsetup
  # Audio (Pipewire, recommended by Hyprland)
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
  pavucontrol alsa-utils
  # zram
  zram-generator
  # Proprietary Broadcom WLAN (BCM4331 in MBP9,x) -- LTS variant
  broadcom-wl-dkms
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

# --- Hand off to chroot script ----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$SCRIPT_DIR/chroot-config.sh" ]] || err "chroot-config.sh missing next to install.sh"

cp "$SCRIPT_DIR/chroot-config.sh" /mnt/root/chroot-config.sh
chmod +x /mnt/root/chroot-config.sh

arch-chroot /mnt /root/chroot-config.sh \
  "$HOSTNAME" "$USERNAME" "$USER_PASS" "$LUKS1" "$LUKS2"

rm -f /mnt/root/chroot-config.sh

# --- Done --------------------------------------------------------------------
echo
echo "============================================================"
echo "  Install complete."
echo "  Run:   umount -R /mnt && cryptsetup close cryptroot1 && \\"
echo "         cryptsetup close cryptroot2 && reboot"
echo
echo "  After reboot, log in and run post-reboot.sh as your user"
echo "  to install Vivaldi and mbpfan from the AUR."
echo "============================================================"
