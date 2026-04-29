#!/usr/bin/env bash
# ============================================================================
# Arch Linux installer — Part 1/2 (pre-chroot)
# Target: MacBook Pro 9,2 (mid-2012 non-retina 13", no dGPU), two SSDs.
#
# Run from the official Arch ISO (UEFI). Network must be up.
# Expects chroot-config.sh to live in the same directory.
#
# Layout:
#   DISK1: ESP (1 GiB, FAT32) + LUKS2 -> btrfs member 1 (cryptroot)
#   DISK2: LUKS2                       -> btrfs member 2 (cryptroot2)
#   btrfs: -d single -m raid1 (full capacity, metadata mirrored)
#   Same LUKS passphrase on both -> sd-encrypt caches; one prompt at boot.
# ============================================================================

set -euo pipefail

log()  { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
err()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
CHROOT_SCRIPT="${SCRIPT_DIR}/chroot-config.sh"

# ---------- Sanity checks --------------------------------------------------
[[ $EUID -eq 0 ]]                  || err "Run as root."
[[ -d /sys/firmware/efi/efivars ]] || err "Not booted in UEFI mode."
[[ -f "$CHROOT_SCRIPT" ]]          || err "Missing $CHROOT_SCRIPT next to this script."
ping -c1 -W2 archlinux.org >/dev/null 2>&1 || err "No network. Connect first."

# ---------- Prompts --------------------------------------------------------
read -rp "Hostname: "  HOSTNAME
[[ -n "$HOSTNAME" ]] || err "Hostname required."
read -rp "Username: "  USERNAME
[[ -n "$USERNAME" ]] || err "Username required."

while :; do
    read -rsp "User password: " USER_PASS;  echo
    read -rsp "Confirm:        " USER_PASS2; echo
    [[ "$USER_PASS" == "$USER_PASS2" ]] && break
    warn "Passwords differ. Retry."
done

while :; do
    read -rsp "LUKS passphrase (used for both disks): " LUKS_PASS;  echo
    read -rsp "Confirm:                                " LUKS_PASS2; echo
    [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
    warn "Passphrases differ. Retry."
done

echo
lsblk -dno NAME,SIZE,MODEL | grep -v -E '^(loop|sr)' || true
echo
read -rp "Primary disk   (ESP + root, e.g. /dev/sda): " DISK1
read -rp "Secondary disk (root member 2,    /dev/sdb): " DISK2
[[ -b "$DISK1" && -b "$DISK2" ]] || err "Disks must be block devices."
[[ "$DISK1" != "$DISK2" ]]      || err "Disks must differ."

echo
warn "ALL DATA on $DISK1 and $DISK2 will be DESTROYED."
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || err "Aborted."

# Helper: build partition node name (handles nvme/mmc suffix)
partname() {
    case "$1" in
        *nvme*|*mmcblk*) echo "${1}p${2}" ;;
        *)               echo "${1}${2}"  ;;
    esac
}

# ---------- Time / mirrors -------------------------------------------------
log "Syncing clock and refreshing keyring."
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring

# ---------- Partitioning ---------------------------------------------------
log "Wiping and partitioning $DISK1 and $DISK2."
wipefs -af  "$DISK1" "$DISK2"
sgdisk --zap-all "$DISK1"
sgdisk --zap-all "$DISK2"

sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:"ESP"        "$DISK1"
sgdisk -n 2:0:0     -t 2:8309 -c 2:"cryptroot"  "$DISK1"
sgdisk -n 1:0:0     -t 1:8309 -c 1:"cryptroot2" "$DISK2"

partprobe "$DISK1" "$DISK2"; sleep 2

ESP=$(partname   "$DISK1" 1)
LUKS1=$(partname "$DISK1" 2)
LUKS2=$(partname "$DISK2" 1)

# ---------- ESP + LUKS -----------------------------------------------------
log "Formatting ESP."
mkfs.fat -F32 -n ESP "$ESP"

log "Creating LUKS2 containers."
luks_args=(--type luks2 --batch-mode --cipher aes-xts-plain64 --key-size 512
           --hash sha256 --iter-time 4000 --pbkdf argon2id --use-urandom)

printf '%s' "$LUKS_PASS" | cryptsetup luksFormat "${luks_args[@]}" --key-file=- "$LUKS1"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat "${luks_args[@]}" --key-file=- "$LUKS2"

log "Opening LUKS containers."
printf '%s' "$LUKS_PASS" | cryptsetup open --allow-discards --key-file=- "$LUKS1" cryptroot
printf '%s' "$LUKS_PASS" | cryptsetup open --allow-discards --key-file=- "$LUKS2" cryptroot2

# ---------- btrfs across both decrypted devices ----------------------------
log "Creating btrfs spanning both LUKS volumes."
mkfs.btrfs -f -L arch -d single -m raid1 \
    /dev/mapper/cryptroot /dev/mapper/cryptroot2

# Subvolumes
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@var_tmp
umount /mnt

MOUNT_OPTS="noatime,compress=zstd:3,ssd,space_cache=v2,discard=async"

mount -o "${MOUNT_OPTS},subvol=@"           /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache,var/tmp}
mount -o "${MOUNT_OPTS},subvol=@home"       /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@snapshots"  /dev/mapper/cryptroot /mnt/.snapshots
mount -o "${MOUNT_OPTS},subvol=@var_log"    /dev/mapper/cryptroot /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@var_cache"  /dev/mapper/cryptroot /mnt/var/cache
mount -o "${MOUNT_OPTS},subvol=@var_tmp"    /dev/mapper/cryptroot /mnt/var/tmp
chattr +C /mnt/var/cache /mnt/var/tmp || true

mount "$ESP" /mnt/boot

# ---------- Pacstrap base system -------------------------------------------
log "Running pacstrap (this takes a while)."
pacstrap -K /mnt \
    base base-devel linux-lts linux-lts-headers linux-firmware intel-ucode \
    btrfs-progs cryptsetup efibootmgr \
    networkmanager network-manager-applet nm-connection-editor \
    bluez bluez-utils blueman \
    tlp tlp-rdw acpi acpid \
    broadcom-wl-dkms \
    openssh sudo git \
    zram-generator \
    vim nano less htop man-db man-pages \
    pacman-contrib reflector iputils inetutils usbutils pciutils \
    bash-completion

genfstab -U /mnt >> /mnt/etc/fstab

# ---------- Write env file + chroot script for Part 2 ----------------------
LUKS1_UUID=$(blkid -s UUID -o value "$LUKS1")
LUKS2_UUID=$(blkid -s UUID -o value "$LUKS2")

install -d -m 700 /mnt/root
umask 077
cat > /mnt/root/install.env <<EOF
HOSTNAME='${HOSTNAME}'
USERNAME='${USERNAME}'
USER_PASS='${USER_PASS}'
LUKS1_UUID='${LUKS1_UUID}'
LUKS2_UUID='${LUKS2_UUID}'
EOF

install -m 755 "$CHROOT_SCRIPT" /mnt/root/chroot-config.sh

log "Entering chroot to run Part 2."
arch-chroot /mnt /root/chroot-config.sh

# Wipe credentials.
shred -u /mnt/root/install.env 2>/dev/null || rm -f /mnt/root/install.env
rm -f /mnt/root/chroot-config.sh

# ---------- Done -----------------------------------------------------------
log "Installation complete."
echo
log "Public SSH key:"
cat /mnt/home/"$USERNAME"/.ssh/id_ed25519_"${HOSTNAME}"_*.pub || true
echo
log "Finish with:"
echo "    umount -R /mnt"
echo "    cryptsetup close cryptroot"
echo "    cryptsetup close cryptroot2"
echo "    reboot"
