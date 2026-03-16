#!/bin/bash
set -euo pipefail

PARTITION_NUMBER="2"
MOUNTPOINT="/mnt/settingsroot"
WAIT_SECONDS=2
SOURCE_SETTINGS="/home/sdfactory/emulationstationhiddenfolder/.emulationstation"
TARGET_SETTINGS="/home/ark/.emulationstation"

log() {
    echo "[SETTINGS_REPLACE] $*"
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
    local base_device device current_mount target_folder target_parent

    [ -d "$SOURCE_SETTINGS" ] || { log "ERROR: Source settings folder not found: $SOURCE_SETTINGS"; exit 1; }

    base_device="$(resolve_base_device || true)"
    [ -n "$base_device" ] || { log "ERROR: Could not determine SD device"; exit 1; }
    device="${base_device}${PARTITION_NUMBER}"
    [ -b "$device" ] || { log "ERROR: Device not found: $device"; exit 1; }

    log "Starting EmulationStation settings replacement on $device"
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

    target_folder="$MOUNTPOINT$TARGET_SETTINGS"
    target_parent="$(dirname "$target_folder")"

    [ -d "$MOUNTPOINT" ] || { log "ERROR: Mount point missing: $MOUNTPOINT"; exit 1; }
    [ -d "$target_parent" ] || { log "ERROR: Target parent folder missing: $target_parent"; exit 1; }

    log "Removing existing target folder..."
    rm -rf "$target_folder"

    log "Copying new settings folder..."
    cp -a "$SOURCE_SETTINGS" "$target_folder"
    sync

    log "Settings replacement complete"
}

main
