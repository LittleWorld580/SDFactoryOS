#!/bin/bash
set -euo pipefail

log() {
    echo "[AUTOEJECT] $*"
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
    local device

    device="$(resolve_base_device || true)"
    [ -n "$device" ] || { log "ERROR: Could not determine SD device"; exit 1; }
    [ -b "$device" ] || { log "ERROR: Device not found: $device"; exit 1; }

    log "Unmounting partitions on $device..."
    lsblk -ln -o NAME "$device" | tail -n +2 | while read -r part; do
        [ -n "$part" ] || continue
        if mount | grep -q "^/dev/$part "; then
            log "Unmounting /dev/$part"
            umount "/dev/$part" || true
        fi
    done

    sync
    udevadm settle 2>/dev/null || true

    log "Requesting device eject..."
    if command -v udisksctl >/dev/null 2>&1; then
        udisksctl power-off -b "$device" >/dev/null 2>&1 || true
    elif command -v eject >/dev/null 2>&1; then
        eject "$device" >/dev/null 2>&1 || true
    fi

    log "Device unmounted and ejected."
}

main
