# Basic Arch installation Scripts

The Idea is to have a set of scripts that install a basic encrypted arch-linux installation with btrfs on all my hardware.
Specific scripts for each computer that I own.

The basic hardware installation is done, I want to be able to install specific packages for each usecase in a second step.

## Macbook 2012


### Prompt:

generate an install script for arch linux on a 2012 non-retina 13 inch macbook pro without dedicated gpu. Modified to hold two SSDs each 256gb capacity. I want to do an encrypted Arch linux installation. This should span over both disks using btrfs. proprietary wlan hardware modules shall be loaded as well. for booting I prefer systemd boot. add acpi and tlp add bluetooth, setup for a german keyboard layout an ssh deamon. use the lts-kernel instead of the normal one, add bluetooth, networkmanager including an applet, git, yay, commandline-tools. prompt for the user-name and host-machine name. generate a pair of ssh-keys for the user and include the machines name and the date of creation into the filename of that key, deactivate the root account. add the user to the sudo group. use zram. add macbook optimizations.  enable trim for the ssd and other reasonable hardware tweaks.
