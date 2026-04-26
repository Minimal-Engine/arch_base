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
HOSTNAME="archbook"
USERNAME="user"
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

ok "Base system installed"

# -----------------------------------------------------------------------------
# Copy keyfile into chroot
# -----------------------------------------------------------------------------
cp /crypto_keyfile.bin /mnt/crypto_keyfile.bin
chmod 000 /mnt/crypto_keyfile.bin

# -----------------------------------------------------------------------------
# chroot configuration
# -----------------------------------------------------------------------------
header "chroot configuration"

UUID_SDA2=$(blkid -s UUID -o value "$LUKS0_PART")
UUID_SDB1=$(blkid -s UUID -o value "$LUKS1_PART")

arch-chroot /mnt /bin/bash -s "$HOSTNAME" "$USERNAME" "$TIMEZONE" "$LOCALE" \
    "$KEYMAP" "$USER_PASS" "$UUID_SDA2" "$UUID_SDB1" << 'CHROOT'

HOSTNAME="$1"; USERNAME="$2"; TIMEZONE="$3"; LOCALE="$4"
KEYMAP="$5";   USER_PASS="$6"
UUID_SDA2="$7"; UUID_SDB1="$8"

# Write vconsole.conf before anything else — sd-vconsole hook requires it
# Done here before set -euo pipefail so a later failure cannot prevent it
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

set -euo pipefail

# Timezone & clock
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Locale
echo "${LOCALE} UTF-8"  >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf


# Hostname
echo "$HOSTNAME" > /etc/hostname

# User — root account locked, sudo via wheel
useradd -mG wheel,bluetooth "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
passwd -l root
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers


# mkinitcpio
cat > /etc/mkinitcpio.conf << 'EOF'
MODULES=()
BINARIES=()
FILES=(/crypto_keyfile.bin)
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt filesystems fsck)
EOF

# Ensure vconsole.conf exists — guard against any earlier failure
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
mkinitcpio -P
chmod 600 /boot/initramfs-linux-lts*

# Broadcom blacklist
cat > /etc/modprobe.d/broadcom.conf << 'EOF'
blacklist b43
blacklist b43legacy
blacklist ssb
blacklist bcm43xx
blacklist brcm80211
blacklist brcmfmac
blacklist brcmsmac
blacklist bcma
EOF

# GRUB
GRUB_CMDLINE="rd.luks.uuid=${UUID_SDA2} rd.luks.uuid=${UUID_SDB1} rd.luks.key=${UUID_SDB1}=/crypto_keyfile.bin root=/dev/mapper/crypt0 rootflags=subvol=@ rw quiet mem_sleep_default=deep i915.enable_psr=0 i915.enable_rc6=1 i915.enable_fbc=1 intel_pstate=active nmi_watchdog=0 pcie_aspm=force"

cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=4
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE}"
GRUB_ENABLE_CRYPTODISK=y
GRUB_PRELOAD_MODULES="part_gpt part_msdos luks2 cryptodisk"
EOF

grub-install --target=x86_64-efi --efi-directory=/boot     --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# TLP
cat > /etc/tlp.conf << 'EOF'
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0
SATA_LINKPWR_ON_AC=med_power_with_dipm
SATA_LINKPWR_ON_BAT=min_power
DISK_APM_LEVEL_ON_AC=254
DISK_APM_LEVEL_ON_BAT=128
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=off
USB_AUTOSUSPEND=1
START_CHARGE_THRESH_BAT0=40
STOP_CHARGE_THRESH_BAT0=80
EOF

# cpupower
sed -i "s/^#governor=.*/governor='powersave'/" /etc/cpupower.conf 2>/dev/null || \
    echo "governor='powersave'" > /etc/cpupower.conf

# zram
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

# Backlight udev rule
cat > /etc/udev/rules.d/99-backlight.rules << 'EOF'
SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="/usr/bin/brightnessctl set 30%"
SUBSYSTEM=="power_supply", ATTR{online}=="1", RUN+="/usr/bin/brightnessctl set 100%"
EOF

# Suspend fix — XHC1 wakeup
cat > /etc/systemd/system/disable-xhc-wakeup.service << 'EOF'
[Unit]
Description=Disable XHC1 wakeup
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo XHC1 > /proc/acpi/wakeup"

[Install]
WantedBy=multi-user.target
EOF

# logind — lid switch
sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=suspend/' /etc/systemd/logind.conf
sed -i 's/^#HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf

# pacman
sed -i 's/^#Color/Color/'                             /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
sed -i '/^ParallelDownloads/a ILoveCandy'             /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'        /etc/pacman.conf
sed -i '/\[multilib\]/{n;s/^#//}' /etc/pacman.conf
sed -i '/\[multilib\]/s/^#//'     /etc/pacman.conf

# reflector
cat > /etc/xdg/reflector/reflector.conf << 'EOF'
--country Germany
--age 12
--protocol https
--sort rate
--save /etc/pacman.d/mirrorlist
EOF

# Journal size
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf << 'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
EOF

# sysctl hardening
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
net.ipv4.conf.all.rp_filter=1
EOF

# pacman hooks — auto-mount EFI
mkdir -p /etc/pacman.d/hooks

cat > /etc/pacman.d/hooks/mount-boot.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-lts
Target = grub

[Action]
Description = Mounting /boot for kernel/grub update
When = PreTransaction
Exec = /usr/bin/mount /boot
EOF

cat > /etc/pacman.d/hooks/grub-mkconfig.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-lts

[Action]
Description = Regenerating GRUB config after kernel update
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
EOF

cat > /etc/pacman.d/hooks/umount-boot.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-lts
Target = grub

[Action]
Description = Unmounting /boot after kernel/grub update
When = PostTransaction
Exec = /usr/bin/umount /boot
EOF

# SSH daemon config — disable root login, allow only key auth
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/'        /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/'    /etc/ssh/sshd_config

# SSH key generation — name: user-hostname-date
SSH_DATE=$(date +%Y%m%d)
SSH_KEYNAME="${USERNAME}-${HOSTNAME}-${SSH_DATE}"
SSH_DIR="/home/${USERNAME}/.ssh"
mkdir -p "$SSH_DIR"
ssh-keygen -t ed25519 -f "${SSH_DIR}/${SSH_KEYNAME}" -C "${SSH_KEYNAME}" -N ""
chmod 700 "$SSH_DIR"
chmod 600 "${SSH_DIR}/${SSH_KEYNAME}"
chmod 644 "${SSH_DIR}/${SSH_KEYNAME}.pub"
chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"

# Snapper
snapper -c root create-config /
snapper -c home  create-config /home

# Enable services
systemctl enable NetworkManager
systemctl enable acpid
systemctl enable sshd
systemctl enable bluetooth
systemctl enable tlp
systemctl enable thermald
systemctl enable cpupower
systemctl enable earlyoom
systemctl enable disable-xhc-wakeup
systemctl enable reflector.timer
systemctl enable fstrim.timer
systemctl enable btrfs-scrub@-.timer
systemctl enable btrfs-scrub@home.timer
systemctl enable ufw
ufw default deny incoming
ufw enable

echo "chroot done"
CHROOT

ok "chroot configuration complete"

# -----------------------------------------------------------------------------
# Finalise
# -----------------------------------------------------------------------------
header "Done"

umount -R /mnt
cryptsetup close crypt1
cryptsetup close crypt0

echo -e "\n${GREEN}${BOLD}Installation complete. Remove installation media and reboot.${NC}"
echo -e "  Boot entry:   ${BOLD}Arch Linux LTS${NC}"
echo -e "  Bluetooth:    bluetoothctl"
echo -e "  Post-install: install yay for AUR access\n"
