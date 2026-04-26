#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Install — MacBook Pro 2012 (non-retina), dual 256 GB SATA SSD
# Disk    : EFI (512 MB, /dev/sdX1) | LUKS2 on both SSDs → Btrfs RAID
# Boot    : systemd-boot, linux-lts, Intel ucode
# Desktop : Hyprland + Waybar + Alacritty
# Extras  : LUKS2, Btrfs RAID0(data)/RAID1(meta), zram, TLP, TRIM, Bluetooth,
#           Broadcom wl, NetworkManager, mbpfan, German layout, SSH daemon
# Run from the Arch ISO live environment as root.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GRN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

# ── Prompts ───────────────────────────────────────────────────────────────────
echo
read -rp  "Username : " USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Invalid username"

read -rp  "Hostname : " HOSTNAME
[[ "$HOSTNAME"  =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Invalid hostname"

read -rsp "LUKS passphrase        : " LUKS_PASS;  echo
read -rsp "Confirm LUKS passphrase: " LUKS_PASS2; echo
[[ "$LUKS_PASS" == "$LUKS_PASS2" ]] || die "Passphrases do not match"

read -rsp "User password          : " USER_PASS;  echo
echo

# ── Disk selection ────────────────────────────────────────────────────────────
lsblk -d -o NAME,SIZE,MODEL,TRAN
echo
read -rp "Primary disk   (e.g. sda): " _D1
read -rp "Secondary disk (e.g. sdb): " _D2

DISK1="/dev/${_D1##/dev/}"
DISK2="/dev/${_D2##/dev/}"
DEV1="${_D1##/dev/}"   # bare name, e.g. sda
DEV2="${_D2##/dev/}"

[[ -b "$DISK1" ]] || die "$DISK1 is not a block device"
[[ -b "$DISK2" ]] || die "$DISK2 is not a block device"
[[ "$DISK1" != "$DISK2" ]] || die "Both disks are the same device"

warn "ALL data on $DISK1 and $DISK2 will be permanently destroyed."
read -rp "Type 'yes' to continue: " _CONFIRM
[[ "$_CONFIRM" == "yes" ]] || die "Aborted"

CREATION_DATE=$(date +%Y%m%d)

timedatectl set-ntp true

# ── Partitioning ──────────────────────────────────────────────────────────────
log "Partitioning $DISK1 …"
sgdisk --zap-all "$DISK1"
sgdisk \
  -n 1:0:+512M  -t 1:ef00 -c 1:"EFI" \
  -n 2:0:0      -t 2:8309 -c 2:"LUKS_A" \
  "$DISK1"

log "Partitioning $DISK2 …"
sgdisk --zap-all "$DISK2"
sgdisk \
  -n 1:0:0 -t 1:8309 -c 1:"LUKS_B" \
  "$DISK2"

partprobe "$DISK1" "$DISK2"
sleep 2

EFI_PART="${DISK1}1"
LUKS_PART1="${DISK1}2"
LUKS_PART2="${DISK2}1"

# ── LUKS2 encryption ──────────────────────────────────────────────────────────
LUKS_ARGS=(
  --type luks2
  --cipher aes-xts-plain64
  --key-size 512
  --hash sha512
  --pbkdf argon2id
  --iter-time 3000
)

for _part in "$LUKS_PART1" "$LUKS_PART2"; do
  log "LUKS2 format: $_part"
  echo -n "$LUKS_PASS" | cryptsetup luksFormat "${LUKS_ARGS[@]}" "$_part" -
done

log "Opening LUKS containers …"
echo -n "$LUKS_PASS" | cryptsetup open --allow-discards "$LUKS_PART1" cryptroot1 -
echo -n "$LUKS_PASS" | cryptsetup open --allow-discards "$LUKS_PART2" cryptroot2 -

# ── Btrfs (data RAID0 for full capacity, metadata RAID1 for resilience) ───────
log "Creating Btrfs across /dev/mapper/cryptroot{1,2} …"
mkfs.btrfs \
  --label arch \
  --data    raid0 \
  --metadata raid1 \
  /dev/mapper/cryptroot1 /dev/mapper/cryptroot2

BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot1)
UUID1=$(blkid -s UUID -o value "$LUKS_PART1")
UUID2=$(blkid -s UUID -o value "$LUKS_PART2")

# ── Subvolumes ────────────────────────────────────────────────────────────────
mount /dev/mapper/cryptroot1 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

# ── Mount ─────────────────────────────────────────────────────────────────────
BOPTS="noatime,compress=zstd:1,space_cache=v2,discard=async"
mount -o "${BOPTS},subvol=@"          /dev/mapper/cryptroot1 /mnt
mkdir -p /mnt/{home,var,.snapshots,boot}
mount -o "${BOPTS},subvol=@home"      /dev/mapper/cryptroot1 /mnt/home
mount -o "${BOPTS},subvol=@var"       /dev/mapper/cryptroot1 /mnt/var
mount -o "${BOPTS},subvol=@snapshots" /dev/mapper/cryptroot1 /mnt/.snapshots

# ESP at /boot — kernels live inside the ESP (required for systemd-boot)
mkfs.fat -F32 -n EFI "$EFI_PART"
mount "$EFI_PART" /mnt/boot

# ── pacstrap ──────────────────────────────────────────────────────────────────
log "pacstrap — this will take a while …"
pacstrap -K /mnt \
  base base-devel \
  linux-lts linux-lts-headers linux-firmware \
  btrfs-progs \
  cryptsetup \
  sudo git vim \
  openssh \
  networkmanager network-manager-applet \
  bluez bluez-utils \
  acpi acpid \
  tlp tlp-rdw \
  zram-generator \
  intel-ucode \
  mesa libva-intel-driver \
  broadcom-wl-dkms \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  hyprland xdg-desktop-portal-hyprland \
  waybar \
  wofi \
  mako \
  swww \
  hyprlock hypridle \
  alacritty \
  thunar \
  polkit-kde-agent \
  qt5-wayland qt6-wayland qt5ct \
  grim slurp \
  wl-clipboard \
  brightnessctl \
  playerctl \
  pamixer pavucontrol \
  xdg-utils \
  noto-fonts noto-fonts-emoji \
  ttf-font-awesome \
  mbpfan \
  thermald \
  bash-completion

genfstab -U /mnt >> /mnt/etc/fstab

# ── chroot setup script ───────────────────────────────────────────────────────
# Written to a file to avoid heredoc-within-heredoc quoting issues.
# All $OUTER_VARS are expanded NOW by this shell; \$INNER_VARS expand
# inside the chroot script at runtime.
cat > /mnt/root/setup.sh << SETUP
#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME}"
HOSTNAME="${HOSTNAME}"
USER_PASS="${USER_PASS}"
LUKS_PASS="${LUKS_PASS}"
UUID1="${UUID1}"
UUID2="${UUID2}"
BTRFS_UUID="${BTRFS_UUID}"
DEV1="${DEV1}"
DEV2="${DEV2}"
CREATION_DATE="${CREATION_DATE}"

# ── Timezone ──────────────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

# ── Locale ────────────────────────────────────────────────────────────────────
sed -i '/^#de_DE.UTF-8 UTF-8/s/^#//' /etc/locale.gen
sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=de_DE.UTF-8"   > /etc/locale.conf
printf 'KEYMAP=de-latin1\nFONT=lat9w-16\n' > /etc/vconsole.conf

# ── Hostname ──────────────────────────────────────────────────────────────────
echo "\$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain  \${HOSTNAME}
EOF

# ── crypttab.initramfs (sd-encrypt reads this for multi-device LUKS) ─────────
# Both LUKS containers are opened before root is mounted.
# If both share the same passphrase, systemd caches it after the first prompt.
cat > /etc/crypttab.initramfs << EOF
cryptroot1  UUID=\${UUID1}  none  luks,discard
cryptroot2  UUID=\${UUID2}  none  luks,discard
EOF

# ── mkinitcpio ────────────────────────────────────────────────────────────────
sed -i 's/^MODULES=.*/MODULES=(btrfs intel_agp i915)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
    /etc/mkinitcpio.conf
mkinitcpio -P

# ── systemd-boot ──────────────────────────────────────────────────────────────
bootctl --esp-path=/boot install

cat > /boot/loader/loader.conf << EOF
default arch-lts.conf
timeout 4
console-mode max
editor  no
EOF

# Normal entry — no rd.luks.name needed; sd-encrypt reads crypttab.initramfs
cat > /boot/loader/entries/arch-lts.conf << EOF
title   Arch Linux LTS
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options root=UUID=\${BTRFS_UUID} rootfstype=btrfs rootflags=subvol=@ rw \\
        quiet loglevel=3 \\
        acpi_osi=Darwin acpi_backlight=native \\
        pcie_aspm=off nmi_watchdog=0 \\
        i915.enable_psr=0
EOF

cat > /boot/loader/entries/arch-lts-fallback.conf << EOF
title   Arch Linux LTS (fallback initramfs)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts-fallback.img
options root=UUID=\${BTRFS_UUID} rootfstype=btrfs rootflags=subvol=@ rw \\
        acpi_osi=Darwin acpi_backlight=native
EOF

# ── zram ──────────────────────────────────────────────────────────────────────
cat > /etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size            = ram / 2
compression-algorithm = zstd
swap-priority        = 100
fs-type              = swap
EOF

# ── Broadcom wl (BCM4331) ─────────────────────────────────────────────────────
echo "wl" > /etc/modules-load.d/broadcom-wl.conf
cat > /etc/modprobe.d/broadcom-wl.conf << EOF
blacklist b43
blacklist b43legacy
blacklist bcma
blacklist brcmsmac
blacklist brcmfmac
EOF

# ── Sound (MacBook Pro 2012 — Cirrus Logic CS4206) ────────────────────────────
cat > /etc/modprobe.d/snd-hda-intel.conf << EOF
options snd-hda-intel model=mbp101
EOF

# ── TLP ───────────────────────────────────────────────────────────────────────
cat >> /etc/tlp.conf << EOF

# MacBook Pro 2012 — appended by install script
TLP_ENABLE=1
DISK_DEVICES="\${DEV1} \${DEV2}"
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="128 128"
SATA_LINKPWR_ON_BAT=med_power_with_dipm
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
RUNTIME_PM_ON_BAT=auto
USB_AUTOSUSPEND=1
WOL_DISABLE=Y
EOF

# ── mbpfan ────────────────────────────────────────────────────────────────────
cat > /etc/mbpfan.conf << EOF
[general]
min_fan_speed    = 2000
max_fan_speed    = 6200
low_temp         = 55
high_temp        = 65
max_temp         = 90
polling_interval = 7
EOF

# ── SSH hardening ─────────────────────────────────────────────────────────────
cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
PermitRootLogin      no
PubkeyAuthentication yes
PasswordAuthentication yes
X11Forwarding        no
EOF

# ── pacman: color + parallel downloads + multilib ────────────────────────────
sed -i 's/^#Color/Color/'                              /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
sed -i '/^\[multilib\]/{n;s/^#//}' /etc/pacman.conf || true
sed -i 's/^#\[multilib\]/[multilib]/'                  /etc/pacman.conf || true
pacman -Sy --noconfirm

# ── User ──────────────────────────────────────────────────────────────────────
useradd -m -G wheel,audio,video,storage,optical,network,bluetooth,input \
        -s /bin/bash "\$USERNAME"
echo "\${USERNAME}:\${USER_PASS}" | chpasswd
passwd -l root        # disable root login

# sudo — require password but extend timeout to 15 min
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
echo "Defaults timestamp_timeout=15" > /etc/sudoers.d/timeout

# ── AUR: paru + vivaldi ───────────────────────────────────────────────────────
# Temporarily grant NOPASSWD so makepkg/paru can call pacman
echo "\${USERNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/aur-tmp

su - "\$USERNAME" -c '
  set -euo pipefail
  cd /tmp
  git clone --depth=1 https://aur.archlinux.org/paru-bin.git
  cd paru-bin
  makepkg -si --noconfirm --needed

  paru -S --noconfirm --needed vivaldi
' || warn "AUR installation failed — install paru + vivaldi manually after reboot"

rm -f /etc/sudoers.d/aur-tmp

# ── SSH key pair ──────────────────────────────────────────────────────────────
su - "\$USERNAME" -c "
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  KEYFILE=~/.ssh/\${HOSTNAME}_\${CREATION_DATE}
  ssh-keygen -t ed25519 \
             -C '\${USERNAME}@\${HOSTNAME} created:\${CREATION_DATE}' \
             -f \"\\\$KEYFILE\" \
             -N ''
  cat \"\\\${KEYFILE}.pub\" >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  echo \"[+] SSH key pair: \\\$KEYFILE\"
"

# ── Hyprland config ───────────────────────────────────────────────────────────
HDIR="/home/\${USERNAME}/.config/hypr"
mkdir -p "\$HDIR"

cat > "\${HDIR}/hyprland.conf" << 'HYPRCONF'
# hyprland.conf — MacBook Pro 2012 / Arch Linux

monitor = , preferred, auto, 1

env = XCURSOR_SIZE,     24
env = QT_QPA_PLATFORMTHEME, qt5ct
env = MOZ_ENABLE_WAYLAND, 1

input {
    kb_layout  = de
    kb_options = caps:escape
    follow_mouse = 1
    sensitivity  = 0
    touchpad {
        natural_scroll       = true
        tap-to-click         = true
        drag_lock            = true
        disable_while_typing = true
    }
}

general {
    gaps_in     = 4
    gaps_out    = 8
    border_size = 2
    col.active_border   = rgba(88c0d0ff) rgba(81a1c1ff) 45deg
    col.inactive_border = rgba(4c566aff)
    layout      = dwindle
}

decoration {
    rounding = 8
    drop_shadow = true
    shadow_range = 8
    blur {
        enabled = true
        size    = 4
        passes  = 1
    }
}

animations {
    enabled = true
    bezier = ease, 0.05, 0.9, 0.1, 1.05
    animation = windows,    1, 4, ease
    animation = windowsOut, 1, 4, default, popin 80%
    animation = fade,       1, 4, default
    animation = workspaces, 1, 5, default
}

dwindle {
    pseudotile     = true
    preserve_split = true
}

gestures {
    workspace_swipe = true
}

misc {
    force_default_wallpaper = 0
}

# ── Autostart ─────────────────────────────────────────────────────────────────
exec-once = /usr/lib/polkit-kde-authentication-agent-1
exec-once = nm-applet --indicator
exec-once = waybar
exec-once = mako
exec-once = swww-daemon
exec-once = hypridle

# ── Keybinds ──────────────────────────────────────────────────────────────────
$mainMod = SUPER

bind = $mainMod,       Return, exec,         alacritty
bind = $mainMod,       Q,      killactive,
bind = $mainMod SHIFT, M,      exit,
bind = $mainMod,       E,      exec,         thunar
bind = $mainMod,       Space,  exec,         wofi --show drun
bind = $mainMod,       F,      fullscreen,
bind = $mainMod SHIFT, F,      togglefloating,
bind = $mainMod,       L,      exec,         hyprlock

# Focus (vi keys)
bind = $mainMod, h, movefocus, l
bind = $mainMod, l, movefocus, r
bind = $mainMod, k, movefocus, u
bind = $mainMod, j, movefocus, d

# Move windows
bind = $mainMod SHIFT, h, movewindow, l
bind = $mainMod SHIFT, l, movewindow, r
bind = $mainMod SHIFT, k, movewindow, u
bind = $mainMod SHIFT, j, movewindow, d

# Workspaces 1-9
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9

# MacBook Fn keys
bind = , XF86MonBrightnessUp,   exec, brightnessctl set 5%+
bind = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
bind = , XF86AudioRaiseVolume,  exec, pamixer -i 5
bind = , XF86AudioLowerVolume,  exec, pamixer -d 5
bind = , XF86AudioMute,         exec, pamixer -t
bind = , XF86AudioPlay,         exec, playerctl play-pause
bind = , XF86AudioNext,         exec, playerctl next
bind = , XF86AudioPrev,         exec, playerctl previous

# Screenshot → clipboard
bind = ,          Print,       exec, grim - | wl-copy
bind = $mainMod SHIFT, S, exec, grim -g "\$(slurp)" - | wl-copy

# Mouse window ops
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow
HYPRCONF

# ── hyprlock ──────────────────────────────────────────────────────────────────
cat > "\${HDIR}/hyprlock.conf" << 'LOCKCONF'
background {
    monitor =
    color   = rgba(1e1e2eff)
}
input-field {
    monitor  =
    size     = 300, 50
    position = 0, -80
    halign   = center
    valign   = center
    outline_thickness = 2
    col.color       = rgba(88c0d0ff)
    col.outer_color = rgba(4c566aff)
    placeholder_text = <i>Password...</i>
    hide_input = false
}
LOCKCONF

# ── hypridle ──────────────────────────────────────────────────────────────────
cat > "\${HDIR}/hypridle.conf" << 'IDLECONF'
general {
    lock_cmd = hyprlock
}
listener {
    timeout    = 150
    on-timeout = brightnessctl -s set 10%
    on-resume  = brightnessctl -r
}
listener {
    timeout    = 300
    on-timeout = hyprlock
}
listener {
    timeout    = 600
    on-timeout = systemctl suspend
}
IDLECONF

# ── Waybar ────────────────────────────────────────────────────────────────────
WBDIR="/home/\${USERNAME}/.config/waybar"
mkdir -p "\$WBDIR"
cat > "\${WBDIR}/config.jsonc" << 'WBCONF'
{
    "layer"        : "top",
    "position"     : "top",
    "height"       : 28,
    "modules-left" : ["hyprland/workspaces"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "battery", "network", "tray"],

    "hyprland/workspaces": { "format": "{id}" },

    "clock": { "format": "{:%d.%m.%Y  %H:%M}" },

    "battery": {
        "format"          : "  {capacity}%",
        "format-charging" : "⚡ {capacity}%",
        "warning"         : 20,
        "critical"        : 10
    },
    "network": {
        "format-wifi"        : "  {essid} ({signalStrength}%)",
        "format-ethernet"    : "  {ifname}",
        "format-disconnected": "⚠  disconnected",
        "tooltip-format-wifi": "{ipaddr}"
    },
    "pulseaudio": {
        "format"      : "  {volume}%",
        "format-muted": "  muted",
        "on-click"    : "pavucontrol"
    },
    "tray": { "spacing": 8 }
}
WBCONF

cat > "\${WBDIR}/style.css" << 'WBSTYLE'
* { font-family: "Noto Sans", "Font Awesome 6 Free"; font-size: 13px; }
window#waybar { background: rgba(30,34,42,0.85); color: #d8dee9; }
#workspaces button { padding: 0 6px; color: #4c566a; }
#workspaces button.active { color: #88c0d0; border-bottom: 2px solid #88c0d0; }
#clock, #battery, #network, #pulseaudio, #tray { padding: 0 10px; }
#battery.critical { color: #bf616a; }
WBSTYLE

chown -R "\${USERNAME}:\${USERNAME}" "/home/\${USERNAME}/.config"

# ── Enable systemd services ───────────────────────────────────────────────────
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable bluetooth
systemctl enable acpid
systemctl enable tlp
systemctl enable fstrim.timer      # periodic SSD TRIM
systemctl enable mbpfan
systemctl enable thermald

# TLP conflicts with rfkill services
systemctl mask systemd-rfkill.service systemd-rfkill.socket

echo
echo "======================================================"
echo "  Chroot setup complete."
echo "  SSH key: ~/.ssh/\${HOSTNAME}_\${CREATION_DATE}"
echo "======================================================"
SETUP

chmod +x /mnt/root/setup.sh
arch-chroot /mnt /root/setup.sh
rm /mnt/root/setup.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────
log "Unmounting …"
sync
umount -R /mnt
cryptsetup close cryptroot2
cryptsetup close cryptroot1

echo
echo -e "${GRN}Installation complete.${NC}"
echo "• Remove the install medium and reboot."
echo "• On boot: hold ⌥ Option to choose the EFI boot device if needed."
echo "• LUKS prompt appears twice (cryptroot1, cryptroot2)."
echo "  If both share the same passphrase, systemd caches it after the first entry."
echo "• After first login, run Hyprland from a TTY: \`Hyprland\`"
echo "• WiFi: \`nmtui\` or nm-applet in Hyprland."
