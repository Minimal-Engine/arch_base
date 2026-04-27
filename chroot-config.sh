#!/usr/bin/env bash
# Run inside arch-chroot. Invoked by install.sh.
# Args: HOSTNAME USERNAME USER_PASS LUKS1 LUKS2

set -euo pipefail

HOSTNAME=$1
USERNAME=$2
USER_PASS=$3
LUKS1=$4
LUKS2=$5

# --- Time, locale, keymap ----------------------------------------------------
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/'   /etc/locale.gen
sed -i 's/^#\(de_DE.UTF-8 UTF-8\)/\1/'   /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# German keyboard for the TTY (vconsole). Hyprland gets its own kb_layout below.
cat > /etc/vconsole.conf <<EOF
KEYMAP=de-latin1
FONT=lat9w-16
EOF

# --- Hostname / hosts --------------------------------------------------------
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# --- mkinitcpio (sd-encrypt for two LUKS volumes) ----------------------------
# 'systemd' replaces 'udev'; 'sd-encrypt' handles multiple devices via crypttab.initramfs.
# 'microcode' hook auto-includes intel-ucode (no separate initrd line needed).
sed -i 's|^MODULES=.*|MODULES=(btrfs i915)|' /etc/mkinitcpio.conf
sed -i 's|^HOOKS=.*|HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)|' /etc/mkinitcpio.conf

UUID1=$(blkid -s UUID -o value "$LUKS1")
UUID2=$(blkid -s UUID -o value "$LUKS2")

# crypttab.initramfs: same passphrase on both => systemd caches and reuses.
cat > /etc/crypttab.initramfs <<EOF
cryptroot1 UUID=${UUID1} - luks,discard
cryptroot2 UUID=${UUID2} - luks,discard
EOF

mkinitcpio -P

# --- systemd-boot ------------------------------------------------------------
# ESP is mounted at /boot, so kernel images live directly on the ESP.
bootctl install

cat > /boot/loader/loader.conf <<EOF
default  arch-lts.conf
timeout  3
console-mode max
editor   no
EOF

ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot1)

# acpi_osi tweak helps ACPI quirks on Apple firmware.
KCMD="rd.luks.name=${UUID1}=cryptroot1 rd.luks.name=${UUID2}=cryptroot2 \
rd.luks.options=discard \
root=UUID=${ROOT_UUID} rootflags=subvol=@ \
rw quiet loglevel=3 acpi_osi=! acpi_osi=\"Darwin\" acpi_backlight=vendor"

mkdir -p /boot/loader/entries
cat > /boot/loader/entries/arch-lts.conf <<EOF
title    Arch Linux LTS
linux    /vmlinuz-linux-lts
initrd   /initramfs-linux-lts.img
options  ${KCMD}
EOF

cat > /boot/loader/entries/arch-lts-fallback.conf <<EOF
title    Arch Linux LTS (fallback)
linux    /vmlinuz-linux-lts
initrd   /initramfs-linux-lts-fallback.img
options  ${KCMD}
EOF

# Auto-update systemd-boot when the systemd package is upgraded.
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/95-systemd-boot.hook <<'EOF'
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
EOF

# --- User --------------------------------------------------------------------
# 'wheel' is Arch's sudo group.
groupadd -f wheel
useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd

# Enable sudo for wheel
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
visudo -cf /etc/sudoers >/dev/null

# Disable root account (lock password, no shell login)
passwd -l root
usermod -s /usr/sbin/nologin root

# --- SSH key for the user (filename includes hostname + creation date) ------
DATE=$(date +%Y%m%d)
USER_HOME="/home/${USERNAME}"
KEYNAME="id_ed25519_${HOSTNAME}_${DATE}"

install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.ssh"
sudo -u "$USERNAME" ssh-keygen -t ed25519 -a 100 -N "" \
  -C "${USERNAME}@${HOSTNAME} ${DATE}" \
  -f "$USER_HOME/.ssh/${KEYNAME}"

# --- sshd hardening ----------------------------------------------------------
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
EOF

# --- ZRAM --------------------------------------------------------------------
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# --- TRIM --------------------------------------------------------------------
# discard=async is set in fstab via genfstab inheritance + LUKS 'discard' is set
# in crypttab.initramfs. fstrim.timer is a weekly safety net.
systemctl enable fstrim.timer

# --- Services ----------------------------------------------------------------
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sshd
systemctl enable tlp
systemctl enable acpid
systemctl enable systemd-timesyncd
systemctl enable reflector.timer

# --- MacBook optimizations ---------------------------------------------------
# Blacklist conflicting Broadcom open drivers (we use proprietary 'wl').
cat > /etc/modprobe.d/blacklist-broadcom.conf <<EOF
blacklist b43
blacklist bcma
blacklist ssb
blacklist brcmsmac
blacklist brcmfmac
EOF

# Apple keyboard: F-keys behave as F1..F12 by default; ANSI layout fix off.
cat > /etc/modprobe.d/hid_apple.conf <<EOF
options hid_apple fnmode=2
options hid_apple iso_layout=0
options hid_apple swap_opt_cmd=0
EOF

# Bluetooth quirk on some Apple BCM USB chips
cat > /etc/modprobe.d/macbook-bt.conf <<EOF
options btusb enable_autosuspend=n
EOF

# Pre-load applesmc (fan/temp sensors)
cat > /etc/modules-load.d/applesmc.conf <<EOF
applesmc
coretemp
EOF

# TLP defaults tuned for SATA SSDs + battery life
cat > /etc/tlp.conf.d/00-macbook.conf <<EOF
TLP_ENABLE=1
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
PLATFORM_PROFILE_ON_AC=performance
PLATFORM_PROFILE_ON_BAT=low-power
DISK_DEVICES="sda sdb"
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="128 128"
SATA_LINKPWR_ON_AC=med_power_with_dipm
SATA_LINKPWR_ON_BAT=min_power
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
USB_AUTOSUSPEND=1
EOF

# --- reflector ---------------------------------------------------------------
cat > /etc/xdg/reflector/reflector.conf <<EOF
--country Germany,France,Netherlands,Austria
--protocol https
--latest 20
--sort rate
--save /etc/pacman.d/mirrorlist
EOF

# --- Pacman tweaks -----------------------------------------------------------
sed -i 's/^#Color/Color/'                              /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf

# --- Minimal Hyprland config (German layout, alacritty as terminal) ---------
HYPR_DIR="$USER_HOME/.config/hypr"
install -d -m 755 -o "$USERNAME" -g "$USERNAME" "$HYPR_DIR"

cat > "$HYPR_DIR/hyprland.conf" <<'HYPR'
# ~/.config/hypr/hyprland.conf -- starter config

monitor=,preferred,auto,1

input {
    kb_layout = de
    kb_variant = nodeadkeys
    follow_mouse = 1
    touchpad {
        natural_scroll = true
        tap-to-click = true
    }
    sensitivity = 0
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
    layout = dwindle
}

decoration {
    rounding = 6
    blur { enabled = true }
}

# Autostart
exec-once = waybar
exec-once = hyprpaper
exec-once = mako
exec-once = nm-applet --indicator
exec-once = blueman-applet
exec-once = systemctl --user start hyprpolkitagent
exec-once = wl-paste --type text  --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = hypridle

$mod = SUPER
$term = alacritty

bind = $mod, RETURN, exec, $term
bind = $mod, Q, killactive
bind = $mod SHIFT, E, exit
bind = $mod, D, exec, wofi --show drun
bind = $mod, E, exec, thunar
bind = $mod, L, exec, hyprlock
bind = $mod, F, fullscreen
bind = $mod, V, togglefloating

# Screenshot
bind = , Print, exec, grim -g "$(slurp)" - | swappy -f -

# Brightness / volume
bind = , XF86MonBrightnessUp,   exec, brightnessctl set +5%
bind = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
bind = , XF86AudioRaiseVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = , XF86AudioLowerVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = , XF86AudioMute,         exec, wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle

# Workspaces
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
HYPR

cat > "$HYPR_DIR/hyprpaper.conf" <<'HYP2'
# Replace with your wallpaper path
# preload = ~/Pictures/wall.jpg
# wallpaper = ,~/Pictures/wall.jpg
HYP2

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

# Make blueman-applet available (used by hyprland.conf autostart)
pacman -S --noconfirm --needed blueman

echo "==> Chroot configuration finished."
