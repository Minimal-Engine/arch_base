#!/bin/bash
set -e

echo "==== Arch Linux Dual-SSD Encrypted Setup (Improved) ===="

# --- User input ---
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME

echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL

read -rp "Enter first SSD (e.g. /dev/sda): " DISK1
read -rp "Enter second SSD (e.g. /dev/sdb): " DISK2

# --- Partitioning ---
for DISK in $DISK1 $DISK2; do
    parted -s $DISK mklabel gpt
    parted -s $DISK mkpart ESP fat32 1MiB 513MiB
    parted -s $DISK set 1 esp on
    parted -s $DISK mkpart primary 513MiB 100%
done

mkfs.fat -F32 ${DISK1}1

# --- Encryption ---
cryptsetup luksFormat ${DISK1}2
cryptsetup luksFormat ${DISK2}2

cryptsetup open ${DISK1}2 crypt1
cryptsetup open ${DISK2}2 crypt2

# --- Btrfs RAID1 ---
mkfs.btrfs -d raid1 -m raid1 /dev/mapper/crypt1 /dev/mapper/crypt2

mount /dev/mapper/crypt1 /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

umount /mnt

mount -o noatime,compress=zstd,ssd,subvol=@ /dev/mapper/crypt1 /mnt
mkdir -p /mnt/{home,.snapshots,boot}

mount -o noatime,compress=zstd,ssd,subvol=@home /dev/mapper/crypt1 /mnt/home
mount -o noatime,compress=zstd,ssd,subvol=@snapshots /dev/mapper/crypt1 /mnt/.snapshots

mount ${DISK1}1 /mnt/boot

# --- Install packages ---
pacstrap /mnt base linux-lts linux-lts-headers linux-firmware intel-ucode \
    btrfs-progs sudo vim git base-devel \
    networkmanager network-manager-applet \
    bluez bluez-utils openssh \
    tlp acpi acpid \
    zram-generator \
    snapper snap-pac grub-btrfs \
    mesa vulkan-intel xf86-video-intel \
    alacritty \
    hyprland waybar wofi grim slurp wl-clipboard xdg-desktop-portal-hyprland \
    polkit-gnome \
    vivaldi \
    broadcom-wl-dkms \
    mbpfan

# --- fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot ---
arch-chroot /mnt /bin/bash <<EOF

# Time & locale
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

echo "de_DE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=de_DE.UTF-8" > /etc/locale.conf
echo "KEYMAP=de-latin1" > /etc/vconsole.conf

# Host
echo "$HOSTNAME" > /etc/hostname

cat <<EOT >> /etc/hosts
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOT

# Initramfs (better config)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# systemd-boot
bootctl install

ROOT_UUID=\$(blkid -s UUID -o value ${DISK1}2)

cat <<EOT > /boot/loader/entries/arch.conf
title Arch Linux (LTS)
linux /vmlinuz-linux-lts
initrd /intel-ucode.img
initrd /initramfs-linux-lts.img
options rd.luks.name=\$ROOT_UUID=crypt1 root=/dev/mapper/crypt1 rootflags=subvol=@ rw quiet splash
EOT

echo "default arch.conf" > /boot/loader/loader.conf

# Services
systemctl enable NetworkManager bluetooth sshd tlp acpid fstrim.timer

# zram
cat <<EOT > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOT

# Snapper setup
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount -a

systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# grub-btrfs (for snapshots in boot)
systemctl enable grub-btrfs.path

# User
useradd -m -G wheel -s /bin/bash $USERNAME
passwd $USERNAME

echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

passwd -l root

# SSH keys
sudo -u $USERNAME mkdir -p /home/$USERNAME/.ssh
DATE=\$(date +%Y%m%d)
sudo -u $USERNAME ssh-keygen -t ed25519 -f /home/$USERNAME/.ssh/id_ed25519_${HOSTNAME}_\$DATE -N ""

# Hyprland config
mkdir -p /home/$USERNAME/.config/hypr
cat <<EOT > /home/$USERNAME/.config/hypr/hyprland.conf
exec-once = waybar &
exec-once = nm-applet &

monitor=,preferred,auto,1

input {
    kb_layout = de
}

bind = SUPER, RETURN, exec, alacritty
bind = SUPER, D, exec, wofi --show drun
bind = SUPER, Q, killactive
EOT

chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# MacBook tuning
systemctl enable mbpfan

echo "options b43 pio=0 qos=0" > /etc/modprobe.d/broadcom.conf

# Power tuning
echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf

EOF

echo "==== INSTALL COMPLETE ===="
echo "Reboot and enjoy."
