# --- Flatpak + Flathub -------------------------------------------------------
sudo pacman -S --needed --noconfirm flatpak
sudo flatpak remote-add --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo

# --- yay (AUR helper) --------------------------------------------------------
if ! command -v yay >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  ( cd "$tmp/yay-bin" && makepkg -si --noconfirm )
  rm -rf "$tmp"
fi

# Arch Linux setup: git, zsh, tmux, yt-dlp, cmus, mc, neovim, oh-my-zsh
set -euo pipefail
 
if [[ $EUID -eq 0 ]]; then
    echo "Run as a regular user with sudo privileges, not as root." >&2
    exit 1
fi
 
PKGS=(git zsh tmux yt-dlp cmus mc neovim curl)
 
echo ">>> Syncing repos and installing packages..."
sudo pacman -Syu --needed --noconfirm "${PKGS[@]}"
 
# Oh My Zsh (unattended; won't change shell or run zsh)
if [[ -d "$HOME/.oh-my-zsh" ]]; then
    echo ">>> Oh My Zsh already installed, skipping."
else
    echo ">>> Installing Oh My Zsh..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
 
# Set zsh as default shell if it isn't already
ZSH_PATH="$(command -v zsh)"
if [[ "${SHELL:-}" != "$ZSH_PATH" ]]; then
    echo ">>> Setting zsh as default shell (you'll be prompted for your password)..."
    chsh -s "$ZSH_PATH"
fi
 
echo ">>> Done. Log out and back in for the shell change to take effect."

# install tailscale
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
