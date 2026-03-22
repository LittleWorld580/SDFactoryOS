#!/bin/bash
set -euo pipefail

IMAGE_FILE="/home/sdfactory/dArkOSRE_R36_trixie_03082026.img"
INPUT_FILESYSTEM="exfat"
PARTITION_TIMEOUT=20
POST_WRITE_SETTLE_SECONDS=3
BOOT_MOUNTPOINT="/mnt/sdboot"
ROOT_MOUNTPOINT="/mnt/sdroot"
EASYROMS_MOUNTPOINT="/mnt/easyroms"

log() {
    echo "[AUTOIMAGECREATE] $*"
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
    local devnode="$1" partnum="$2"
    echo "${devnode}${partnum}"
}

get_root_parent_disk() {
    local root_src base
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null)" || return 1
    base="$(basename "$root_src")"
    if [[ "$base" =~ ^mmcblk[0-9]+p[0-9]+$ ]]; then
        echo "/dev/${base%%p*}"
    elif [[ "$base" =~ ^sd[a-z]+[0-9]+$ ]]; then
        echo "/dev/${base%%[0-9]*}"
    else
        echo "/dev/$base"
    fi
}

get_partition_fstype() {
    local partition="$1"
    lsblk -no FSTYPE "$partition" 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]'
}

wait_for_clean_input_partition() {
    local devnode="$1"
    local input_partition
    local fstype
    input_partition="$(partition_path "$devnode" 1)"

    log "Waiting for clean input partition: $input_partition ($INPUT_FILESYSTEM)"
    while true; do
        [ -b "$devnode" ] || { log "Device disappeared: $devnode"; sleep 1; continue; }
        [ -b "$input_partition" ] || { log "Partition not present yet: $input_partition"; sleep 1; continue; }
        fstype="$(get_partition_fstype "$input_partition")"
        if [ "$fstype" = "$INPUT_FILESYSTEM" ]; then
            log "Detected input partition $input_partition with filesystem $fstype"
            return 0
        fi
        log "Found $input_partition but filesystem is '$fstype', expected '$INPUT_FILESYSTEM'"
        sleep 1
    done
}

unmount_partitions() {
    local devnode="$1"
    log "Unmounting partitions on $devnode..."
    lsblk -ln -o NAME "$devnode" | tail -n +2 | while read -r part; do
        [ -n "$part" ] || continue
        umount "/dev/$part" 2>/dev/null || true
    done
}

wait_for_partition() {
    local partition="$1"
    local timeout="${2:-20}"
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        [ -b "$partition" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

mount_partition_rw() {
    local partition="$1" mountpoint="$2" current_mount
    [ -b "$partition" ] || return 1
    current_mount="$(lsblk -no MOUNTPOINT "$partition" | head -n1)"
    if [ -n "$current_mount" ]; then
        log "$partition already mounted at $current_mount"
        return 0
    fi
    mkdir -p "$mountpoint"
    log "Mounting $partition to $mountpoint as read-write"
    mount -o rw "$partition" "$mountpoint"
}

mount_created_partitions() {
    local devnode="$1"
    local boot_part root_part easy_part
    boot_part="$(partition_path "$devnode" 1)"
    root_part="$(partition_path "$devnode" 2)"
    easy_part="$(partition_path "$devnode" 3)"

    log "Re-reading partition table..."
    blockdev --rereadpt "$devnode" 2>/dev/null || true
    partprobe "$devnode" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep "$POST_WRITE_SETTLE_SECONDS"

    wait_for_partition "$boot_part" "$PARTITION_TIMEOUT" || true
    wait_for_partition "$root_part" "$PARTITION_TIMEOUT" || true
    wait_for_partition "$easy_part" "$PARTITION_TIMEOUT" || true

    log "Attempting to mount created partitions..."
    mount_partition_rw "$boot_part" "$BOOT_MOUNTPOINT" || true
    mount_partition_rw "$root_part" "$ROOT_MOUNTPOINT" || true
    mount_partition_rw "$easy_part" "$EASYROMS_MOUNTPOINT" || true

    log "Current device layout:"
    lsblk "$devnode"
}

main() {
    local devnode root_disk

    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root: sudo bash $0"
        exit 1
    fi

    [ -f "$IMAGE_FILE" ] || { log "ERROR: Image file not found: $IMAGE_FILE"; exit 1; }

    devnode="$(resolve_base_device || true)"
    [ -n "$devnode" ] || { log "ERROR: Could not determine SD device"; exit 1; }
    [ -b "$devnode" ] || { log "ERROR: Device not found: $devnode"; exit 1; }
    is_whole_disk "$devnode" || { log "ERROR: Not a whole disk: $devnode"; exit 1; }
    is_removable "$devnode" || { log "ERROR: Device is not removable: $devnode"; exit 1; }

    root_disk="$(get_root_parent_disk || true)"
    if [ -n "$root_disk" ] && [ "$devnode" = "$root_disk" ]; then
        log "ERROR: Refusing to write to system disk $devnode"
        exit 1
    fi

    wait_for_clean_input_partition "$devnode"

    log "Target device confirmed: $devnode"
    unmount_partitions "$devnode"

    log "Wiping beginning of card..."
    dd if=/dev/zero of="$devnode" bs=1M count=16 conv=fsync status=progress
    sync

    log "Writing bootable image..."
    dd if="$IMAGE_FILE" of="$devnode" bs=4M conv=fsync status=progress
    sync

    log "Image write complete"
    mount_created_partitions "$devnode"
    log "Done. $devnode should now be bootable."
}

main
