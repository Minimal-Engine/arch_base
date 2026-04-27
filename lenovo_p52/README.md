# Arch Linux installer — Lenovo ThinkPad P52

Encrypted Arch install for a P52 with **2× NVMe SSDs + 1× SATA SSD** and the
NVIDIA Quadro Pascal dGPU + Intel UHD 630 iGPU (Optimus hybrid).

## Files

| File | When | Where |
|------|------|-------|
| `install.sh` | Live ISO | as root |
| `chroot-config.sh` | called automatically by `install.sh` | inside `arch-chroot` |
| `post-reboot.sh` | after first boot | as your user |

## Disk layout

| Drive | Partitioning | Role |
|-------|--------------|------|
| NVMe1 | 512 MiB ESP + LUKS2 | ESP at `/boot`, root part 1 |
| NVMe2 | full disk LUKS2 | root part 2 |
| SATA SSD | full disk LUKS2 | separate Btrfs at `/mnt/data` |

Root Btrfs spans **both NVMe drives** (`-d single -m raid1`): data is
concatenated across the NVMe pair (~2× capacity), metadata mirrored. The SATA
SSD is its own encrypted Btrfs at `/mnt/data` — kept separate to avoid mixing
NVMe and SATA performance tiers.

Subvolumes on the NVMe span: `@`, `@home`, `@log`, `@pkg`, `@snapshots`.
Subvolume on the SATA: `@data`.

## Usage

1. Boot the Arch ISO in EFI mode (F12 boot menu).
2. Get a network: Ethernet works out of box; for WiFi use `iwctl`.
3. Copy `install.sh` and `chroot-config.sh` to the same dir on the live system.
4. `bash install.sh` — answer prompts (3 disks, hostname, username, passwords).
5. After it finishes:
   ```
   umount -R /mnt
   cryptsetup close cryptroot1
   cryptsetup close cryptroot2
   cryptsetup close cryptdata
   reboot
   ```
6. Log in via ly (Hyprland session), then `bash post-reboot.sh`.

## Key design decisions

- **Encryption**: LUKS2 + Argon2id on all three drives, **same passphrase** —
  `sd-encrypt` caches the first entry and reuses it for the next two, so you
  type once at boot.
- **Bootloader**: systemd-boot. Pacman hook keeps `bootctl` updated; second hook
  rebuilds initramfs on `nvidia-lts` updates.
- **Kernel**: `linux-lts` (paired with `nvidia-lts`).
- **NVIDIA**:
  - Proprietary `nvidia-lts` (Pascal — `nvidia-open` is Turing+ only).
  - Modules in `MODULES=` for early KMS.
  - `nvidia_drm.modeset=1` and `nvidia_drm.fbdev=1` on cmdline.
  - `nvidia-suspend.service` / `-resume` / `-hibernate` enabled (VRAM save).
  - Dynamic power management on (`NVreg_DynamicPowerManagement=0x02`) — dGPU
    powers down when not in use, big battery win.
- **Hybrid graphics**: Hyprland runs on the **Intel iGPU** by default (set via
  `WLR_DRM_DEVICES`). For dGPU offload of a specific app: `prime-run <app>`.
- **TRIM**: `discard=async` (Btrfs) + `discard` (LUKS) + weekly `fstrim.timer`.
- **ZRAM**: half of RAM, capped at 8 GiB, zstd.
- **Power**: TLP + thermald + acpid all enabled. ThinkPad battery charge
  thresholds set (75/80%) to extend battery lifespan.
- **ThinkPad fan control**: `thinkfan` (post-reboot script). If it fails to
  start, edit `/etc/thinkfan.conf` and ensure
  `options thinkpad_acpi fan_control=1` is in `/etc/modprobe.d/thinkfan.conf`.
- **TrackPoint**: middle-button-drag scrolling configured via Xorg conf
  (libinput on Wayland already does middle-button scroll on its own).
- **WiFi/Bluetooth**: Intel chip — covered by `linux-firmware`, no proprietary
  blob needed.
- **Firmware updates**: `fwupd` enabled. Run `fwupdmgr refresh && fwupdmgr update`
  for BIOS/Thunderbolt/etc. updates via LVFS (well supported on ThinkPads).
- **User**: in `wheel` (sudo) + `video,audio,input,storage,network,lp`.
- **Root**: locked + `nologin`.
- **SSH key**: `~/.ssh/id_ed25519_<HOSTNAME>_<YYYYMMDD>`.
- **sshd**: drop-in hardening (no root, no X11 fwd).
- **German keyboard**: `de-latin1` TTY, `de` + `nodeadkeys` Hyprland.
- **Display manager**: ly (TUI on tty2).
- **Flatpak**: with Flathub system-wide.
- **Hyprland**: starter config + tweaks (`tweaks.conf`) loaded via `source =`.
  Includes recommended utilities (waybar, wofi, hyprpaper, hyprlock, hypridle,
  mako, hyprpolkitagent, grim/slurp/swappy, wl-clipboard, cliphist) and
  **alacritty** as the terminal.
- **AUR packages**: vivaldi + codecs, acpi_call-lts.

## Things to check after install

- **GPU path**: `ls -l /dev/dri/by-path/` — confirm `pci-0000:00:02.0-card` is
  Intel and adjust `WLR_DRM_DEVICES` in `~/.config/hypr/tweaks.conf` if not.
- **Monitor**: `hyprctl monitors`, then uncomment / edit the `monitor=` line
  in `tweaks.conf`.
- **Offload test**: `glxinfo | grep "OpenGL renderer"` (should show Intel),
  then `prime-run glxinfo | grep "OpenGL renderer"` (should show Quadro).
- **Suspend test**: `systemctl suspend` and resume — `mem_sleep_default=deep`
  is set on cmdline; verify with `cat /sys/power/mem_sleep` (should show `[deep]`).
- **Firmware**: `fwupdmgr get-devices` and `fwupdmgr update`.

## Notes

- **NVIDIA + Wayland** has improved a lot but is still occasionally rough.
  If you hit weird flicker/black screens, the Hyprland wiki has an NVIDIA page
  worth bookmarking. Keeping the iGPU as primary (this setup) avoids most issues.
- **`/mnt/data`** belongs to your user (set in chroot script). Mount it
  wherever you like — symlink `~/Steam`, `~/VirtualBox VMs`, build dirs, etc.
- **Reset if anything fails**: re-running `install.sh` wipes everything cleanly,
  but `cryptsetup close` any open mappers first.
