#!/usr/bin/env bash
# Run as the regular user AFTER first reboot.
# Installs an AUR helper, then Vivaldi and mbpfan from the AUR.

set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root."; exit 1; }

sudo pacman -Syu --needed --noconfirm git base-devel

# --- yay (AUR helper) --------------------------------------------------------
if ! command -v yay >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  ( cd "$tmp/yay-bin" && makepkg -si --noconfirm )
  rm -rf "$tmp"
fi

# --- Vivaldi + codecs --------------------------------------------------------
yay -S --needed --noconfirm vivaldi vivaldi-ffmpeg-codecs

# --- mbpfan (fan control tuned for MacBook) ----------------------------------
yay -S --needed --noconfirm mbpfan-git
sudo systemctl enable --now mbpfan.service

echo "Done. Vivaldi and mbpfan installed."
