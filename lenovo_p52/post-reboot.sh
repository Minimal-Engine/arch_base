#!/usr/bin/env bash
# Run as the regular user AFTER first reboot.
# Installs flatpak + flathub, ly DM, AUR helper, Vivaldi, ThinkPad fan/ACPI
# tooling, and writes Hyprland tweaks tuned for hybrid Intel+NVIDIA on a P52.

set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root."; exit 1; }
[[ -n "${HOME:-}" ]] || { echo "HOME not set."; exit 1; }

sudo pacman -Syu --needed --noconfirm git base-devel

# --- Flatpak + Flathub -------------------------------------------------------
sudo pacman -S --needed --noconfirm flatpak
sudo flatpak remote-add --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo

# --- ly display manager ------------------------------------------------------
sudo pacman -S --needed --noconfirm ly
sudo systemctl disable --now getty@tty2.service 2>/dev/null || true
sudo systemctl enable ly.service

# --- Extra desktop tooling ---------------------------------------------------
sudo pacman -S --needed --noconfirm \
  qt6ct nwg-look udiskie pamixer thinkfan

# Enable thinkfan (sensors must be present; thinkpad_acpi loads automatically).
# Default config in /etc/thinkfan.conf works for most ThinkPads.
sudo systemctl enable --now thinkfan.service || \
  echo "thinkfan failed to start -- review /etc/thinkfan.conf, may need 'options thinkpad_acpi fan_control=1'"

# --- yay (AUR helper) --------------------------------------------------------
if ! command -v yay >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  ( cd "$tmp/yay-bin" && makepkg -si --noconfirm )
  rm -rf "$tmp"
fi

# --- Vivaldi + codecs --------------------------------------------------------
yay -S --needed --noconfirm vivaldi vivaldi-ffmpeg-codecs

# --- acpi_call (matches linux-lts) -------------------------------------------
# Used by some power tools and for Optimus dGPU on/off scripts.
yay -S --needed --noconfirm acpi_call-lts

# --- Vivaldi / Chromium Wayland flags ----------------------------------------
mkdir -p "$HOME/.config"

cat > "$HOME/.config/vivaldi-flags.conf" <<'EOF'
--ozone-platform-hint=auto
--enable-features=WaylandWindowDecorations
--gtk-version=4
EOF

cat > "$HOME/.config/chromium-flags.conf" <<'EOF'
--ozone-platform-hint=auto
--enable-features=WaylandWindowDecorations
--gtk-version=4
EOF

# --- Hyprland tweaks (P52 hybrid Intel+NVIDIA) ------------------------------
HYPR_DIR="$HOME/.config/hypr"
mkdir -p "$HYPR_DIR"

cat > "$HYPR_DIR/tweaks.conf" <<'EOF'
# Loaded from hyprland.conf via `source =`. Tuned for ThinkPad P52
# running Hyprland on the Intel iGPU primary, NVIDIA Quadro available
# via prime-run for selective offload.

# --- Monitor (edit after first login: hyprctl monitors) ---------------------
# Internal panel is usually eDP-1
# monitor = eDP-1, 1920x1080@60, 0x0, 1

# --- Cursor size -------------------------------------------------------------
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

# --- Toolkit / session env ---------------------------------------------------
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = QT_QPA_PLATFORM,wayland;xcb
env = QT_QPA_PLATFORMTHEME,qt6ct
env = MOZ_ENABLE_WAYLAND,1
env = GDK_BACKEND,wayland,x11,*

# --- NVIDIA bits (apply globally; harmless when prime-run isn't used) -------
# These let CUDA / hardware video decode work, and ensure GBM uses NVIDIA
# when the dGPU is selected.
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct

# --- Force Hyprland onto the Intel iGPU as primary --------------------------
# /dev/dri/by-path/* is stable across reboots, unlike card0/card1.
# After first boot, run: ls -l /dev/dri/by-path/  and adjust if needed.
# Most P52 setups: pci-0000:00:02.0 = Intel, pci-0000:01:00.0 = NVIDIA
env = WLR_DRM_DEVICES,/dev/dri/by-path/pci-0000:00:02.0-card

# --- Touchpad / TrackPoint ---------------------------------------------------
input {
    kb_layout = de
    kb_variant = nodeadkeys
    touchpad {
        natural_scroll       = true
        tap-to-click         = true
        disable_while_typing = true
        clickfinger_behavior = true
        scroll_factor        = 0.4
    }
}

gestures {
    workspace_swipe         = true
    workspace_swipe_fingers = 3
}

# --- Performance -------------------------------------------------------------
decoration {
    rounding = 6
    blur {
        enabled            = true
        size               = 5
        passes             = 2
        new_optimizations  = true
    }
    shadow {
        enabled = false
    }
}

animations {
    enabled = true
    bezier  = easeOut, 0.25, 0.46, 0.45, 0.94
    animation = windows,    1, 4, easeOut
    animation = fade,       1, 4, easeOut
    animation = workspaces, 1, 4, easeOut
}

misc {
    vfr                       = true
    vrr                       = 0
    disable_hyprland_logo     = true
    disable_splash_rendering  = true
}

# --- Autostart additions -----------------------------------------------------
exec-once = udiskie --tray

# --- Media keys via pamixer --------------------------------------------------
bind = , XF86AudioRaiseVolume, exec, pamixer -i 5
bind = , XF86AudioLowerVolume, exec, pamixer -d 5
bind = , XF86AudioMute,        exec, pamixer -t

# --- Run an app on the NVIDIA dGPU ------------------------------------------
# Mod+Shift+RETURN opens an alacritty session where commands run on NVIDIA.
bind = SUPER SHIFT, RETURN, exec, prime-run alacritty
EOF

# Append `source =` to hyprland.conf if not already there (idempotent).
HYPR_CONF="$HYPR_DIR/hyprland.conf"
if [[ -f "$HYPR_CONF" ]] && ! grep -q 'source = ~/.config/hypr/tweaks.conf' "$HYPR_CONF"; then
  printf '\n# Tweaks added by post-reboot.sh\nsource = ~/.config/hypr/tweaks.conf\n' \
    >> "$HYPR_CONF"
fi

# --- hypridle ----------------------------------------------------------------
cat > "$HYPR_DIR/hypridle.conf" <<'EOF'
general {
    lock_cmd        = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd  = hyprctl dispatch dpms on
}

listener {
    timeout    = 300
    on-timeout = brightnessctl -s set 10%
    on-resume  = brightnessctl -r
}

listener {
    timeout    = 600
    on-timeout = loginctl lock-session
}

listener {
    timeout    = 630
    on-timeout = hyprctl dispatch dpms off
    on-resume  = hyprctl dispatch dpms on
}

listener {
    timeout    = 1800
    on-timeout = systemctl suspend
}
EOF

# --- hyprlock ----------------------------------------------------------------
cat > "$HYPR_DIR/hyprlock.conf" <<'EOF'
background {
    monitor =
    color   = rgba(25, 20, 20, 1.0)
    blur_passes = 2
}

input-field {
    monitor = 
    size    = 250, 50
    position = 0, -80
    halign  = center
    valign  = center
    placeholder_text = Password
}

label {
    monitor   = 
    text      = $TIME
    font_size = 64
    position  = 0, 160
    halign    = center
    valign    = center
}
EOF

# --- mako --------------------------------------------------------------------
mkdir -p "$HOME/.config/mako"
cat > "$HOME/.config/mako/config" <<'EOF'
default-timeout=5000
border-radius=6
padding=12
margin=12
anchor=top-right
font=JetBrainsMono Nerd Font 10
EOF

# --- Waybar ------------------------------------------------------------------
if [[ ! -d "$HOME/.config/waybar" ]] && [[ -d /etc/xdg/waybar ]]; then
  mkdir -p "$HOME/.config/waybar"
  cp -a /etc/xdg/waybar/. "$HOME/.config/waybar/"
fi

# --- Portal user service -----------------------------------------------------
systemctl --user enable xdg-desktop-portal-hyprland.service 2>/dev/null || true

echo
echo "Done."
echo "  - Flatpak ready (flathub system-wide)."
echo "  - ly starts on next boot. Pick 'Hyprland' in the session list."
echo "  - Vivaldi, thinkfan, acpi_call-lts installed."
echo "  - Hyprland tweaks loaded via ~/.config/hypr/tweaks.conf"
echo
echo "  After login:"
echo "    hyprctl monitors                  -> set monitor= line in tweaks.conf"
echo "    ls -l /dev/dri/by-path/           -> verify WLR_DRM_DEVICES path"
echo "    prime-run glxinfo | grep vendor   -> confirm NVIDIA offload works"
echo "    fwupdmgr refresh && fwupdmgr update -> ThinkPad firmware updates"
