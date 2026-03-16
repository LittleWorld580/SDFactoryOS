#!/bin/bash
set -euo pipefail

PARTITION_NUMBER="3"
MOUNTPOINT="/mnt/easyroms"
WAIT_SECONDS=2
DETECT_TIMEOUT=60
SOURCE_FOLDER="/home/sdfactory/EASYROMsource/EASYROMS"

log() {
    echo "[EASYROM_REPLACE] $*" >&2
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

wait_for_partition() {
    local i=0
    local base_device=""
    local partition=""

    log "Waiting for SD card partition ${PARTITION_NUMBER}..."

    while [ "$i" -lt "$DETECT_TIMEOUT" ]; do
        udevadm settle 2>/dev/null || true

        base_device="$(resolve_base_device || true)"
        if [ -n "$base_device" ]; then
            partition="${base_device}${PARTITION_NUMBER}"
            if [ -b "$partition" ]; then
                echo "$partition"
                return 0
            fi
        fi

        sleep 1
        i=$((i + 1))
    done

    return 1
}

main() {
    local device current_mount

    [ -d "$SOURCE_FOLDER" ] || {
        log "ERROR: Source folder not found: $SOURCE_FOLDER"
        exit 1
    }

    device="$(wait_for_partition || true)"
    [ -n "$device" ] || {
        log "ERROR: Could not detect SD card partition ${PARTITION_NUMBER}"
        exit 1
    }

    [ -b "$device" ] || {
        log "ERROR: Device not found: $device"
        exit 1
    }

    log "Starting EasyROM folder replacement on $device"
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
    [ -n "$MOUNTPOINT" ] || {
        log "ERROR: Failed to mount $device"
        exit 1
    }

    [ -d "$MOUNTPOINT" ] || {
        log "ERROR: Mount point missing: $MOUNTPOINT"
        exit 1
    }

    log "Removing existing contents from target..."
    find "$MOUNTPOINT" -mindepth 1 -maxdepth 1 ! -name "lost+found" -exec rm -rf {} +

    log "Copying new contents..."
    rsync -rltv --no-o --no-g --no-p --info=progress2 --modify-window=1 \
        "$SOURCE_FOLDER"/ "$MOUNTPOINT"/

    sync
    log "EasyROM replacement complete"
}

main