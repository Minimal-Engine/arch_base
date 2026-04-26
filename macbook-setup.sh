#!/bin/bash

# Configuration
loadkeys de-latin1
timedatectl set-ntp true

read -p "Enter username: " USERNAME
read -p "Enter hostname: " HOSTNAME

# Disk Partitioning (sda & sdb)
# Creating a 512MB EFI on sda, rest for LUKS. sdb fully LUKS.
sgdisk -Z /dev/sda
sgdisk -Z /dev/sdb
sgdisk -n 1:0:+512M -t 1:ef00 /dev/sda
sgdisk -n 2:0:0 -t 2:8309 /dev/sda
sgdisk -n 1:0:0 -t 1:8309 /dev/sdb

# Encryption Setup
echo "Setting up LUKS on sda2..."
cryptsetup luksFormat /dev/sda2
echo "Setting up LUKS on sdb1..."
cryptsetup luksFormat /dev/sdb1

cryptsetup open /dev/sda2 crypt_sda
cryptsetup open /dev/sdb1 crypt_sdb

# Btrfs RAID0 setup (Spanning both disks)
mkfs.btrfs -L ARCH_ROOT -d raid0 -m raid1 /dev/mapper/crypt_sda /dev/mapper/crypt_sdb
mount /dev/btrfs-control /mnt # Ensure control node exists
mount /dev/mapper/crypt_sda /mnt

# Create Subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

# Mount with SSD optimizations
MOUNT_OPTS="noatime,compress=zstd,ssd,discard=async,subvol="
mount -o ${MOUNT_OPTS}@ /dev/mapper/crypt_sda /mnt
mkdir -p /mnt/{home,.snapshots,boot}
mount -o ${MOUNT_OPTS}@home /dev/mapper/crypt_sda /mnt/home
mount -o ${MOUNT_OPTS}@snapshots /dev/mapper/crypt_sda /mnt/.snapshots
mount /dev/sda1 /mnt/boot

# Install Base System
pacstrap /mnt base base-devel linux-lts linux-lts-headers linux-firmware \
btrfs-progs broadcom-wl-dkms git vim sudo alacritty networkmanager \
network-manager-applet bluez bluez-utils hyprland waybar wofi mako \
xdg-desktop-portal-hyprland vivaldi openssh tlp acpi zram-generator

# Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot configuration
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
echo "de_DE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=de_DE.UTF-8" > /etc/locale.conf
echo "KEYMAP=de-latin1" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname

# Initramfs for Encryption and Btrfs
sed -i 's/HOOKS=(base udev/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -p linux-lts

# User setup
useradd -m -G wheel -s /bin/zsh $USERNAME
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers
passwd -l root

# SSH Key Generation
DATE=\$(date +%Y%m%d)
KEYNAME="/home/$USERNAME/.ssh/id_ed25519_\${HOSTNAME}_\${DATE}"
mkdir -p /home/$USERNAME/.ssh
ssh-keygen -t ed25519 -f "\$KEYNAME" -C "$USERNAME@$HOSTNAME"
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

# Bootloader (systemd-boot)
bootctl install
UUID1=\$(blkid -s UUID -o value /dev/sda2)
UUID2=\$(blkid -s UUID -o value /dev/sdb1)

echo "default arch" > /boot/loader/loader.conf
cat <<EOT > /boot/loader/entries/arch.conf
title Arch Linux (LTS)
linux /vmlinuz-linux-lts
initrd /initrd-linux-lts.img
options cryptdevice=UUID=\$UUID1:crypt_sda cryptdevice=UUID=\$UUID2:crypt_sdb root=/dev/mapper/crypt_sda rootflags=subvol=@ rw
EOT

# Services & Optimizations
systemctl enable NetworkManager bluetooth sshd tlp fstrim.timer
echo -e "[zram0]\nzram-size = min(ram / 2, 4096)" > /etc/systemd/zram-generator.conf

# MacBook specific: Prevent lid wake issues and fix backlight
echo "options drm_info_cap=1" > /etc/modprobe.d/i915.conf
EOF

umount -R /mnt
swapoff -a
echo "Installation complete. Reboot and set user password."
