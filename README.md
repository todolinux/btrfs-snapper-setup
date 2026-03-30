# btrfs-snapper-setup

https://youtu.be/PkQF579oXNA

## 🎥 Video tutorial

[![Watch the video](https://img.youtube.com/vi/PkQF579oXNA/maxresdefault.jpg)](https://www.youtube.com/watch?v=PkQF579oXNA)

Convert a standard Linux installation into a Btrfs snapshot-based system
with rollback support (similar to openSUSE).

This project installs the `btrfs-snapsetup` command.

---

## Overview

This tool automates the process of transforming a standard Linux installation
into a snapshot-based system using Btrfs and Snapper.

It provides:

- Automatic Btrfs subvolume layout
- Snapper integration
- GRUB snapshot boot entries (via grub-btrfs)
- Rollback-ready system design
- openSUSE-inspired structure

---

## ⚠ WARNING

This script performs **deep and potentially destructive system modifications**, including:

- Filesystem restructuring
- Btrfs subvolume creation
- Bootloader configuration
- Snapper setup
- `/etc/fstab` modification

Before using:

- Test in a **virtual machine**
- Use a **fresh minimal installation**
- Make a **full system backup**

This tool is intended for users familiar with:

- Linux boot process
- Btrfs filesystem
- System recovery procedures

---

## Features

- Btrfs subvolume automation
- Snapper configuration
- GRUB snapshot integration
- Rollback support
- openSUSE-like layout
- Minimal user interaction

---

## Requirements

Install required packages before running:

``` bash
git rsync inotify-tools gawk build-essential snapper
```
After installing Snapper, do not create the root configuration manually.

## Supported Distributions

Tested on:

Debian 12, Debian 13
Ubuntu 24.4
Linuxmint 22

Other distributions may work but are not officially supported.

## Quick Start
``` bash
git clone https://github.com/YOUR_USER/btrfs-snapper-setup.git
cd btrfs-snapper-setup

chmod +x btrfs-snapsetup

sudo ./btrfs-snapsetup check
sudo ./btrfs-snapsetup install
git clone https://github.com/YOUR_USER/btrfs-snapper-setup.git
cd btrfs-snapper-setup

chmod +x btrfs-snapsetup

sudo ./btrfs-snapsetup check
sudo ./btrfs-snapsetup install
```
## Configuration

The script uses a configuration file called btrfs-snapsetup.conf.

### Example configuration
``` bash
# btrfs-snapsetup.conf

# Target user for /home paths
USER_CONFIG="stech"

# Main root subvolume
ROOT_SUBVOL="@rootfs"

# Top-level mount point (subvolid=5)
MNT_POINT="/mnt/btrfs_top"

# Default subvolume for boot
DEFAULT_SUBVOL_NAME="@rootfs"

# Subvolumes to manage
SUBVOL_DIRS=(
    "/boot"
    "/var"
    "/home"
    "/opt"
    "/root"
    "/usr/local"
    "/home/$USER_CONFIG/Videos"
    "/home/$USER_CONFIG/opencloud"
    "/home/$USER_CONFIG/Pictures"
    "/home/$USER_CONFIG/Nextcloud"
    "/home/$USER_CONFIG/Music"
    "/home/$USER_CONFIG/Downloads"
    "/home/$USER_CONFIG/.local/share/Trash"
    "/home/$USER_CONFIG/.cache/BraveSoftware"
    "/home/$USER_CONFIG/.config/BraveSoftware"
    "/home/$USER_CONFIG/.cache/thorium"
    "/home/$USER_CONFIG/.cache/spotify"
)

# Log file
LOG_FILE="btrfs-snapsetup.log"

# Protected subvolumes
PROTECTED_SUBVOLS=("@boot" "@" "@rootfs")

# Mount options
FSTAB_OPTIONS=(
    "noatime"
    "compress=zstd"
)

# Devices
ROOT_DEV="/dev/sda2"
EFI_DEV="/dev/sda1"
```
## Usage
```bash
btrfs-snapsetup check
btrfs-snapsetup install
btrfs-snapsetup uninstall
btrfs-snapsetup        # check + install
btrfs-snapsetup pre-install  # create @ for Ubuntu - needs to reboot
```
## Ubuntu (Important – Two-Stage Installation)

Ubuntu uses Btrfs differently than Debian. By default, it mounts the top-level subvolume (`ID 5`) as `/` instead of using a dedicated root subvolume like `@`.

Because of this, Snapper cannot work correctly out of the box (snapshots, rollback, and `.snapshots` layout will break).

This script automatically handles Ubuntu using a **two-stage installation process**.

---

### Stage 1 – Pre-install (automatic)

On the first run, if the system is detected as:

- Ubuntu **AND**
- running on subvolume `ID 5`

the script will:

- Create a root subvolume (default: `@`) from `/`
- Update `/etc/fstab` to mount `/` from `@`
- Set the Btrfs default subvolume to `@`

⚠️ The system **must be rebooted** after this step.

---

### Stage 2 – Full installation

After reboot:

1. Verify the system is now using the new root subvolume:

```bash
findmnt /
```
If @ is the result run the script again with no options for full installation:
```bash
sudo ./btrfs-snapsetup.sh
```
The installation will now proceed normally.
## Example output
``` bash
$ sudo btrfs-snapsetup check

✔ Root filesystem OK
✔ Running from root subvolume
✔ Snapper not initialized
✔ Configuration valid

System ready for installation
```
## How It Works

The installation consists of two phases:

### 1. Requirement Checks

The script verifies:

Root filesystem is not a snapshot
Execution with sudo (not direct root)
Required directories exist
Partition configuration is valid
No existing Snapper snapshots
### 2. Installation Tasks

The script performs:

Mount root subvolume
Configure /etc/fstab
Create .snapshots
Install grub-btrfs
Add GRUB entries
Configure Snapper
Create initial snapshot
Perform rollback
Create subvolumes
Restore and update fstab
Reinstall GRUB (chroot)
## Subvolume Layout

Default layout:

``` bash
SUBVOL_DIRS=(
    "/boot"
    "/var"
    "/home"
    "/opt"
    "/root"
    "/usr/local"
)
```
This layout follows the openSUSE Btrfs scheme.

### Why this layout?

These directories are excluded from root snapshots, allowing:

## Booting from read-only snapshots
Safer system recovery
Reduced snapshot size
Boot Behavior

After installation, GRUB includes:

Default Btrfs system (auto)
Original system (@rootfs)
Snapshot entries (via grub-btrfs)

Snapshots allow system recovery in case of failure.

⚠ Note: rollback does not fully restore system state due to excluded subvolumes.

## Special Case: /boot Subvolume

This tool creates a dedicated @boot subvolume.

## Advantages
Always boots latest kernel
No GRUB reinstall needed after snapshots
## Disadvantages
Kernel rollback not supported
## Uninstall

Must be executed from the root subvolume.

Removes:

Snapper snapshots
.snapshots
Created subvolumes
grub-btrfs daemon

Restores:

/etc/fstab

⚠ @boot is NOT removed.

## Limitations
Not compatible with complex existing Btrfs layouts
No LUKS/LVM support
No kernel rollback
Manual permission fixes may be required
## Manual Full Reversion

To fully revert:

Remove @boot from fstab
Reinstall GRUB in /@rootfs/boot
Reboot

Manual recovery from GRUB may be required.

## Notes About Permissions

If multiple users are included in SUBVOL_DIRS:

Permissions must be adjusted manually
Files are created using the executing user
## Contributing

Pull requests are welcome.

For major changes, please open an issue first.

## License

This project is licensed under the GPL License.
