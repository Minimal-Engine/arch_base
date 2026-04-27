# Arch Linux installer — 2012 non-retina MacBook Pro

Encrypted Arch install for a MacBookPro9,1 / 9,2 modified with two 256 GB SATA SSDs
(typical mod: main bay + optical-bay caddy).

## Files

| File | When | Where |
|------|------|-------|
| `install.sh` | Live ISO | as root |
| `chroot-config.sh` | called automatically by `install.sh` | inside `arch-chroot` |
| `post-reboot.sh` | after first boot | as your user |

## Usage

1. Boot the Arch ISO **in EFI mode** (hold Option/Alt at chime, pick the EFI USB).
2. Get a network: `iwctl` for WiFi, or plug in Ethernet (USB adapter — built-in WLAN
   needs the proprietary `wl` driver which the ISO does not have).
3. Copy `install.sh` and `chroot-config.sh` to the same dir on the live system.
4. `bash install.sh` — answer the prompts.
5. After it finishes:
   ```
   umount -R /mnt
   cryptsetup close cryptroot1
   cryptsetup close cryptroot2
   reboot
   ```
6. Log in as your user, then `bash post-reboot.sh` to install Vivaldi + mbpfan from AUR.

## Design notes

- **Disks.** Disk 1 = 512 MiB ESP + LUKS2 root part 1. Disk 2 = single LUKS2 partition.
- **Btrfs profile.** `data=single, metadata=raid1` — data is concatenated across both
  unlocked devices (~512 GiB usable), metadata is mirrored for safety. Switch to
  `-d raid0` for striping if you want speed over redundancy of metadata only.
- **Subvolumes.** `@`, `@home`, `@log`, `@pkg`, `@snapshots`.
- **Encryption.** LUKS2 + Argon2id. Both volumes use the **same passphrase**;
  systemd's `sd-encrypt` initramfs hook caches the first entry and reuses it for
  the second, so you type it once at boot.
- **TRIM.** `discard=async` on btrfs, `discard` on LUKS (set in `/etc/crypttab.initramfs`),
  and `fstrim.timer` enabled as a weekly safety net.
- **Bootloader.** systemd-boot installed to `/boot` (= ESP). Loader entries for
  LTS kernel + fallback. Pacman hook keeps `bootctl` updated.
- **Kernel.** `linux-lts` only.
- **Initramfs.** `mkinitcpio` with `systemd` + `sd-encrypt` + `microcode` hooks
  (no separate `intel-ucode.img` line needed in loader entries).
- **WLAN.** `broadcom-wl-dkms` for the BCM4331; conflicting in-tree drivers
  (`b43`, `bcma`, `ssb`, `brcmsmac`, `brcmfmac`) blacklisted.
- **Apple keyboard.** `hid_apple` set to `fnmode=2` so F-keys are F-keys by default.
- **Apple firmware quirks.** `acpi_osi="Darwin"` and `acpi_backlight=vendor` on the
  kernel cmdline; `nouveau` blacklisted (matters on the 15" MBP9,1 with the
  GT 650M — it black-screens otherwise).
- **ZRAM.** Half of RAM, capped at 8 GiB, `zstd` compression, swap-priority 100.
- **TLP.** Tuned config in `/etc/tlp.conf.d/00-macbook.conf` — runtime PM, SATA
  link-power management, WiFi power save on battery.
- **User.** Added to `wheel` (Arch's sudo group) plus `video,audio,input,storage,network,lp`.
- **Root.** Locked (`passwd -l`) and shell set to `nologin`.
- **SSH key.** `~/.ssh/id_ed25519_<HOSTNAME>_<YYYYMMDD>` — comment includes the
  username, hostname, and date.
- **sshd.** Hardened drop-in: no root login, no X11 forwarding.
- **German keyboard.** `de-latin1` for the TTY (`/etc/vconsole.conf`); Hyprland
  config sets `kb_layout = de` with the `nodeadkeys` variant.
- **Hyprland.** Includes the recommended utilities — waybar, wofi, hyprpaper,
  hyprlock, hypridle, mako, grim/slurp/swappy, wl-clipboard + cliphist,
  hyprpolkitagent, xdg-desktop-portal-hyprland. **Terminal is alacritty**, not kitty.
- **Vivaldi.** AUR (`vivaldi` + `vivaldi-ffmpeg-codecs`) — installed by `post-reboot.sh`.
- **Fans.** `mbpfan-git` from AUR — also installed by `post-reboot.sh`.

## Things to check before running

- The script assumes `/dev/sda` and `/dev/sdb` style names. NVMe-style names
  (`nvme0n1pX`) are handled too — but a 2012 MBP only has SATA, so this is
  mostly defensive.
- `DISK_DEVICES` in the TLP drop-in is set to `"sda sdb"`. If your disks come
  up in a different order, adjust afterwards.
- The Apple firmware sometimes prefers `/EFI/BOOT/BOOTX64.EFI` over registered
  EFI entries. `bootctl install` writes both, so booting via the Option menu
  picking "EFI Boot" should work. If it doesn't, run `bless` from macOS or use
  rEFInd.
- "tpl" in the prompt was interpreted as **TLP** (the laptop power-management daemon).
