# btrfs-snapper-setup

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

```bash
git rsync inotify-tools gawk build-essential snapper
