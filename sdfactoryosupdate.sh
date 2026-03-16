#!/bin/bash
set -euo pipefail

#######################################
# OS UPDATE SCRIPT
# Pull files from GitHub repo and replace local files
# Does NOT delete extra local files
#######################################

# ===== CONFIG =====
REPO_URL="https://github.com/LittleWorld580/SDFactoryOS.git"
BRANCH="main"

# Where the repo files should be copied to
TARGET_DIR="/home/sdfactory"

# Optional: only copy contents of a subfolder inside the repo
# Leave blank "" to copy the whole repo contents
REPO_SUBFOLDER=""

# Temp working folder
TMP_DIR="/tmp/osupdate_repo"

# Optional systemd service to restart after update
RESTART_SERVICE=""

# Files/folders to exclude from replacement
EXCLUDES=(
  ".git"
  ".github"
  "README.md"
)

log() {
    echo "[OSUPDATE] $*"
}

fail() {
    echo "[OSUPDATE] ERROR: $*" >&2
    exit 1
}

require_root() {
    if [ "${EUID:-0}" -ne 0 ]; then
        fail "Run with sudo: sudo bash osupdate.sh"
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
    log "Copying files from repo into $TARGET_DIR ..."
    rsync -av \
        "${RSYNC_EXCLUDES[@]}" \
        "$SOURCE_DIR"/ "$TARGET_DIR"/
}

fix_permissions() {
    log "Fixing script permissions..."
    find "$TARGET_DIR" -maxdepth 1 -type f -name "*.sh" -exec chmod 755 {} \;
    find "$TARGET_DIR" -maxdepth 1 -type f -name "*.py" -exec chmod 755 {} \;

    if id "sdfactory" >/dev/null 2>&1; then
        chown sdfactory:sdfactory "$TARGET_DIR"/*.sh 2>/dev/null || true
        chown sdfactory:sdfactory "$TARGET_DIR"/*.py 2>/dev/null || true
    fi
}

restart_service() {
    if [ -z "$RESTART_SERVICE" ]; then
        log "No service configured, skipping restart"
        return
    fi

    if systemctl list-unit-files | grep -q "^${RESTART_SERVICE}"; then
        log "Restarting $RESTART_SERVICE ..."
        systemctl restart "$RESTART_SERVICE"
    else
        log "Service $RESTART_SERVICE not found, skipping restart"
    fi
}

summary() {
    echo
    log "Update complete"
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
    clone_repo
    resolve_source_dir
    build_rsync_excludes
    copy_files
    fix_permissions
    restart_service
    summary
}

main "$@"