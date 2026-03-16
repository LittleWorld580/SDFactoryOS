#!/bin/bash
set -euo pipefail

#######################################
# EMULATIONSTATION UPDATE SCRIPT
# Pull .emulationstation files from GitHub repo and replace matching local files
# Does NOT delete extra local files
#######################################

# ===== CONFIG =====
REPO_URL="https://github.com/LittleWorld580/EmulationStationSettings.git"
BRANCH="main"

# Where the .emulationstation files should be copied to
TARGET_DIR="/home/sdfactory/emulationstationhiddenfolder/.emulationstation"

# Optional: only copy contents of a subfolder inside the repo
# Leave blank "" to copy the whole repo contents
REPO_SUBFOLDER=""

# Temp working folder
TMP_DIR="/tmp/emulationstationupdate_repo"

# Files/folders to exclude from replacement
EXCLUDES=(
  ".git"
  ".github"
  "README.md"
)

log() {
    echo "[EMULATIONSTATIONUPDATE] $*"
}

fail() {
    echo "[EMULATIONSTATIONUPDATE] ERROR: $*" >&2
    exit 1
}

require_root() {
    if [ "${EUID:-0}" -ne 0 ]; then
        fail "Run with sudo: sudo bash emulationstationupdate.sh"
    fi
}

check_requirements() {
    command -v git >/dev/null 2>&1 || fail "git is not installed"
    command -v rsync >/dev/null 2>&1 || fail "rsync is not installed"
}

cleanup() {
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

prepare_target() {
    log "Ensuring target directory exists..."
    mkdir -p "$TARGET_DIR"
}

clone_repo() {
    log "Removing old temp folder..."
    rm -rf "$TMP_DIR"

    log "Cloning repo..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR"
}

resolve_source_dir() {
    if [ -n "$REPO_SUBFOLDER" ]; then
        SOURCE_DIR="$TMP_DIR/$REPO_SUBFOLDER"
    else
        SOURCE_DIR="$TMP_DIR"
    fi

    [ -d "$SOURCE_DIR" ] || fail "Source directory not found: $SOURCE_DIR"
}

build_rsync_excludes() {
    RSYNC_EXCLUDES=()
    local item
    for item in "${EXCLUDES[@]}"; do
        RSYNC_EXCLUDES+=(--exclude="$item")
    done
}

copy_files() {
    log "Copying .emulationstation files into $TARGET_DIR ..."
    rsync -av \
        "${RSYNC_EXCLUDES[@]}" \
        "$SOURCE_DIR"/ "$TARGET_DIR"/
}

fix_permissions() {
    log "Fixing ownership..."
    if id "sdfactory" >/dev/null 2>&1; then
        chown -R sdfactory:sdfactory "$TARGET_DIR" 2>/dev/null || true
    fi
}

summary() {
    echo
    log ".emulationstation update complete"
    echo "Repo:    $REPO_URL"
    echo "Branch:  $BRANCH"
    echo "Target:  $TARGET_DIR"
    echo "Mode:    Overwrite matching files, keep extra local files"
    echo
}

main() {
    trap cleanup EXIT

    require_root
    check_requirements
    prepare_target
    clone_repo
    resolve_source_dir
    build_rsync_excludes
    copy_files
    fix_permissions
    summary
}

main "$@"