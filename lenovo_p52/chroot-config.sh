#!/usr/bin/env bash
# Run inside arch-chroot. Invoked by install.sh.
# Args: HOSTNAME USERNAME USER_PASS LUKS1 LUKS2 LUKS3

set -euo pipefail

HOSTNAME=$1
USERNAME=$2
USER_PASS=$3
LUKS1=$4
LUKS2=$5
LUKS3=$6

# --- Time, locale, keymap ----------------------------------------------------
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/'   /etc/locale.gen
sed -i 's/^#\(de_DE.UTF-8 UTF-8\)/\1/'   /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

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

# --- mkinitcpio --------------------------------------------------------------
# NVIDIA in MODULES for early KMS (required for nvidia_drm.modeset=1).
sed -i 's|^MODULES=.*|MODULES=(btrfs i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)|' /etc/mkinitcpio.conf
sed -i 's|^HOOKS=.*|HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)|' /etc/mkinitcpio.conf

UUID1=$(blkid -s UUID -o value "$LUKS1")
UUID2=$(blkid -s UUID -o value "$LUKS2")
UUID3=$(blkid -s UUID -o value "$LUKS3")

# Same passphrase on all three -> sd-encrypt caches first entry, reuses for the rest.
cat > /etc/crypttab.initramfs <<EOF
cryptroot1 UUID=${UUID1} - luks,discard
cryptroot2 UUID=${UUID2} - luks,discard
cryptdata  UUID=${UUID3} - luks,discard
EOF

mkinitcpio -P

# --- systemd-boot ------------------------------------------------------------
bootctl install

cat > /boot/loader/loader.conf <<EOF
default  arch-lts.conf
timeout  3
console-mode max
editor   no
EOF

ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot1)

# nvidia_drm.modeset=1   -> required for Wayland
# nvidia_drm.fbdev=1     -> use NVIDIA fbdev (cleaner handoff)
# mem_sleep_default=deep -> proper S3 suspend (some ThinkPads default to s2idle)
KCMD="rd.luks.name=${UUID1}=cryptroot1 rd.luks.name=${UUID2}=cryptroot2 \
rd.luks.name=${UUID3}=cryptdata \
rd.luks.options=discard \
root=UUID=${ROOT_UUID} rootflags=subvol=@ \
rw quiet loglevel=3 \
nvidia_drm.modeset=1 nvidia_drm.fbdev=1 \
mem_sleep_default=deep"

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

# Auto-update systemd-boot.
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

# Rebuild initramfs when nvidia or kernel updates (arch-supplied hook covers
# the kernel; this one ensures nvidia-lts changes propagate).
cat > /etc/pacman.d/hooks/90-nvidia.hook <<'EOF'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia-lts
Target=linux-lts

[Action]
Description=Rebuild initramfs after NVIDIA/kernel change
Depends=mkinitcpio
When=PostTransaction
NeedsTargets
Exec=/bin/sh -c 'while read -r trg; do case $trg in linux-lts) exit 0; esac; done; /usr/bin/mkinitcpio -P'
EOF

# --- User --------------------------------------------------------------------
groupadd -f wheel
useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd

sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
visudo -cf /etc/sudoers >/dev/null

# Disable root
passwd -l root
usermod -s /usr/sbin/nologin root

# --- SSH key for the user (filename has hostname + creation date) -----------
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
systemctl enable fstrim.timer

# --- /mnt/data permissions ---------------------------------------------------
# Make the data drive writable by the user without sudo.
chown "$USERNAME:$USERNAME" /mnt/data

# --- Services ----------------------------------------------------------------
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sshd
systemctl enable tlp
systemctl enable acpid
systemctl enable thermald
systemctl enable systemd-timesyncd
systemctl enable reflector.timer
systemctl enable fwupd-refresh.timer

# --- ThinkPad / NVIDIA optimizations ----------------------------------------

# Power-save for NVIDIA when idle (works well with prime-run hybrid setup).
cat > /etc/modprobe.d/nvidia-power.conf <<EOF
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

# nvidia-suspend / nvidia-resume / nvidia-hibernate handle VRAM save-restore.
systemctl enable nvidia-suspend.service
systemctl enable nvidia-resume.service
systemctl enable nvidia-hibernate.service

# TrackPoint scrolling + sensitivity.
cat > /etc/X11/xorg.conf.d/20-thinkpad.conf <<EOF
Section "InputClass"
    Identifier  "TPPS/2 Elan TrackPoint"
    MatchProduct "TPPS/2 Elan TrackPoint"
    Option      "EmulateWheel"       "true"
    Option      "EmulateWheelButton" "2"
    Option      "Emulate3Buttons"    "false"
    Option      "XAxisMapping"       "6 7"
    Option      "YAxisMapping"       "4 5"
EndSection
EOF

# TLP tuned for P52: 2x NVMe + 1x SATA SSD, Intel WiFi.
mkdir -p /etc/tlp.conf.d
cat > /etc/tlp.conf.d/00-p52.conf <<EOF
TLP_ENABLE=1
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
PLATFORM_PROFILE_ON_AC=performance
PLATFORM_PROFILE_ON_BAT=low-power
DISK_DEVICES="nvme0n1 nvme1n1 sda"
SATA_LINKPWR_ON_AC=med_power_with_dipm
SATA_LINKPWR_ON_BAT=min_power
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
USB_AUTOSUSPEND=1
# ThinkPad battery charge thresholds (works on most ThinkPads incl. P52)
START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80
EOF

# --- reflector ---------------------------------------------------------------
mkdir -p /etc/xdg/reflector
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

# --- Hyprland starter config ------------------------------------------------
HYPR_DIR="$USER_HOME/.config/hypr"
install -d -m 755 -o "$USERNAME" -g "$USERNAME" "$HYPR_DIR"

cat > "$HYPR_DIR/hyprland.conf" <<'HYPR'
# ~/.config/hypr/hyprland.conf -- starter config (P52, hybrid Intel+NVIDIA)

monitor=,preferred,auto,1

input {
    kb_layout = de
    kb_variant = nodeadkeys
    follow_mouse = 1
    touchpad {
        natural_scroll = true
        tap-to-click = true
        disable_while_typing = true
        clickfinger_behavior = true
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
exec-once = dbus-update-activation-environment --systemd --all

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

# Run on NVIDIA GPU (e.g. Mod+Shift+B for Blender)
# Use: $ prime-run <app>     to launch any app on the dGPU
bind = , Print, exec, grim -g "$(slurp)" - | swappy -f -

bind = , XF86MonBrightnessUp,   exec, brightnessctl set +5%
bind = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
bind = , XF86AudioRaiseVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = , XF86AudioLowerVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = , XF86AudioMute,         exec, wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle

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
# preload = ~/Pictures/wall.jpg
# wallpaper = ,~/Pictures/wall.jpg
HYP2

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

echo "==> Chroot configuration finished."
