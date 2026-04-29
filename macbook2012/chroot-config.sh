#!/usr/bin/env bash
# ============================================================================
# Arch Linux installer — Part 2/2 (post-chroot, runs inside arch-chroot /mnt)
#
# Reads /root/install.env written by install.sh:
#   HOSTNAME, USERNAME, USER_PASS, LUKS1_UUID, LUKS2_UUID
#
# Run standalone (e.g. for re-runs / debugging):
#   arch-chroot /mnt /root/chroot-config.sh
# ============================================================================

set -euo pipefail

warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
err()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }

[[ -f /root/install.env ]] || err "Missing /root/install.env (was Part 1 run?)."
# shellcheck disable=SC1091
source /root/install.env
: "${HOSTNAME:?}" "${USERNAME:?}" "${USER_PASS:?}" "${LUKS1_UUID:?}" "${LUKS2_UUID:?}"

# ---------- Time / locale / keymap -----------------------------------------
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(de_DE.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=de-latin1' > /etc/vconsole.conf

# ---------- Hostname / hosts -----------------------------------------------
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# ---------- pacman.conf tweaks ---------------------------------------------
sed -i 's/^#Color/Color/'                                /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/'  /etc/pacman.conf
sed -i '/^\[multilib\]/,/Include/ s/^#//'                /etc/pacman.conf
pacman -Syu --noconfirm

# ---------- mkinitcpio with sd-encrypt -------------------------------------
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ---------- systemd-boot ---------------------------------------------------
bootctl install

cat > /boot/loader/loader.conf <<LCONF
default  arch.conf
timeout  3
console-mode max
editor   no
LCONF

KOPTS="rd.luks.name=${LUKS1_UUID}=cryptroot rd.luks.name=${LUKS2_UUID}=cryptroot2 rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet"

cat > /boot/loader/entries/arch.conf <<ENT
title   Arch Linux LTS
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options ${KOPTS}
ENT

cat > /boot/loader/entries/arch-fallback.conf <<ENT
title   Arch Linux LTS (fallback)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts-fallback.img
options ${KOPTS}
ENT

# Apple firmware fallback path (some MBP EFIs ignore NVRAM entries).
mkdir -p /boot/EFI/BOOT
cp -f /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI

# Explicit crypttab.initramfs (mirrors the kernel cmdline; sd-encrypt also reads this).
cat > /etc/crypttab.initramfs <<CT
cryptroot  UUID=${LUKS1_UUID}  none  luks,discard
cryptroot2 UUID=${LUKS2_UUID}  none  luks,discard
CT

# ---------- Users ----------------------------------------------------------
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
# wheel = "sudo group" on Arch
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
passwd -l root

# ---------- zram (~half RAM, capped 8 GiB, zstd) ---------------------------
cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
ZRAM

# ---------- TLP -----------------------------------------------------------
cat > /etc/tlp.d/01-laptop.conf <<TLP
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
PLATFORM_PROFILE_ON_AC=balanced
PLATFORM_PROFILE_ON_BAT=low-power
DISK_IOSCHED="mq-deadline mq-deadline"
USB_AUTOSUSPEND=1
RUNTIME_PM_ON_BAT=auto
WIFI_PWR_ON_BAT=on
TLP

# ---------- MacBook 9,2 specifics ------------------------------------------
# fnmode=2: F-keys behave as F-keys; hold fn for media keys.
cat > /etc/modprobe.d/hid_apple.conf <<MB
options hid_apple fnmode=2 iso_layout=0 swap_opt_cmd=0
MB

cat > /etc/modules-load.d/macbook.conf <<ML
applesmc
coretemp
wl
ML

# Force broadcom-wl: blacklist all conflicting open drivers.
cat > /etc/modprobe.d/blacklist-broadcom.conf <<BL
blacklist b43
blacklist b43legacy
blacklist brcmsmac
blacklist bcma
blacklist ssb
BL

# Use intel_backlight, not apple_bl.
cat > /etc/modprobe.d/blacklist-apple-bl.conf <<AB
blacklist apple_bl
AB

# Bluetooth auto-enable on boot.
mkdir -p /etc/bluetooth/main.conf.d
cat > /etc/bluetooth/main.conf.d/00-autoenable.conf <<BT
[Policy]
AutoEnable=true
BT

# I/O schedulers (TLP also sets disk; udev rule is a belt-and-braces).
cat > /etc/udev/rules.d/60-ioschedulers.rules <<UD
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
UD

# vm tunables for zram-first swap.
cat > /etc/sysctl.d/99-perf.conf <<SY
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
SY

# ---------- SSH daemon -----------------------------------------------------
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'                /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# ---------- SSH key for the user -------------------------------------------
KEY_DATE=$(date +%Y%m%d)
KEY_NAME="id_ed25519_${HOSTNAME}_${KEY_DATE}"
sudo -u "$USERNAME" mkdir -p "/home/${USERNAME}/.ssh"
sudo -u "$USERNAME" ssh-keygen -t ed25519 -a 100 -N '' \
    -C "${USERNAME}@${HOSTNAME} ${KEY_DATE}" \
    -f "/home/${USERNAME}/.ssh/${KEY_NAME}"
chmod 700 "/home/${USERNAME}/.ssh"

# ---------- yay (AUR helper) -----------------------------------------------
sudo -u "$USERNAME" bash -c '
    set -e
    cd /tmp
    rm -rf yay-bin
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
'
rm -rf /tmp/yay-bin

# ---------- mbpfan-git (AUR) -----------------------------------------------
sudo -u "$USERNAME" yay -S --noconfirm --needed mbpfan-git || \
    warn "mbpfan-git failed; install manually post-boot."
systemctl enable mbpfan.service 2>/dev/null || true

# ---------- Services -------------------------------------------------------
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable sshd.service
systemctl enable tlp.service
systemctl enable acpid.service
systemctl enable fstrim.timer
systemctl enable systemd-boot-update.service
systemctl mask   systemd-rfkill.service systemd-rfkill.socket   # TLP manages rfkill

# Reflector: weekly mirror refresh (Germany + neighbors).
cat > /etc/xdg/reflector/reflector.conf <<RF
--country Germany,France,Netherlands,Austria
--protocol https
--latest 20
--sort rate
--save /etc/pacman.d/mirrorlist
RF
systemctl enable reflector.timer

echo "[+] Chroot setup done."
