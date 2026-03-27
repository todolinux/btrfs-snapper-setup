#!/bin/bash
set -euo pipefail

CONF_FILE="btrfs-syssetup.conf"

# Load configuration
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
else
    echo "[ERROR] Configuration file '$CONF_FILE' not found."
    exit 1
fi

# Validate LOG_FILE
: "${LOG_FILE:?LOG_FILE is not set in config}"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Define log_message
log_message() {
    local LEVEL="$1"
    local MSG="$2"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$LEVEL] $MSG" >> "$LOG_FILE" || true
    fi
    echo "[$LEVEL] $MSG"
}

# Verify root/sudo
if [[ "$EUID" -ne 0 ]]; then
    log_message "ERROR" "This script must be run with sudo or as root."
    exit 1
fi

check_btrfs_root() {
    if findmnt -n -o FSTYPE / | grep -q btrfs; then
        log_message "OK" "Root FS: Btrfs detected."
        return 0
    else
        log_message "FAIL" "Root FS: Btrfs not detected."
        log_message "ERROR" "Root must be a Btrfs filesystem."
        return 1
    fi
}

check_user_context() {
    local current_real_user=${SUDO_USER:-$USER}

    if [ "$current_real_user" = "$USER_CONFIG" ]; then
        log_message "OK" "User Context: $USER_CONFIG verified."
        return 0
    else
        log_message "FAIL" "User Context mismatch."
        log_message "ERROR" "Running as $current_real_user, expected $USER_CONFIG."
        return 1
    fi
}

check_subvol_level5() {
    # 1. Obtain subvol ID mounted on /
    local current_id
    current_id=$(btrfs subvolume show / 2>>"$LOG_FILE" | grep "Subvolume ID:" | awk '{print $3}')

    # 2. Obtain subvol parent ID
    local parent_id
    parent_id=$(btrfs subvolume show / 2>>"$LOG_FILE" | grep "Parent ID:" | awk '{print $3}')

    # 3. Verify ierarchy
    if [[ "$current_id" == "5" ]] || [[ "$parent_id" == "5" ]]; then
        log_message "OK" "Boot Context: Level 1 Subvolume detected."
        log_message "INFO" "Running on a top-level subvolume (ID: $current_id, Parent: $parent_id)."
        return 0
    else
        log_message "FAIL" "Boot Context: Invalid level."
        log_message "ERROR" "You are in a nested snapshot (Parent ID: $parent_id)."
        log_message "INFO" "Please boot into a top-level subvolume before proceeding."
        return 1
    fi
}

mount_top_level() {
    local dev="$1"
    local status="OK"

    # 1. Ensure the target mount point directory exists
    mkdir -p "$MNT_POINT" >> "$LOG_FILE" 2>&1

    # 2. Always attempt to unmount first (if mounted)
    if mountpoint -q "$MNT_POINT"; then
        log_message "INFO" "Mount point $MNT_POINT is mounted. Attempting to unmount..."
        if ! umount -l "$MNT_POINT" >> "$LOG_FILE" 2>&1; then
            log_message "FAIL" "Mounting Btrfs Top Level (ID 5) failed."
            log_message "ERROR" "Could not unmount existing $MNT_POINT"
            return 1
        fi
        status="RE-MOUNTED"
    fi

    # 3. Perform the actual mount operation using subvolid=5
    log_message "ACTION" "Mounting $dev (ID 5) to $MNT_POINT..."
    if mount -o subvolid=5 "$dev" "$MNT_POINT" >> "$LOG_FILE" 2>&1; then
        log_message "OK" "Btrfs Top Level (ID 5) mounted [$status]."
        log_message "INFO" "Successfully mounted $dev (ID 5) to $MNT_POINT"
        return 0
    else
        log_message "FAIL" "Mounting Btrfs Top Level (ID 5) failed."
        log_message "ERROR" "Failed to mount $dev. Check system logs."
        return 1
    fi
}

check_list_integrity() {
    local count=${#SUBVOL_DIRS[@]}
    local has_boot=0

    log_message "INFO" "Checking subvolume list integrity..."

    # 1. Search for /boot in the array to ensure system bootability
    for dir in "${SUBVOL_DIRS[@]}"; do
        if [[ "$dir" == "/boot" ]]; then
            has_boot=1
            break
        fi
    done

    # 2. Validation Logic
    if [[ $count -eq 0 ]]; then
        log_message "FAIL" "Subvolume List Integrity check failed."
        log_message "ERROR" "SUBVOL_DIRS array is empty in your configuration file."
        return 1
    elif [[ $has_boot -eq 0 ]]; then
        log_message "FAIL" "Subvolume List Integrity check failed."
        log_message "ERROR" "/boot is missing from SUBVOL_DIRS (it is required for this setup)."
        return 1
    else
        log_message "OK" "Subvolume list validated ($count items found, including /boot)."
        log_message "INFO" "Integrity check passed. Ready to process $count directories."
        return 0
    fi
}

verify_folder_parent() {
    for DIR in "${SUBVOL_DIRS[@]}"; do
        PARENT_DIR=$(dirname "$DIR")
        if [ ! -d "$PARENT_DIR" ]; then
            log_message "ERROR" "Parent directory '$PARENT_DIR' does not exist."
            log_message "ERROR" "Please create it manually with the correct ownership before continuing."
            log_message "ERROR" "Example: mkdir -p $PARENT_DIR"
            return 1
        fi
    done

    log_message "INFO" "All parent directories exist."
}

check_dependencies() {
    log_message "INFO" "Checking system dependencies..."

    declare -A tools=(
        ["btrfs"]="btrfs-progs"
        ["snapper"]="snapper"
        ["git"]="git"
        ["make"]="build-essential"
        ["inotifywait"]="inotify-tools"
        ["gawk"]="gawk"
        ["rsync"]="rsync"
    )

    local missing_pkgs=()
    local bin

    for bin in "${!tools[@]}"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing_pkgs+=("${tools[$bin]}")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        log_message "INFO" "All dependencies installed."
        return 0
    fi

    log_message "ERROR" "Missing packages: ${missing_pkgs[*]}"

    echo "--------------------------------------------------------"
    echo "Run:"
    echo "sudo apt update && sudo apt install -y ${missing_pkgs[*]}"
    echo "--------------------------------------------------------"

    exit 1
}

check_no_snapper_configs() {
    # 1. Check if snapper command exists
    if ! command -v snapper &> /dev/null; then
        log_message "OK" "Snapper is not installed. No configurations possible."
        return 0
    fi

    # 2. Count active configurations
    # snapper list-configs returns 2 header lines even if empty.
    # If line count is greater than 2, configurations exist.
    local config_count
    config_count=$(sudo snapper list-configs | wc -l)

    if [ "$config_count" -le 2 ]; then
        log_message "OK" "No Snapper configurations found. System is clean."
        return 0
    else
        log_message "FAIL" "Active Snapper configurations detected!"
        log_message "ERROR" "Please remove all Snapper configs before proceeding."

        # Optional: Show which configs were found to help the user
        snapper list-configs >> "$LOG_FILE" 2>&1

        return 1
    fi
}

# Detect the current root subvolume (returns only the name)
get_current_subvol() {
    findmnt -n -o SOURCE / | sed 's|.*/||; s|\[||; s|\]||'
}

# Detect root device without user prompt
detect_root_device() {
    findmnt -n -o SOURCE / | cut -d'[' -f1
}

# Detect EFI device automatically
detect_efi_device() {
    findmnt -n -o SOURCE /boot/efi 2>/dev/null || true
}

verify_conf_vars() {
    echo "===== Configuration Verification ====="

    # Detect system values
    ROOT_DEV_DETECTED=$(detect_root_device)
    EFI_DEV_DETECTED=$(detect_efi_device)
    MNT_POINT_DETECTED="$MNT_POINT"
    ROOT_SUBVOL_DETECTED=$(get_current_subvol)
    USER_DETECTED="$USER_CONFIG"

    ALL_OK=true

    # Helper function to compare variables
    check_var() {
        local NAME="$1"
        local CONF_VAL="$2"
        local DETECTED_VAL="$3"

        if [[ "$CONF_VAL" == "$DETECTED_VAL" ]]; then
            STATUS="[OK]"
        else
            STATUS="[FAIL]"
            ALL_OK=false
        fi
        printf "%-12s in conf: %-15s | Detected: %-15s %s\n" "$NAME" "$CONF_VAL" "$DETECTED_VAL" "$STATUS"
    }

    # Check all critical variables
    check_var "ROOT_DEV" "$ROOT_DEV" "$ROOT_DEV_DETECTED"
    check_var "EFI_DEV" "$EFI_DEV" "$EFI_DEV_DETECTED"
    check_var "MNT_POINT" "$MNT_POINT" "$MNT_POINT_DETECTED"
    check_var "ROOT_SUBVOL" "$ROOT_SUBVOL" "$ROOT_SUBVOL_DETECTED"
    check_var "USER_CONFIG" "$USER_CONFIG" "$USER_DETECTED"

    echo "======================================"

    # Prompt final based on results
    if $ALL_OK; then
        read -rp "All values match the system. Continue using the config values? [Y/n]: " CONFIRM
        CONFIRM=${CONFIRM:-Y}
    else
        read -rp "Some values do not match the system. Continue anyway? [y/N]: " CONFIRM
        CONFIRM=${CONFIRM:-N}
    fi

    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        log_message "ERROR" "User chose NOT to continue due to config mismatches."
        exit 1
    fi

    log_message "INFO" "User accepted configuration values."
    return 0
}

# UNINSTALL FUNCTIONS

set_default_subvolume_id5() {
    local status="OK"

    log_message "ACTION" "Setting Btrfs default subvolume to ID 5..."

    if btrfs subvolume set-default 5 / >> "$LOG_FILE" 2>&1; then
        log_message "OK" "Default subvolume successfully set to ID 5."
        return 0
    else
        log_message "FAIL" "Failed to set default subvolume to ID 5."
        log_message "ERROR" "Check Btrfs state and ensure the filesystem is mounted correctly."
        return 1
    fi
}

delete_subvolumes_from_list() {
    log_message "INFO" "Removing subvolumes from list..."
    local error_flag=0
    PROTECTED_SUBVOLS=(
    "@"
    "@rootfs"
    "@boot"
)

    for DIR in "${SUBVOL_DIRS[@]}"; do
        CLEAN_PATH=$(echo "$DIR" | sed 's|^/||' | tr '/' '_')
        SUBVOL_NAME="@${CLEAN_PATH}"
        TARGET_PATH="$MNT_POINT/$ROOT_SUBVOL/$SUBVOL_NAME"

        # Saltamos subvolúmenes protegidos
        for P in "${PROTECTED_SUBVOLS[@]}"; do
            if [ "$SUBVOL_NAME" = "$P" ]; then
                log_message "SKIP" "Subvolume $SUBVOL_NAME is protected. Skipping."
                continue 2
            fi
        done

        log_message "INFO" "Processing delete for $TARGET_PATH"

        if btrfs subvolume show "$TARGET_PATH" &>/dev/null; then
            log_message "ACTION" "Deleting subvolume: $TARGET_PATH"
            # Redirigimos la salida de btrfs al log file directamente para no ensuciar la consola
            if btrfs subvolume delete "$TARGET_PATH" >> "$LOG_FILE" 2>&1; then
                log_message "OK" "Subvolume $SUBVOL_NAME deleted."
            else
                log_message "ERROR" "Failed to delete $TARGET_PATH"
                error_flag=1
            fi
        else
            log_message "INFO" "Subvolume not found, skipping: $TARGET_PATH"
        fi
    done

    if [ "$error_flag" -eq 0 ]; then
        log_message "OK" "Removing subvolumes task completed successfully."
        return 0
    else
        log_message "FAIL" "Some subvolumes could not be removed."
        return 1
    fi
}

delete_snapshots_subvolumes() {
    local snapshots_dir="$MNT_POINT/$ROOT_SUBVOL/.snapshots"
    local system_mount_point="/.snapshots"
    local error_flag=0

	check_subvol_level5

    log_message "INFO" "Searching for snapshots in $snapshots_dir..."

    # 1. Check if the snapshots subvolume exists in the Btrfs tree
    if [ -d "$snapshots_dir" ]; then
        log_message "INFO" "Snapshots directory found: $snapshots_dir"

        # 2. Iterate and delete each individual snapshot subvolume
        # Snapper stores snapshots in numbered folders (e.g., .snapshots/1/snapshot)
        for SNAP_FOLDER in "$snapshots_dir"/*; do
            if [ -d "$SNAP_FOLDER/snapshot" ]; then
                local snap_id
                snap_id=$(basename "$SNAP_FOLDER")
                log_message "ACTION" "Deleting snapshot subvolume ID: $snap_id"

                if ! btrfs subvolume delete "$SNAP_FOLDER/snapshot" >> "$LOG_FILE" 2>&1; then
                    log_message "ERROR" "Failed to delete snapshot subvolume in $SNAP_FOLDER"
                    error_flag=1
                fi
            fi
        done

        # 3. Delete the parent .snapshots subvolume itself
        log_message "ACTION" "Deleting the main .snapshots subvolume..."
        if btrfs subvolume delete "$snapshots_dir" >> "$LOG_FILE" 2>&1; then
            log_message "OK" "Main .snapshots subvolume removed."
        else
            log_message "ERROR" "Could not delete $snapshots_dir. It might not be a subvolume or is busy."
            error_flag=1
        fi
    else
        log_message "INFO" "No snapshots subvolume found in Btrfs tree. Skipping."
    fi

    # 4. Remove the physical directory from the root system (/.snapshots)
    log_message "INFO" "Checking for physical mount point: $system_mount_point"
    if [ -d "$system_mount_point" ]; then
        # Ensure it's not mounted before deleting the directory
        if mountpoint -q "$system_mount_point"; then
            log_message "ACTION" "Unmounting $system_mount_point before removal..."
            umount -l "$system_mount_point" >> "$LOG_FILE" 2>&1
        fi

        log_message "ACTION" "Removing physical directory: $system_mount_point"
        if rm -rf "$system_mount_point" >> "$LOG_FILE" 2>&1; then
            log_message "OK" "Physical directory $system_mount_point removed."
        else
            log_message "ERROR" "Failed to remove directory $system_mount_point"
            error_flag=1
        fi
    fi

    # Final result
    if [ "$error_flag" -eq 0 ]; then
        log_message "OK" "Snapshots and directory cleanup completed successfully."
        return 0
    else
        log_message "FAIL" "Errors occurred during snapshots cleanup. Check $LOG_FILE"
        return 1
    fi
}

uninstall_snapper() {
    log_message "ACTION" "Attempting to completely remove Snapper from the system..."

    if ! command -v snapper &> /dev/null; then
        log_message "OK" "Snapper is not installed. Nothing to remove."
        return 0
    fi

    log_message "INFO" "Running 'apt purge snapper' to remove binaries and configurations..."

    if sudo apt-get purge -y snapper >> "$LOG_FILE" 2>&1; then
        log_message "OK" "Snapper package purged successfully."
    else
        log_message "FAIL" "Failed to purge Snapper package!"
        log_message "ERROR" "Check your system or run: sudo apt-get purge snapper"
        return 1
    fi

    log_message "INFO" "Cleaning up any leftover Snapper configuration directories..."
    sudo rm -rf /etc/snapper/configs /var/lib/snapper/configs >> "$LOG_FILE" 2>&1 || true

    log_message "OK" "Snapper completely removed and configuration cleaned."
}

create_subvol_snapshots() {
    local target_path="$MNT_POINT/$ROOT_SUBVOL/.snapshots"
    local mount_point="/.snapshots"

    # 1. Create the .snapshots subvolume if it doesn't exist
    log_message "INFO" "Checking for .snapshots subvolume at $target_path..."
    if ! btrfs subvolume show "$target_path" &>/dev/null; then
        log_message "ACTION" "Creating subvolume: .snapshots"
        if btrfs subvolume create "$target_path" >> "$LOG_FILE" 2>&1; then
            log_message "OK" ".snapshots subvolume created successfully."
        else
            log_message "FAIL" "Could not create Btrfs subvolume at $target_path"
            log_message "ERROR" "Check disk space or Btrfs permissions."
            return 1
        fi
    else
        log_message "OK" ".snapshots subvolume already exists."
    fi

    # 2. Prepare the system mount point directory
    log_message "INFO" "Ensuring mount point $mount_point exists..."
    mkdir -p "$mount_point" >> "$LOG_FILE" 2>&1

    # 3. Mount the subvolume (checking if already mounted first)
    log_message "INFO" "Checking if $mount_point is already mounted..."
    if mountpoint -q "$mount_point"; then
        log_message "OK" "$mount_point is already mounted."
    else
        log_message "ACTION" "Mounting $target_path to $mount_point..."
        # We use $ROOT_DEV as the source device for the mount operation
        if mount -o subvol="/$ROOT_SUBVOL/.snapshots" "$ROOT_DEV" "$mount_point" >> "$LOG_FILE" 2>&1; then
            log_message "OK" "Successfully mounted /.snapshots."
        else
            log_message "FAIL" "Failed to mount .snapshots to $mount_point."
            log_message "ERROR" "Device: $ROOT_DEV, Subvol: /$ROOT_SUBVOL/.snapshots"
            return 1
        fi
    fi

    log_message "INFO" "Subvolume .snapshots is ready for grub-btrfs integration."
    return 0
}

install_grub_btrfs() {
    local error_flag=0

    log_message "INFO" "Starting grub-btrfs setup..."

    # 1. Check if the binary is already installed in the system PATH
    if command -v grub-btrfsd &> /dev/null; then
        log_message "INFO" "grub-btrfs is already installed. Ensuring service is active..."

        # Enable and start the service immediately if it exists
        if systemctl enable --now grub-btrfsd.service >> "$LOG_FILE" 2>&1; then
            log_message "OK" "grub-btrfs service enabled and started."
            return 0
        else
            log_message "ERROR" "Failed to enable/start existing grub-btrfs service."
            return 1
        fi
    fi

    # 2. If not installed, proceed with full installation from Git
    log_message "ACTION" "grub-btrfs not found. Proceeding with full installation..."

    # Clean up any previous interrupted clones
    if [ -d "/tmp/grub-btrfs" ]; then
        log_message "INFO" "Removing previous /tmp/grub-btrfs..."
        rm -rf /tmp/grub-btrfs >> "$LOG_FILE" 2>&1 || error_flag=1
    fi

    # Clone the official repository
    log_message "ACTION" "Cloning grub-btrfs repository..."
    if git clone https://github.com/Antynea/grub-btrfs.git /tmp/grub-btrfs >> "$LOG_FILE" 2>&1; then
        log_message "OK" "Git clone successful."
    else
        log_message "ERROR" "Git clone failed."
        error_flag=1
    fi

    # Compile and install using make
    if [ "$error_flag" -eq 0 ]; then
        log_message "ACTION" "Installing grub-btrfs via make..."
        pushd /tmp/grub-btrfs > /dev/null
        if make install >> "$LOG_FILE" 2>&1; then
            log_message "OK" "Make install completed successfully."
        else
            log_message "ERROR" "Make install failed."
            error_flag=1
        fi
        popd > /dev/null
    fi

    # Enable and start the service after a fresh installation
    if [ "$error_flag" -eq 0 ]; then
        log_message "ACTION" "Enabling and starting service..."
        if systemctl enable --now grub-btrfsd.service >> "$LOG_FILE" 2>&1; then
            log_message "OK" "grub-btrfs installed and service started."
        else
            log_message "ERROR" "Installation succeeded but service failed to start."
            error_flag=1
        fi
    fi

    # Final execution result check
    if [ "$error_flag" -eq 0 ]; then
        log_message "OK" "grub-btrfs setup finished successfully."
        return 0
    else
        log_message "FAIL" "grub-btrfs setup failed. Check log: $LOG_FILE"
        return 1
    fi
}

create_default_grub_entry() {
    local OUTPUT_FILE="/etc/grub.d/07_linux"

    # 1. Get UUID for the specific device passed as an argument
    local UUID
    UUID=$(blkid -s UUID -o value "$ROOT_DEV")

    if [ -z "$UUID" ]; then
        log_message "ERROR" "Could not get UUID for $ROOT_DEV"
        return 1
    fi

    log_message "INFO" "Generating $OUTPUT_FILE for device $ROOT_DEV..."

    # 2. Generate the GRUB script file using a here-document
    # This creates a dynamic script that GRUB will execute during update-grub
    sudo tee "$OUTPUT_FILE" > /dev/null <<EOF
#!/bin/bash
# Locate the most recent kernel and initrd
LATEST_KERNEL=\$(ls -v /boot/vmlinuz-* 2>/dev/null | tail -n 1 | xargs basename 2>/dev/null)
LATEST_INITRD=\$(ls -v /boot/initrd.img-* 2>/dev/null | tail -n 1 | xargs basename 2>/dev/null)

# Exit if no kernel is found
if [ -z "\$LATEST_KERNEL" ]; then
    exit 0
fi

cat << INNER_EOF
menuentry "Debian 13 (Default BTRFS Subvolume - Auto)" --class linux --class gnu-linux {
    insmod gzio
    insmod part_gpt
    insmod btrfs

    # Search by UUID
    search --no-floppy --fs-uuid --set=root $UUID

    echo "Loading kernel \$LATEST_KERNEL from default subvolume..."
    linux /@rootfs/boot/\$LATEST_KERNEL root=UUID=$UUID rw quiet splash
    initrd /@rootfs/boot/\$LATEST_INITRD
}
INNER_EOF
EOF

    # 3. Make the script executable so GRUB can include it
    sudo chmod +x "$OUTPUT_FILE"

    if [ $? -eq 0 ]; then
        log_message "OK" "Default GRUB entry created successfully at $OUTPUT_FILE."
        return 0
    else
        log_message "FAIL" "Failed to set permissions on $OUTPUT_FILE."
        return 1
    fi
}

update_fstab() {
    log_message "INFO" "=== Updating /etc/fstab ==="
    log_message "INFO" "ROOT_DEV=$ROOT_DEV"

    # Backup original only the first time
    if [ ! -f /etc/fstab_original ]; then
        log_message "INFO" "Creating backup of the original fstab at /etc/fstab_original"
        cp /etc/fstab /etc/fstab_original
    else
        log_message "INFO" "Backup already exists: /etc/fstab_original"
    fi

    # Detectar UUID del root
    UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    TMP_FSTAB="/etc/fstab"

    # Mantener todo excepto la línea del root /
    grep -v -E '^[^#].*\s+/\s+' /etc/fstab_original > "$TMP_FSTAB"

    # Agregar root y subvolúmenes
    echo "UUID=$UUID / btrfs defaults 0 0" >> "$TMP_FSTAB"
    log_message "INFO" "Added root / entry to fstab"

    for DIR in "${SUBVOL_DIRS[@]}"; do
        CLEAN_PATH=$(echo "$DIR" | sed 's|^/||' | tr '/' '_')
        SUBVOL_NAME="@${CLEAN_PATH}"
        echo "UUID=$UUID $DIR btrfs noatime,compress=zstd,subvol=/$ROOT_SUBVOL/$SUBVOL_NAME 0 2" >> "$TMP_FSTAB"
        log_message "INFO" "Added subvolume $DIR -> $SUBVOL_NAME to fstab"
    done

    # Agregar subvolumen .snapshots
    echo "UUID=$UUID /.snapshots btrfs noatime,compress=zstd,subvol=/$ROOT_SUBVOL/.snapshots 0 0" >> "$TMP_FSTAB"
    log_message "INFO" "Added /.snapshots subvolume to fstab"

    # Permisos
    chmod 644 "$TMP_FSTAB"
    log_message "INFO" "/etc/fstab updated successfully"
}

ensure_snapper_installed() {
    local status="OK"

    # 1. Check if snapper is already installed
    if command -v snapper >/dev/null 2>&1; then
        log_message "OK" "Snapper is already installed."
        return 0
    fi

    log_message "INFO" "Snapper not found. Attempting installation..."

    # 2. Detect package manager and install
    if command -v apt >/dev/null 2>&1; then
        log_message "ACTION" "Installing snapper using apt..."
        if apt update >> "$LOG_FILE" 2>&1 && apt install -y snapper >> "$LOG_FILE" 2>&1; then
            status="INSTALLED"
        else
            log_message "FAIL" "Snapper installation failed."
            log_message "ERROR" "apt failed to install snapper."
            return 1
        fi

    elif command -v dnf >/dev/null 2>&1; then
        log_message "ACTION" "Installing snapper using dnf..."
        if dnf install -y snapper >> "$LOG_FILE" 2>&1; then
            status="INSTALLED"
        else
            log_message "FAIL" "Snapper installation failed."
            log_message "ERROR" "dnf failed to install snapper."
            return 1
        fi

    elif command -v pacman >/dev/null 2>&1; then
        log_message "ACTION" "Installing snapper using pacman..."
        if pacman -Sy --noconfirm snapper >> "$LOG_FILE" 2>&1; then
            status="INSTALLED"
        else
            log_message "FAIL" "Snapper installation failed."
            log_message "ERROR" "pacman failed to install snapper."
            return 1
        fi

    elif command -v zypper >/dev/null 2>&1; then
        log_message "ACTION" "Installing snapper using zypper..."
        if zypper --non-interactive install snapper >> "$LOG_FILE" 2>&1; then
            status="INSTALLED"
        else
            log_message "FAIL" "Snapper installation failed."
            log_message "ERROR" "zypper failed to install snapper."
            return 1
        fi

    else
        log_message "FAIL" "Snapper installation failed."
        log_message "ERROR" "No supported package manager found."
        return 1
    fi

    # 3. Final verification
    if command -v snapper >/dev/null 2>&1; then
        log_message "OK" "Snapper installed successfully [$status]."
        return 0
    else
        log_message "FAIL" "Snapper installation failed."
        log_message "ERROR" "snapper command still not available after installation."
        return 1
    fi
}

initialize_snapper() {
    log_message "INFO" "Unmounting /.snapshots and deleting existing subvolume for Snapper initialization..."
    umount /.snapshots 2>/dev/null || true
    if btrfs subvolume show "$MNT_POINT/@rootfs/.snapshots" &>/dev/null; then
        btrfs subvolume delete "$MNT_POINT/@rootfs/.snapshots"
        log_message "INFO" "Deleted existing .snapshots subvolume"
    else
        log_message "INFO" ".snapshots subvolume does not exist, skipping deletion"
    fi

    log_message "INFO" "Preparing Snapper configuration..."
    snapper -c root create-config /
    log_message "INFO" "Snapper root configuration initialized"
}

snapper_snapshot1() {
    log_message "INFO" "Creating Snapshot #1 (system base)..."
    snapper -c root create --description "Snapshot#1" --type single
    log_message "INFO" "Snapshot #1 created"
}

snapper_rollback() {
    log_message "INFO" "Rolling back to Snapshot #1..."
    snapper --ambit classic rollback 1
    log_message "INFO" "Rollback completed"
}

create_roofs_fstab() {
    UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    TMP_FSTAB="/etc/fstab"

    log_message "INFO" "Updating /etc/fstab from original backup..."
    if [ ! -f /etc/fstab_original ]; then
        log_message "ERROR" "Original file /etc/fstab_original not found. Manual editing required!"
        return 1
    else
        cp /etc/fstab_original /etc/fstab
        log_message "INFO" "Copied /etc/fstab_original to /etc/fstab"
        # Agregar línea de /boot subvol
        echo "UUID=$UUID /boot btrfs noatime,compress=zstd,subvol=/$ROOT_SUBVOL/@boot 0 0" >> "$TMP_FSTAB"
        log_message "INFO" "Added /boot subvolume for $ROOT_SUBVOL in /etc/fstab"
    fi

    chmod 644 "$TMP_FSTAB"
    log_message "INFO" "/etc/fstab ($ROOT_SUBVOL) updated successfully"
}

install_new_grub() {

    # Updating grub
    log_message "INFO" "Excecuting grub-mkconfig -o /boot/grub/grub.cfg"
    grub-mkconfig -o /boot/grub/grub.cfg

}

create_subvolumes() {
    log_message "INFO" "Creating subvolumes from the configuration list..."
    local error_flag=0

    for DIR in "${SUBVOL_DIRS[@]}"; do
        CLEAN_PATH=$(echo "$DIR" | sed 's|^/||' | tr '/' '_')
        SUBVOL_NAME="@${CLEAN_PATH}"
        TARGET_PATH="$MNT_POINT/$ROOT_SUBVOL/$SUBVOL_NAME"

        log_message "INFO" "Processing: $DIR -> $TARGET_PATH"

        # 🔒 Check that parent directory exists
        PARENT_DIR=$(dirname "$DIR")
        if [ ! -d "$PARENT_DIR" ]; then
            log_message "ERROR" "Parent directory does not exist: $PARENT_DIR"
            error_flag=1
            continue
        fi

        # 📁 Create mount point ONLY if missing (no -p)
        if [ ! -d "$DIR" ]; then
            log_message "ACTION" "Creating mount point: $DIR"

            if [[ "$DIR" == /home/$USER_CONFIG/* ]]; then
                sudo -u "$USER_CONFIG" mkdir "$DIR" >> "$LOG_FILE" 2>&1 || {
                    log_message "ERROR" "Failed to create $DIR as $USER_CONFIG"
                    error_flag=1
                    continue
                }
            else
                mkdir "$DIR" >> "$LOG_FILE" 2>&1 || {
                    log_message "ERROR" "Failed to create $DIR"
                    error_flag=1
                    continue
                }
            fi
        fi

        # 📦 Create subvolume
        if ! btrfs subvolume show "$TARGET_PATH" &>/dev/null; then
            log_message "ACTION" "Creating Btrfs subvolume: $TARGET_PATH"

            if btrfs subvolume create "$TARGET_PATH" >> "$LOG_FILE" 2>&1; then
                if [[ "$DIR" == /home/* || "$DIR" == /home ]]; then
                    chown "$SUDO_USER:$SUDO_USER" "$TARGET_PATH" >> "$LOG_FILE" 2>&1
                    log_message "INFO" "Ownership set to $SUDO_USER for $TARGET_PATH"
                fi
            else
                log_message "ERROR" "Failed to create subvolume: $TARGET_PATH"
                error_flag=1
                continue
            fi
        else
            log_message "INFO" "Subvolume already exists: $TARGET_PATH"
        fi

        # 🔄 Migrate data
        if [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
            log_message "ACTION" "Migrating data from $DIR to $TARGET_PATH..."

            if rsync -aAX "$DIR/" "$TARGET_PATH/" >> "$LOG_FILE" 2>&1; then
                log_message "OK" "Migration successful for $DIR"
            else
                log_message "ERROR" "Data migration failed for $DIR"
                error_flag=1
            fi
        else
            log_message "INFO" "Directory $DIR is empty. No data to migrate."
        fi
    done

    # 📊 Final status
    if [ "$error_flag" -eq 0 ]; then
        log_message "OK" "All subvolumes created and data migrated successfully."
        return 0
    else
        log_message "FAIL" "Subvolume creation encountered errors. Check $LOG_FILE"
        return 1
    fi
}

install_grub_ON_chroot() {
    # 1. Define local paths for the chroot environment
    # Using existing variables from your script's context
    local chroot_dir="/mnt/chroot"
    local error_flag=0

    log_message "INFO" "Starting GRUB repair/installation via chroot..."

    # 2. Prepare the chroot structure
    mkdir -p "$chroot_dir" >> "$LOG_FILE" 2>&1

    # 3. Mount the main root subvolume and necessary secondary subvolumes
    log_message "ACTION" "Mounting Btrfs subvolumes into $chroot_dir..."

    # Mount Root
    mount -o subvol="/$ROOT_SUBVOL" "$ROOT_DEV" "$chroot_dir" >> "$LOG_FILE" 2>&1 || error_flag=1

    # Ensure secondary paths exist inside the chroot before mounting
    mkdir -p "$chroot_dir/boot" "$chroot_dir/var" "$chroot_dir/boot/efi" >> "$LOG_FILE" 2>&1

    # Mount /boot, /var and EFI partition
    mount -o subvol="/$ROOT_SUBVOL/@boot" "$ROOT_DEV" "$chroot_dir/boot" >> "$LOG_FILE" 2>&1 || error_flag=1
    mount -o subvol="/$ROOT_SUBVOL/@var" "$ROOT_DEV" "$chroot_dir/var" >> "$LOG_FILE" 2>&1 || error_flag=1
    mount "$EFI_DEV" "$chroot_dir/boot/efi" >> "$LOG_FILE" 2>&1 || error_flag=1

    # 4. Bind mount virtual filesystems (Kernel APIs)
    # Required for grub-install to detect the hardware and firmware
    log_message "INFO" "Binding virtual filesystems (/dev, /proc, /sys...)"
    for i in /dev /dev/pts /proc /sys /run; do
        mount --bind "$i" "$chroot_dir$i" >> "$LOG_FILE" 2>&1 || error_flag=1
    done

    # 5. Execute GRUB installation inside the chroot
    if [ "$error_flag" -eq 0 ]; then
        log_message "ACTION" "Entering chroot to install GRUB..."

        chroot "$chroot_dir" /bin/bash <<EOF >> "$LOG_FILE" 2>&1
            set -e
            echo "Installing GRUB for x86_64-efi..."
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck

            echo "Generating main grub.cfg..."
            grub-mkconfig -o /boot/grub/grub.cfg
EOF

        if [ $? -eq 0 ]; then
            log_message "OK" "GRUB installed and configured successfully inside chroot."
        else
            log_message "FAIL" "GRUB installation failed inside chroot."
            error_flag=1
        fi
    fi

    # 6. Cleanup: Unmount everything in reverse order
    log_message "INFO" "Cleaning up mount points (lazy unmount)..."

    # Unmount virtual filesystems
    for i in /run /sys /proc /dev/pts /dev; do
        umount -l "$chroot_dir$i" 2>/dev/null
    done

    # Unmount physical and Btrfs paths
    umount -l "$chroot_dir/boot/efi" 2>/dev/null
    umount -l "$chroot_dir/boot" 2>/dev/null
    umount -l "$chroot_dir/var" 2>/dev/null
    umount -l "$chroot_dir" 2>/dev/null

    # 7. Final validation
    if [ "$error_flag" -eq 0 ]; then
        log_message "OK" "GRUB installed successfully."
        return 0
    else
        log_message "FAIL" "GRUB install encountered errors. Check $LOG_FILE"
        return 1
    fi
}

delete_snapshots_subvolumes() {
    local snapshots_dir="$MNT_POINT/$ROOT_SUBVOL/.snapshots"
    local system_mount_point="/.snapshots"
    local error_flag=0

	check_subvol_level5

    log_message "INFO" "Searching for snapshots in $snapshots_dir..."

    # 1. Check if the snapshots subvolume exists in the Btrfs tree
    if [ -d "$snapshots_dir" ]; then
        log_message "INFO" "Snapshots directory found: $snapshots_dir"

        # 2. Iterate and delete each individual snapshot subvolume
        # Snapper stores snapshots in numbered folders (e.g., .snapshots/1/snapshot)
        for SNAP_FOLDER in "$snapshots_dir"/*; do
            if [ -d "$SNAP_FOLDER/snapshot" ]; then
                local snap_id
                snap_id=$(basename "$SNAP_FOLDER")
                log_message "ACTION" "Deleting snapshot subvolume ID: $snap_id"

                if ! btrfs subvolume delete "$SNAP_FOLDER/snapshot" >> "$LOG_FILE" 2>&1; then
                    log_message "ERROR" "Failed to delete snapshot subvolume in $SNAP_FOLDER"
                    error_flag=1
                fi
            fi
        done

        # 3. Delete the parent .snapshots subvolume itself
        log_message "ACTION" "Deleting the main .snapshots subvolume..."
        if btrfs subvolume delete "$snapshots_dir" >> "$LOG_FILE" 2>&1; then
            log_message "OK" "Main .snapshots subvolume removed."
        else
            log_message "ERROR" "Could not delete $snapshots_dir. It might not be a subvolume or is busy."
            error_flag=1
        fi
    else
        log_message "INFO" "No snapshots subvolume found in Btrfs tree. Skipping."
    fi

    # 4. Remove the physical directory from the root system (/.snapshots)
    log_message "INFO" "Checking for physical mount point: $system_mount_point"
    if [ -d "$system_mount_point" ]; then
        # Ensure it's not mounted before deleting the directory
        if mountpoint -q "$system_mount_point"; then
            log_message "ACTION" "Unmounting $system_mount_point before removal..."
            umount -l "$system_mount_point" >> "$LOG_FILE" 2>&1
        fi

        log_message "ACTION" "Removing physical directory: $system_mount_point"
        if rm -rf "$system_mount_point" >> "$LOG_FILE" 2>&1; then
            log_message "OK" "Physical directory $system_mount_point removed."
        else
            log_message "ERROR" "Failed to remove directory $system_mount_point"
            error_flag=1
        fi
    fi

    # Final result
    if [ "$error_flag" -eq 0 ]; then
        log_message "OK" "Snapshots and directory cleanup completed successfully."
        return 0
    else
        log_message "FAIL" "Errors occurred during snapshots cleanup. Check $LOG_FILE"
        return 1
    fi
}

#########################################
# CHECKS
#########################################

run_checks() {
    HAS_ERRORS=0
    verify_conf_vars           || HAS_ERRORS=1
    check_btrfs_root           || HAS_ERRORS=1
    check_user_context         || HAS_ERRORS=1
    check_subvol_level5        || HAS_ERRORS=1
    mount_top_level "$ROOT_DEV" || HAS_ERRORS=1
    check_list_integrity       || HAS_ERRORS=1
    verify_folder_parent       || HAS_ERRORS=1
    check_dependencies         || HAS_ERRORS=1
    check_no_snapper_configs   || HAS_ERRORS=1

    if [[ "$HAS_ERRORS" -ne 0 ]]; then
        log_message "ERROR" "One or more checks failed."
        return 1
    fi

    log_message "OK" "All checks passed successfully."
    return 0
}

run_checks_uninstall() {
    HAS_ERRORS=0
    verify_conf_vars           || HAS_ERRORS=1
    check_btrfs_root           || HAS_ERRORS=1
    check_user_context         || HAS_ERRORS=1
    check_subvol_level5        || HAS_ERRORS=1
    mount_top_level "$ROOT_DEV" || HAS_ERRORS=1
    check_list_integrity       || HAS_ERRORS=1

    if [[ "$HAS_ERRORS" -ne 0 ]]; then
        log_message "ERROR" "One or more checks failed."
        return 1
    fi

    log_message "OK" "All checks passed successfully."
    return 0
}

#########################################
# INSTALLATION
#########################################

run_install() {
    log_message "INFO" "Starting installation..."

    # Ejecuta checks primero
    if ! run_checks; then
        log_message "ERROR" "Cannot proceed with installation: pre-checks failed."
        return 1
    fi

    # Código de instalación real
    create_subvol_snapshots
    install_grub_btrfs
    create_default_grub_entry
    update_fstab
    delete_snapshots_subvolumes
#    ensure_snapper_installed
    initialize_snapper
    snapper_snapshot1
    snapper_rollback
    create_roofs_fstab
    install_new_grub
    create_subvolumes
    install_grub_ON_chroot

    log_message "OK" "Installation completed successfully."
}

#########################################
# UNINSTALLATION
#########################################

run_uninstall() {
    log_message "INFO" "Starting uninstall..."

    # Ejecuta checks primero
    if ! run_checks_uninstall; then
        log_message "ERROR" "Cannot proceed with uninstall: pre-checks failed."
        return 1
    fi

    set_default_subvolume_id5
    delete_subvolumes_from_list
    delete_snapshots_subvolumes
    create_roofs_fstab
    uninstall_snapper

    log_message "OK" "Uninstall completed successfully."
}

#########################################
# MAIN LOGIC
#########################################

# Sin argumentos → ejecuta check + install
if [[ $# -eq 0 ]]; then
    log_message "INFO" "No command passed. Running check + install..."
    run_install
    exit $?
fi

COMMAND="$1"
shift || true

case "$COMMAND" in
    check)
        run_checks
        ;;
    install)
        log_message "WARN" "Running install without pre-checks. It's the user's responsibility to ensure the system is ready."
        run_install
        ;;
    uninstall)
        run_uninstall
        ;;
    rollback)
        rollback_logic
        ;;
    *)
        echo "Usage: $0 {check|install|rollback|uninstall}"
        exit 1
        ;;
esac
