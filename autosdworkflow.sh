#!/bin/bash
set -euo pipefail

AUTOIMAGECREATE="/home/sdfactory/autoimagecreate.sh"
AUTOEJECT="/home/sdfactory/autoeject.sh"
AUTODTBREPLACE="/home/sdfactory/autodtbreplace.sh"
SETTINGS_REPLACE="/home/sdfactory/autosettingsreplace.sh"
EASYROM_REPLACE="/home/sdfactory/autoeasyromreplace.sh"
AUTOSDPREP="/home/sdfactory/autosdprep.sh"

CONTROL_MODE="gpio"   # console or gpio
START_BUTTON_PIN=17
WORKING_LED_PIN=27
COMPLETE_LED_PIN=22
READY_LED_PIN=23
BUTTON_PRESSED_VALUE="0"
REQUIRED_PARTITION_LABEL="EASYROMS"
REQUIRED_PARTITION_MIN_BYTES=8589934592
BLINK_PID=""
CURRENT_DEVICE=""

WORKFLOW_STATE_FILE="/tmp/sdworkflow_state"
WORKFLOW_PROGRESS_FILE="/tmp/sdworkflow_progress"
WORKFLOW_COLOR_FILE="/tmp/sdworkflow_status_color"
LAST_RESULT_FILE="/tmp/sd_factory_last_result"
LAST_ALERT_FILE="/tmp/sd_factory_last_alert"

set_workflow_state() {
    local state="${1:-IDLE}"
    local progress="${2:-0}"
    local color="${3:-idle}"

    echo "$state" > "$WORKFLOW_STATE_FILE"
    echo "$progress" > "$WORKFLOW_PROGRESS_FILE"
    echo "$color" > "$WORKFLOW_COLOR_FILE"
}

set_last_result() {
    echo "${1:-NONE}" > "$LAST_RESULT_FILE"
}

set_last_alert() {
    echo "${1:-NONE}" > "$LAST_ALERT_FILE"
}

clear_last_alert() {
    echo "NONE" > "$LAST_ALERT_FILE"
}

log() {
    echo "[WORKFLOW] $*"
}

device_path() {
    [ -n "$CURRENT_DEVICE" ] && echo "$CURRENT_DEVICE"
}

device_exists() {
    local devnode
    devnode="$(device_path)"
    [ -n "$devnode" ] && [ -b "$devnode" ]
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

device_ready() {
    local devnode
    devnode="$(device_path)"
    [ -n "$devnode" ] && [ -b "$devnode" ] && is_whole_disk "$devnode" && is_removable "$devnode"
}

required_partition_label_exists() {
    local devnode
    devnode="$(device_path)"
    [ -n "$devnode" ] || return 1
    lsblk -ln -o NAME,TYPE,LABEL "$devnode" 2>/dev/null | awk -v label="$REQUIRED_PARTITION_LABEL" '$2=="part" && $3==label {found=1} END {exit !found}'
}

required_partition_label_size_ok() {
    local devnode
    devnode="$(device_path)"
    [ -n "$devnode" ] || return 1
    lsblk -bn -o NAME,TYPE,LABEL,SIZE "$devnode" 2>/dev/null | awk -v label="$REQUIRED_PARTITION_LABEL" -v min="$REQUIRED_PARTITION_MIN_BYTES" '$2=="part" && $3==label && $4>min {found=1} END {exit !found}'
}

wait_for_sd_card() {
    local found
    log "Waiting for removable SD card..."
    while true; do
        found="$(find_removable_sd_device || true)"
        if [ -n "$found" ]; then
            CURRENT_DEVICE="$found"
            log "Detected SD card: $CURRENT_DEVICE"
            sleep 1
            return 0
        fi
        sleep 0.5
    done
}

wait_for_easyroms_partition() {
    while true; do
        if ! device_ready; then
            log "SD card not ready. Insert SD card first..."
            sleep 0.5
            wait_for_sd_card
            continue
        fi
        if ! required_partition_label_exists; then
            log "Partition label '$REQUIRED_PARTITION_LABEL' not found yet on $(device_path)..."
            sleep 1.5
            continue
        fi
        if ! required_partition_label_size_ok; then
            log "Partition '$REQUIRED_PARTITION_LABEL' found, but size is not greater than 8 GiB yet..."
            sleep 1.5
            continue
        fi
        log "Detected partition '$REQUIRED_PARTITION_LABEL' larger than 8 GiB"
        return 0
    done
}

wait_for_sd_removal() {
    while true; do
        if [ -z "$CURRENT_DEVICE" ]; then
            return 0
        fi
        if ! device_ready; then
            CURRENT_DEVICE=""
            return 0
        fi
        sleep 0.5
    done
}

gpio_init() {
    pinctrl set "$WORKING_LED_PIN" op dl
    pinctrl set "$COMPLETE_LED_PIN" op dl
    pinctrl set "$READY_LED_PIN" op dl
    pinctrl set "$START_BUTTON_PIN" ip pu
}

set_working()  { [ "${1:-0}" = "1" ] && pinctrl set "$WORKING_LED_PIN" op dh || pinctrl set "$WORKING_LED_PIN" op dl; }
set_complete() { [ "${1:-0}" = "1" ] && pinctrl set "$COMPLETE_LED_PIN" op dh || pinctrl set "$COMPLETE_LED_PIN" op dl; }
set_ready()    { [ "${1:-0}" = "1" ] && pinctrl set "$READY_LED_PIN" op dh || pinctrl set "$READY_LED_PIN" op dl; }

all_off() {
    set_working 0
    set_complete 0
}

stop_all_blinking() {
    if [ -n "${BLINK_PID:-}" ]; then
        kill "$BLINK_PID" >/dev/null 2>&1 || true
        wait "$BLINK_PID" 2>/dev/null || true
        BLINK_PID=""
    fi
}

blink_working() {
    stop_all_blinking
    all_off
    (
        while true; do
            set_working 1
            set_complete 0
            set_ready 1
            sleep 0.4
            set_working 0
            set_complete 0
            set_ready 1
            sleep 0.4
        done
    ) &
    BLINK_PID=$!
}

blink_ready() {
    stop_all_blinking
    all_off
    (
        while true; do
            set_working 0
            set_complete 0
            set_ready 1
            sleep 0.4
            set_working 0
            set_complete 0
            set_ready 0
            sleep 0.4
        done
    ) &
    BLINK_PID=$!
}

blink_leds() {
    stop_all_blinking
    all_off
    (
        while true; do
            set_working 1
            set_complete 1
            set_ready 1
            sleep 0.4
            set_working 0
            set_complete 0
            set_ready 1
            sleep 0.4
        done
    ) &
    BLINK_PID=$!
}

alternate_leds() {
    stop_all_blinking
    all_off
    (
        while true; do
            set_working 1
            set_complete 0
            set_ready 1
            sleep 0.4
            set_working 0
            set_complete 1
            set_ready 1
            sleep 0.4
        done
    ) &
    BLINK_PID=$!
}

stop_blinking() {
    stop_all_blinking
    all_off
    set_ready 1
}

stop_blinking_working() {
    stop_all_blinking
    all_off
    set_ready 1
}

cleanup() {
    stop_all_blinking
    set_working 0
    set_complete 0
    set_ready 1
    pinctrl set "$WORKING_LED_PIN" ip >/dev/null 2>&1 || true
    pinctrl set "$COMPLETE_LED_PIN" ip >/dev/null 2>&1 || true
    pinctrl set "$START_BUTTON_PIN" ip >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

error_state() {
    local msg="$1"
    set_workflow_state "FAILED" "100" "error"
    set_last_result "FAILED"
    set_last_alert "$msg"

    echo
    echo "ERROR: $msg"
    echo
    echo "Press ENTER to exit to terminal"

    blink_ready

    if [ "$CONTROL_MODE" = "console" ]; then
        read -r
        exit 1
    else
        while true; do
            if read -t 0.2 -r; then
                exit 1
            fi
        done
    fi
}

wait_for_start() {
    local value
    if [ "$CONTROL_MODE" = "console" ]; then
        read -p "Press ENTER to continue..."
        return
    fi
    log "Waiting for START button..."
    while true; do
        value="$(pinctrl get "$START_BUTTON_PIN" | grep -o 'lo\|hi' | head -n1)"
        if [ "$BUTTON_PRESSED_VALUE" = "0" ] && [ "$value" = "lo" ]; then
            sleep 0.25
            break
        fi
        if [ "$BUTTON_PRESSED_VALUE" = "1" ] && [ "$value" = "hi" ]; then
            sleep 0.25
            break
        fi
        sleep 0.1
    done
}

wait_for_start_with_sd() {
    while true; do
        if ! device_ready; then
            log "SD card not ready. Insert card first..."
            sleep 0.5
            continue
        fi
        log "Required SD device: $(device_path)"
        wait_for_start
        if device_ready; then
            log "Confirmed SD card present: $(device_path)"
            return 0
        fi
        log "Start ignored. Device is no longer present."
        sleep 0.5
    done
}

wait_for_start_with_sd_and_easyroms() {
    while true; do
        if ! device_ready; then
            log "SD card not ready. Insert card first..."
            sleep 0.5
            continue
        fi
        if ! required_partition_label_exists; then
            log "Partition '$REQUIRED_PARTITION_LABEL' not found yet on $(device_path)..."
            sleep 0.5
            continue
        fi
        if ! required_partition_label_size_ok; then
            log "Partition '$REQUIRED_PARTITION_LABEL' exists but is not larger than 8 GiB yet..."
            sleep 0.5
            continue
        fi
        wait_for_start
        if device_ready && required_partition_label_exists && required_partition_label_size_ok; then
            log "Confirmed SD card present with '$REQUIRED_PARTITION_LABEL' larger than 8 GiB"
            return 0
        fi
        log "Start ignored. Device or required partition is no longer valid."
        sleep 0.5
    done
}

run_script() {
    local script="$1"
    local step_name="${2:-RUNNING}"

    [ -x "$script" ] || error_state "Script missing or not executable: $script"

    export TARGET_SD_DEVICE
    TARGET_SD_DEVICE="$(device_path)"

    log "Running $step_name using $script"
    "$script" || error_state "Script failed: $script"
}

clear
gpio_init
all_off
set_ready 1

set_workflow_state "IDLE" "0" "idle"
set_last_result "IDLE"
clear_last_alert

while true; do
    clear

    set_ready 1

    set_workflow_state "WAITING_FOR_SD" "0" "idle"
    set_last_result "WAITING"
    clear_last_alert

    echo
    echo "Insert SD card then push START"

    wait_for_sd_card

    set_workflow_state "WAITING_FOR_START_STAGE_1" "5" "running"
    blink_leds
    wait_for_start_with_sd
    stop_blinking

    echo
    echo "Starting process on $(device_path)..."
    set_workflow_state "SD_PREP" "15" "running"
    blink_working

    run_script "$AUTOSDPREP" "SD_PREP"

    set_workflow_state "IMAGE_CREATE" "35" "running"
    run_script "$AUTOIMAGECREATE" "IMAGE_CREATE"

    set_workflow_state "DTB_REPLACE" "55" "running"
    run_script "$AUTODTBREPLACE" "DTB_REPLACE"

    set_workflow_state "EJECT_STAGE_1" "70" "running"
    run_script "$AUTOEJECT" "EJECT_STAGE_1"

    stop_blinking_working

    echo
    echo "Remove SD card and boot R36S"
    echo "Then insert SD card and push START"

    set_workflow_state "WAITING_FOR_BOOT_AND_REINSERT" "75" "running"
    alternate_leds
    wait_for_sd_removal

    set_workflow_state "WAITING_FOR_RETURN_SD" "78" "running"
    wait_for_sd_card

    set_workflow_state "WAITING_FOR_EASYROMS" "82" "running"
    wait_for_easyroms_partition
    stop_all_blinking
    all_off
    set_ready 1

    set_workflow_state "WAITING_FOR_START_STAGE_2" "85" "running"
    blink_leds
    wait_for_start_with_sd_and_easyroms
    stop_blinking

    set_workflow_state "SETTINGS_REPLACE" "90" "running"
    blink_working
    run_script "$SETTINGS_REPLACE" "SETTINGS_REPLACE"

    set_workflow_state "EASYROM_REPLACE" "96" "running"
    run_script "$EASYROM_REPLACE" "EASYROM_REPLACE"
    stop_blinking_working

    echo
    echo "Process complete"
    echo "Remove SD card to restart"

    set_workflow_state "COMPLETE" "100" "complete"
    set_last_result "COMPLETE"
    set_complete 1
    clear_last_alert

    
    set_ready 1
    wait_for_sd_removal
    all_off
    set_ready 0

    set_workflow_state "IDLE" "0" "idle"
done