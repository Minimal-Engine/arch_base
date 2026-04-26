#!/usr/bin/env bash
# =============================================================================
# Arch Linux — MacBook Pro 2012
# Dual SSD · LUKS2 · Btrfs · GRUB · linux-lts · Bluetooth · No GUI
# =============================================================================
# Run from Arch live ISO as root.
# Usage: bash arch-install.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colours
# -----------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header(){ echo -e "\n${BOLD}=== $* ===${NC}"; }

# -----------------------------------------------------------------------------
# Configuration — edit before running
# -----------------------------------------------------------------------------
DISK1="/dev/sda"
DISK2="/dev/sdb"
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
TIMEZONE="Europe/Berlin"
LOCALE="de_DE.UTF-8"
KEYMAP="de-latin1-nodeadkeys"
SSID=""          # leave empty to skip WiFi setup in live env
WIFI_PASS=""

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
header "Pre-flight checks"

[[ $EUID -eq 0 ]] || die "Must run as root"
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode"

for disk in "$DISK1" "$DISK2"; do
    [[ -b "$disk" ]] || die "Disk $disk not found — check DISK1/DISK2 variables"
done

info "Disks: $DISK1  $DISK2"
info "Hostname: $HOSTNAME  User: $USERNAME  TZ: $TIMEZONE"

echo -e "${RED}${BOLD}This will ERASE all data on $DISK1 and $DISK2.${NC}"
read -rp "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || die "Aborted"

# -----------------------------------------------------------------------------
# Passwords
# -----------------------------------------------------------------------------
header "Passwords"

read -rsp "LUKS passphrase: "          LUKS_PASS;  echo
read -rsp "LUKS passphrase (confirm): " LUKS_CONF;  echo
[[ "$LUKS_PASS" == "$LUKS_CONF" ]] || die "LUKS passphrases do not match"

read -rsp "Password for $USERNAME: "   USER_PASS;  echo

# -----------------------------------------------------------------------------
# WiFi (live env)
# -----------------------------------------------------------------------------
header "Network"

if [[ -n "$SSID" ]]; then
    info "Loading Broadcom module"
    rmmod b43 ssb bcma brcmfmac brcmsmac 2>/dev/null || true
    modprobe wl
    rfkill unblock all
    iwctl --passphrase "$WIFI_PASS" station wlan0 connect "$SSID"
    sleep 3
    ping -c 2 archlinux.org >/dev/null || die "No network connectivity"
    ok "WiFi connected"
else
    ping -c 2 archlinux.org >/dev/null || die "No network — set SSID/WIFI_PASS or connect manually"
    ok "Network OK"
fi

# -----------------------------------------------------------------------------
# Keymap + time
# -----------------------------------------------------------------------------
loadkeys "$KEYMAP"
timedatectl set-ntp true

# -----------------------------------------------------------------------------
# Partitioning
# -----------------------------------------------------------------------------
header "Partitioning"

info "Wiping $DISK1"
sgdisk --zap-all "$DISK1"
sgdisk --new=1:0:+1G   --typecode=1:ef00 \
       --new=2:0:0      --typecode=2:8309 \
       --change-name=1:EFI --change-name=2:LUKS0 "$DISK1"

info "Wiping $DISK2"
sgdisk --zap-all "$DISK2"
sgdisk --new=1:0:0 --typecode=1:8309 \
       --change-name=1:LUKS1 "$DISK2"

partprobe "$DISK1" "$DISK2"
udevadm settle
ok "Partitions created"

# -----------------------------------------------------------------------------
# LUKS
# -----------------------------------------------------------------------------
header "LUKS Encryption"

EFI_PART="${DISK1}1"
LUKS0_PART="${DISK1}2"
LUKS1_PART="${DISK2}1"

info "Formatting $LUKS0_PART"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$LUKS0_PART" -

info "Formatting $LUKS1_PART"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$LUKS1_PART" -

info "Opening LUKS devices"
echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$LUKS0_PART" crypt0
echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$LUKS1_PART" crypt1

info "Generating keyfile for crypt1"
dd if=/dev/urandom bs=512 count=4 of=/crypto_keyfile.bin 2>/dev/null
chmod 000 /crypto_keyfile.bin
# -d - authorises with existing passphrase from stdin; keyfile is the new key to add
echo -n "$LUKS_PASS" | cryptsetup luksAddKey --batch-mode -d - "$LUKS1_PART" /crypto_keyfile.bin
ok "LUKS ready"

# -----------------------------------------------------------------------------
# Btrfs
# -----------------------------------------------------------------------------
header "Btrfs"

mkfs.btrfs -L arch -d raid0 -m raid1 /dev/mapper/crypt0 /dev/mapper/crypt1

MOUNT_OPTS="noatime,compress=zstd"

mount -o "$MOUNT_OPTS" /dev/mapper/crypt0 /mnt

for sv in @ @home @snapshots; do
    btrfs subvolume create "/mnt/$sv"
done

umount /mnt

mount -o "${MOUNT_OPTS},subvol=@"          /dev/mapper/crypt0 /mnt
mkdir -p /mnt/{home,.snapshots,boot}
mount -o "${MOUNT_OPTS},subvol=@home"      /dev/mapper/crypt0 /mnt/home
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/crypt0 /mnt/.snapshots

mkfs.fat -F32 "$EFI_PART"
mount "$EFI_PART" /mnt/boot

ok "Btrfs mounted"

# -----------------------------------------------------------------------------
# Install base
# -----------------------------------------------------------------------------
header "pacstrap"

pacstrap /mnt \
    base linux-lts linux-firmware \
    btrfs-progs intel-ucode \
    networkmanager sudo vim \
    broadcom-wl-dkms linux-lts-headers \
    bluez bluez-utils \
    acpi acpid \
    brightnessctl tlp tlp-rdw thermald \
    cpupower earlyoom zram-generator \
    reflector snapper snap-pac \
    openssh \
    grub efibootmgr \
    ufw git base-devel

genfstab -U /mnt >> /mnt/etc/fstab

# Mark EFI as noauto in fstab
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
sed -i "s|UUID=${EFI_UUID}.*vfat.*defaults|UUID=${EFI_UUID}  /boot  vfat  noauto,noatime,fmask=0137,dmask=0027|" /mnt/etc/fstab

# -----------------------------------------------------------------------------
# Copy keyfile into chroot
# -----------------------------------------------------------------------------
cp /crypto_keyfile.bin /mnt/crypto_keyfile.bin
chmod 000 /mnt/crypto_keyfile.bin

ok "Base system installed"
