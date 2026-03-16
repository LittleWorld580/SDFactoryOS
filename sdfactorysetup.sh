#!/bin/bash
set -euo pipefail

#######################################
# SD FACTORY SIMPLE PI SETUP
#######################################

FACTORY_USER="sdfactory"
FACTORY_HOME="/home/$FACTORY_USER"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVICE_NAME="wio-serial-panel.service"
GPIO_INIT_SERVICE_NAME="sd-factory-gpio-init.service"
GPIO_INIT_SCRIPT="/usr/local/bin/sd-factory-gpio-init.sh"
SUDOERS_FILE="/etc/sudoers.d/sdfactory"

# GPIO CONFIG
START_BUTTON_PIN=17
WORKING_LED_PIN=27
COMPLETE_LED_PIN=22
READY_LED_PIN=23

# Files expected to be in the same folder as this setup script
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
  "sdfactoryosupdate.sh"
  "sdfactoryeasyromsupdate.sh"
  "sdfactorysettingsupdate.sh"
)

OPTIONAL_FILES=(
  ".bash_profile"
)

log() {
    echo "[SD-FACTORY-SETUP] $*"
}

fail() {
    echo "[SD-FACTORY-SETUP] ERROR: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Run this script with sudo or as root."
    fi
}

check_required_files() {
    log "Checking required files in: $SCRIPT_DIR"
    local missing=0
    for f in "${REQUIRED_FILES[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
            echo "Missing required file: $f"
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        fail "One or more required files are missing."
    fi
}

create_user_if_needed() {
    if id "$FACTORY_USER" >/dev/null 2>&1; then
        log "User $FACTORY_USER already exists."
    else
        log "Creating user: $FACTORY_USER"
        useradd -m -s /bin/bash "$FACTORY_USER"
    fi
}

install_packages() {
    log "Installing required packages"
    apt-get update
    apt-get install -y \
        python3 \
        python3-serial \
        python3-rpi.gpio \
        rsync \
        git \
        sudo
}

copy_scripts() {
    log "Copying scripts to $FACTORY_HOME"
    mkdir -p "$FACTORY_HOME"

    for f in "${REQUIRED_FILES[@]}"; do
        install -m 755 "$SCRIPT_DIR/$f" "$FACTORY_HOME/$f"
    done

    # Optional .bash_profile replacement
    if [[ -f "$SCRIPT_DIR/.bash_profile" ]]; then
        log "Replacing $FACTORY_HOME/.bash_profile"
        install -m 644 "$SCRIPT_DIR/.bash_profile" "$FACTORY_HOME/.bash_profile"
    else
        log "No .bash_profile found in setup folder, skipping."
    fi

    chown -R "$FACTORY_USER:$FACTORY_USER" "$FACTORY_HOME"
}

set_permissions() {
    log "Setting script permissions"
    chmod +x "$FACTORY_HOME"/*.sh || true
    chmod +x "$FACTORY_HOME/wio_serial_panel.py" || true
    chown -R "$FACTORY_USER:$FACTORY_USER" "$FACTORY_HOME"
}

write_sudoers() {
    log "Writing sudoers file: $SUDOERS_FILE"

    cat > "$SUDOERS_FILE" <<EOF
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/autoimagecreate.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/autosdprep.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/autosdworkflow.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/autosettingsreplace.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/enableterminal.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/autodtbreplace.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/autoeasyromreplace.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/autoeject.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/sdfactoryosupdate.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/sdfactoryeasyromsupdate.sh
$FACTORY_USER ALL=(ALL) NOPASSWD: /home/$FACTORY_USER/sdfactorysettingsupdate.sh

# Optional common admin commands
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/sbin/reboot
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/sbin/shutdown
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/mount
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/umount
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/rsync
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/cp
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/mv
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/rm
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/chown
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/chmod
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/tee
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/kill
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/pkill
$FACTORY_USER ALL=(ALL) NOPASSWD: /usr/bin/python3
EOF

    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE"
}

write_gpio_init_script() {
    log "Writing GPIO init script: $GPIO_INIT_SCRIPT"

    cat > "$GPIO_INIT_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

# Wait briefly for GPIO subsystem
sleep 1

# Try libgpiod first
if command -v gpioset >/dev/null 2>&1; then
    CHIP="/dev/gpiochip0"

    # Set output defaults
    gpioset "\$CHIP" $WORKING_LED_PIN=0 $COMPLETE_LED_PIN=0 $READY_LED_PIN=1 >/dev/null 2>&1 || true
fi

# Try raspi-gpio if available
if command -v raspi-gpio >/dev/null 2>&1; then
    raspi-gpio set $WORKING_LED_PIN op dl || true
    raspi-gpio set $COMPLETE_LED_PIN op dl || true
    raspi-gpio set $READY_LED_PIN op dh || true
fi

exit 0
EOF

    chmod 755 "$GPIO_INIT_SCRIPT"
}

write_gpio_init_service() {
    log "Writing GPIO init service"

    cat > "/etc/systemd/system/$GPIO_INIT_SERVICE_NAME" <<EOF
[Unit]
Description=SD Factory GPIO Init
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$GPIO_INIT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_wio_service() {
    log "Writing Wio serial panel service"

    cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=SD Factory Wio Serial Panel
After=network.target $GPIO_INIT_SERVICE_NAME
Wants=$GPIO_INIT_SERVICE_NAME

[Service]
Type=simple
User=$FACTORY_USER
WorkingDirectory=$FACTORY_HOME
ExecStart=/usr/bin/python3 $FACTORY_HOME/wio_serial_panel.py
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_services() {
    log "Reloading systemd"
    systemctl daemon-reload

    log "Enabling GPIO init service"
    systemctl enable "$GPIO_INIT_SERVICE_NAME"

    log "Enabling Wio serial panel service"
    systemctl enable "$SERVICE_NAME"
}

start_services() {
    log "Starting GPIO init service"
    systemctl restart "$GPIO_INIT_SERVICE_NAME" || true

    log "Starting Wio serial panel service"
    systemctl restart "$SERVICE_NAME" || true
}

show_status() {
    echo
    log "Setup complete."
    echo
    echo "Service status:"
    systemctl --no-pager --full status "$GPIO_INIT_SERVICE_NAME" || true
    echo
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    echo
    echo "Installed files in $FACTORY_HOME:"
    ls -la "$FACTORY_HOME"
    echo
    echo "Useful commands:"
    echo "  sudo systemctl status $SERVICE_NAME"
    echo "  sudo journalctl -u $SERVICE_NAME -f"
    echo "  sudo systemctl restart $SERVICE_NAME"
}

main() {
    require_root
    check_required_files
    create_user_if_needed
    install_packages
    copy_scripts
    set_permissions
    write_sudoers
    write_gpio_init_script
    write_gpio_init_service
    write_wio_service
    enable_services
    start_services
    show_status
}

main "$@"