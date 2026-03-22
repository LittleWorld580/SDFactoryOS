#!/bin/bash
set -euo pipefail

PARTITION_NUMBER="1"
MOUNTPOINT="/mnt/sdboot"
WAIT_SECONDS=2

# Source files
SOURCE_DTB="/home/sdfactory/rk3326-r36s-linux.dtb"
SOURCE_UBOOT_DTB="/home/sdfactory/rg351mp-uboot.dtb"
SOURCE_LOGO="/home/sdfactory/logo.bmp"

# Target paths (on SD)
TARGET_DTB="/rk3326-r36s-linux.dtb"
TARGET_UBOOT_DTB="/rg351MP-uboot.dtb"
TARGET_LOGO="/logo.bmp"

log() {
    echo "[DTB_REPLACE] $*"
}

find_removable_sd_device() {
    local dev name
    for dev in /sys/block/sd*; do
        [ -e "$dev" ] || continue
        name="$(basename "$dev")"
        if [ -f "$dev/removable" ] && [ "$(cat "$dev/removable")" = "1" ]; then
            echo "/dev/$name"
            return 0
        fi
    done
    return 1
}

resolve_base_device() {
    if [ -n "${TARGET_SD_DEVICE:-}" ] && [ -b "${TARGET_SD_DEVICE}" ]; then
        echo "${TARGET_SD_DEVICE}"
        return 0
    fi
    find_removable_sd_device
}

main() {
    local base_device device current_mount dtb_target uboot_target logo_target

    # Main DTB must exist
    [ -f "$SOURCE_DTB" ] || { log "ERROR: Missing $SOURCE_DTB"; exit 1; }

    base_device="$(resolve_base_device || true)"
    [ -n "$base_device" ] || { log "ERROR: Could not determine SD device"; exit 1; }

    device="${base_device}${PARTITION_NUMBER}"
    [ -b "$device" ] || { log "ERROR: Device not found: $device"; exit 1; }

    log "Starting DTB replacement on $device"
    sync
    sleep "$WAIT_SECONDS"

    current_mount="$(lsblk -no MOUNTPOINT "$device" | head -n1)"
    if [ -n "$current_mount" ]; then
        MOUNTPOINT="$current_mount"
        log "Device already mounted at $MOUNTPOINT"
    else
        mkdir -p "$MOUNTPOINT"
        log "Mounting $device to $MOUNTPOINT as read-write"
        mount -o rw "$device" "$MOUNTPOINT"
    fi

    MOUNTPOINT="$(lsblk -no MOUNTPOINT "$device" | head -n1)"
    [ -n "$MOUNTPOINT" ] || { log "ERROR: Failed to mount $device"; exit 1; }

    # Copy main DTB (required)
    dtb_target="$MOUNTPOINT$TARGET_DTB"
    log "Copying rk3326 DTB -> $dtb_target"
    cp -f "$SOURCE_DTB" "$dtb_target"

    # Copy u-boot DTB (optional)
    uboot_target="$MOUNTPOINT$TARGET_UBOOT_DTB"
    if [ -f "$SOURCE_UBOOT_DTB" ]; then
        log "Copying u-boot DTB -> $uboot_target"
        cp -f "$SOURCE_UBOOT_DTB" "$uboot_target"
    else
        log "WARNING: rg351mp-uboot.dtb not found, skipping"
    fi

    # Copy logo.bmp (optional)
    logo_target="$MOUNTPOINT$TARGET_LOGO"
    if [ -f "$SOURCE_LOGO" ]; then
        log "Copying logo.bmp -> $logo_target"
        cp -f "$SOURCE_LOGO" "$logo_target"
    else
        log "WARNING: logo.bmp not found, skipping"
    fi

    sync
    log "DTB + UBOOT + LOGO replacement complete"
}

main