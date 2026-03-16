#!/bin/bash
set -euo pipefail

PARTITION_NUMBER="1"
MOUNTPOINT="/mnt/sdboot"
WAIT_SECONDS=2
SOURCE_DTB="/home/sdfactory/rk3326-rg351mp-linux.dtb"
TARGET_DTB="/rk3326-rg351mp-linux.dtb"

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
    local base_device device current_mount dtb_target

    [ -f "$SOURCE_DTB" ] || { log "ERROR: DTB file not found: $SOURCE_DTB"; exit 1; }

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

    dtb_target="$MOUNTPOINT$TARGET_DTB"
    log "Copying DTB to $dtb_target"
    cp -f "$SOURCE_DTB" "$dtb_target"
    sync
    log "DTB replacement complete"
}

main
