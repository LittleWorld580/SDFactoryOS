#!/bin/bash
set -euo pipefail

PARTITION_LABEL="sd"
PARTITION_NUMBER="1"
RESCAN_WAIT_SECONDS=2

log() {
    echo "[SDPREP] $*"
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

is_whole_disk() {
    local devnode="$1"
    [[ "$(basename "$devnode")" =~ ^sd[a-z]+$ ]]
}

is_removable() {
    local devnode="$1"
    local name path
    name="$(basename "$devnode")"
    path="/sys/block/$name/removable"
    [ -f "$path" ] || return 1
    [ "$(cat "$path")" = "1" ]
}

partition_path() {
    local devnode="$1"
    echo "${devnode}${PARTITION_NUMBER}"
}

wait_for_partition() {
    local partition="$1"
    local timeout="${2:-15}"
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        [ -b "$partition" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

unmount_partitions() {
    local devnode="$1"
    log "Unmounting partitions on $devnode..."
    lsblk -ln -o NAME "$devnode" | tail -n +2 | while read -r part; do
        [ -n "$part" ] || continue
        umount "/dev/$part" 2>/dev/null || true
    done
}

wipe_device() {
    local devnode="$1"
    log "Wiping partition table and signatures..."
    dd if=/dev/zero of="$devnode" bs=4M count=32 conv=fsync status=none
    wipefs -a "$devnode" >/dev/null 2>&1 || true
    sync
}

create_partition_table() {
    local devnode="$1"
    log "Creating GPT partition table..."
    parted -s "$devnode" mklabel gpt
}

create_full_partition() {
    local devnode="$1"
    log "Creating single full-size partition..."
    parted -s -a optimal "$devnode" mkpart primary 1MiB 100%
    sync
}

rescan_device() {
    local devnode="$1"
    log "Rescanning partition table..."
    partprobe "$devnode" 2>/dev/null || true
    blockdev --rereadpt "$devnode" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sync
    sleep "$RESCAN_WAIT_SECONDS"
}

format_partition() {
    local devnode="$1"
    local part
    part="$(partition_path "$devnode")"
    wait_for_partition "$part" 20 || {
        log "ERROR: Partition not found: $part"
        exit 1
    }
    log "Formatting $part as exFAT with label '$PARTITION_LABEL'..."
    mkfs.exfat -n "$PARTITION_LABEL" "$part"
    sync
}

show_result() {
    local devnode="$1"
    log "Final device layout:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$devnode"
}

main() {
    local devnode

    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root: sudo bash $0"
        exit 1
    fi

    devnode="$(resolve_base_device || true)"
    [ -n "$devnode" ] || { log "ERROR: Could not determine SD device"; exit 1; }
    [ -b "$devnode" ] || { log "ERROR: Device not found: $devnode"; exit 1; }
    is_whole_disk "$devnode" || { log "ERROR: Not a whole disk: $devnode"; exit 1; }
    is_removable "$devnode" || { log "ERROR: Device is not removable: $devnode"; exit 1; }

    log "Target device: $devnode"

    unmount_partitions "$devnode"
    wipe_device "$devnode"
    create_partition_table "$devnode"
    create_full_partition "$devnode"
    rescan_device "$devnode"
    format_partition "$devnode"
    rescan_device "$devnode"
    show_result "$devnode"

    log "SD prep complete"
}

main
