#!/bin/bash
set -euo pipefail

#######################################
# SD FACTORY SETUP
#######################################

FACTORY_USER="sdfactory"
FACTORY_HOME="/home/$FACTORY_USER"
SERVICE_NAME="wio-serial-panel.service"
SUDOERS_FILE="/etc/sudoers.d/sdfactory"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REQUIRED_FILES=(
  "autoimagecreate.sh"
  "autosdprep.sh"
  "autosdworkflow.sh"
  "autosettingsreplace.sh"
  "enableterminal.sh"
  "wio_serial_panel.py"
  "autodtbreplace.sh"
  "autoeasyromreplace.sh"
  "autoeject.sh"
)

log() {
    echo "[SETUP] $*"
}

fail() {
    echo "[SETUP] ERROR: $*" >&2
    exit 1
}

require_root() {
    [ "${EUID:-0}" -eq 0 ] || fail "Run with sudo: sudo bash setup.sh"
}

check_user() {
    id "$FACTORY_USER" >/dev/null 2>&1 || fail "User '$FACTORY_USER' does not exist"
}

check_required_files() {
    log "Checking required files..."
    for file in "${REQUIRED_FILES[@]}"; do
        [ -f "$SCRIPT_DIR/$file" ] || fail "Missing required file: $file"
    done
}

install_packages() {

    log "Installing required packages..."

    apt-get update

    apt-get install -y \
        python3 \
        python3-pip \
        python3-serial \
        python3-rpi.gpio \
        rsync \
        parted \
        exfatprogs \
        util-linux \
        udisks2 \
        eject \
        dosfstools
}

create_directories() {

    log "Creating directories..."

    mkdir -p "$FACTORY_HOME"
    mkdir -p "$FACTORY_HOME/logs"

    mkdir -p /mnt/sdboot
    mkdir -p /mnt/sdroot
    mkdir -p /mnt/easyroms
    mkdir -p /mnt/settingsroot

    chown -R "$FACTORY_USER:$FACTORY_USER" "$FACTORY_HOME/logs"
}

install_scripts() {

    log "Installing scripts..."

    for file in "${REQUIRED_FILES[@]}"; do
        install -m 755 "$SCRIPT_DIR/$file" "$FACTORY_HOME/$file"
        chown "$FACTORY_USER:$FACTORY_USER" "$FACTORY_HOME/$file"
        log "Installed $file"
    done
}

write_sudoers() {

    log "Creating sudoers rules..."

cat > "$SUDOERS_FILE" <<EOF
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autosdworkflow.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autosdprep.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autoimagecreate.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autodtbreplace.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autosettingsreplace.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autoeasyromreplace.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autoeject.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/enableterminal.sh
sdfactory ALL=(ALL) NOPASSWD: /usr/sbin/shutdown
sdfactory ALL=(ALL) NOPASSWD: /usr/bin/systemctl
EOF

    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE"
}

configure_bash_profile() {

    BASH_PROFILE="$FACTORY_HOME/.bash_profile"

    log "Configuring bash_profile..."

    touch "$BASH_PROFILE"
    chown "$FACTORY_USER:$FACTORY_USER" "$BASH_PROFILE"

sed -i '/# >>> SD FACTORY AUTOSTART >>>/,/# <<< SD FACTORY AUTOSTART <<</d' "$BASH_PROFILE"

cat >> "$BASH_PROFILE" <<EOF

# >>> SD FACTORY AUTOSTART >>>

if [[ "\$USER" == "sdfactory" ]] && [[ -t 1 ]]; then
    if [[ -z "\${SSH_CONNECTION:-}" ]] && [[ -z "\${SSH_TTY:-}" ]]; then
        if ! pgrep -f autosdworkflow.sh > /dev/null; then
            clear
            echo "Starting SD Factory Workflow..."
            sudo /home/sdfactory/autosdworkflow.sh
        fi
    fi
fi

# <<< SD FACTORY AUTOSTART <<<
EOF

    chown "$FACTORY_USER:$FACTORY_USER" "$BASH_PROFILE"
}

write_systemd_service() {

    log "Creating systemd service..."

cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=SD Factory Wio Serial Panel
After=multi-user.target

[Service]
Type=simple
User=sdfactory
WorkingDirectory=/home/sdfactory
ExecStart=/usr/bin/python3 /home/sdfactory/wio_serial_panel.py
Restart=always
RestartSec=2

StandardOutput=append:/home/sdfactory/logs/wio_serial_panel.log
StandardError=append:/home/sdfactory/logs/wio_serial_panel.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
}

summary() {

echo
echo "=============================="
echo " SD FACTORY SETUP COMPLETE"
echo "=============================="
echo
echo "Wio panel service:"
echo "  systemctl status $SERVICE_NAME"
echo
echo "View Wio logs:"
echo "  tail -f /home/sdfactory/logs/wio_serial_panel.log"
echo
echo "Workflow autostarts on console login"
echo
}

main() {

require_root
check_user
check_required_files

install_packages
create_directories
install_scripts
write_sudoers
configure_bash_profile
write_systemd_service

summary

}

main