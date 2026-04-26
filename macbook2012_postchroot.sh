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
