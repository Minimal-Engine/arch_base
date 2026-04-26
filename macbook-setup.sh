#!/bin/bash

# Configuration and User Input
read -p "Enter username: " USERNAME
read -p "Enter hostname: " HOSTNAME
DISK1="/dev/sda"
DISK2="/dev/sdb"

# Partitioning (UEFI/GPT)
sgdisk -Z $DISK1
sgdisk -Z $DISK2
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" $DISK1
sgdisk -n 2:0:0 -t 2:8309 -c 2:"CRYPT" $DISK1
sgdisk -n 1:0:0 -t 1:8309 -c 1:"CRYPT" $DISK2

# Encryption Setup (LUKS2)
echo "Enter LUKS Passphrase:"
cryptsetup luksFormat $DISK1-part2
cryptsetup luksFormat $DISK2-part1
cryptsetup open $DISK1-part2 crypt1
cryptsetup open $DISK2-part1 crypt2

# Btrfs Multi-device Setup (RAID0 for capacity/performance)
mkfs.btrfs -L ARCH -d raid0 -m raid1 /dev/mapper/crypt1 /dev/mapper/crypt2
mount /dev/label/ARCH /mnt

# Subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@pkg
umount /mnt

# Mount with optimization
MOUNT_OPTS="noatime,compress=zstd,ssd,discard=async,subvol="
mount -o ${MOUNT_OPTS}@ /dev/label/ARCH /mnt
mkdir -p /mnt/{boot,home,var/cache/pacman/pkg}
mount -o ${MOUNT_OPTS}@home /dev/label/ARCH /mnt/home
mount -o ${MOUNT_OPTS}@pkg /dev/label/ARCH /mnt/var/cache/pacman/pkg
mount $DISK1-part1 /mnt/boot

# Base System and MacBook Specifics
pacstrap /mnt base linux-lts linux-lts-headers linux-firmware broadcom-wl-dkms btrfs-progs sudo nvi

# Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot Configuration
arch-chroot /mnt /bin/bash <<EOF
# Localization
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
echo "de_DE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=de_DE.UTF-8" > /etc/locale.conf
echo "KEYMAP=de-latin1" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname

# Initramfs for Encryption and Btrfs
sed -i 's/HOOKS=(base udev/HOOKS=(base udev autodetect modconf block encrypt btrfs/' /etc/mkinitcpio.conf
mkinitcpio -p linux-lts

# Bootloader (systemd-boot)
bootctl install
UUID1=$(blkid -s UUID -o value $DISK1-part2)
UUID2=$(blkid -s UUID -o value $DISK2-part1)
echo "title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /initrd-linux-lts.img
options cryptdevice=UUID=\$UUID1:crypt1 cryptdevice=UUID=\$UUID2:crypt2 root=/dev/mapper/crypt1 rootflags=subvol=@ rw" > /boot/loader/entries/arch.conf

# User Management
useradd -m -G wheel -s /bin/zsh $USERNAME
passwd $USERNAME
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
passwd -l root

# SSH Setup
pacman -S --noconfirm openssh
systemctl enable sshd
sudo -u $USERNAME ssh-keygen -t ed25519 -N "" -f /home/$USERNAME/.ssh/id_ed25519

# Drivers and Power Management
pacman -S --noconfirm tlp acpi bluez bluez-utils networkmanager network-manager-applet
systemctl enable tlp bluetooth NetworkManager

# Desktop Environment (Hyprland)
pacman -S --noconfirm hyprland waybar wofi alacritty vivaldi polkit-kde-agent
EOF

umount -R /mnt
echo "Install complete. Reboot."
