#!/bin/bash
set -euo pipefail

#######################################
# SD FACTORY SETUP
#######################################

FACTORY_USER="sdfactory"
FACTORY_HOME="/home/$FACTORY_USER"
SERVICE_NAME="wio-serial-panel.service"
GPIO_INIT_SERVICE_NAME="sd-factory-gpio-init.service"
GPIO_INIT_SCRIPT="/usr/local/bin/sd-factory-gpio-init.sh"
SUDOERS_FILE="/etc/sudoers.d/sdfactory"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GPIO CONFIG (BCM numbering)
START_BUTTON_PIN=17
WORKING_LED_PIN=27
COMPLETE_LED_PIN=22
READY_LED_PIN=23

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
        dosfstools \
        raspi-utils
}

setup_gpio_user_access() {
    log "Ensuring gpio group access for $FACTORY_USER..."
    getent group gpio >/dev/null 2>&1 || groupadd --system gpio
    usermod -aG gpio "$FACTORY_USER"
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
sdfactory ALL=(ALL) NOPASSWD: /usr/bin/pinctrl
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

write_gpio_init_script() {
    log "Creating GPIO init script..."

cat > "$GPIO_INIT_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

START_BUTTON_PIN=$START_BUTTON_PIN
WORKING_LED_PIN=$WORKING_LED_PIN
COMPLETE_LED_PIN=$COMPLETE_LED_PIN
READY_LED_PIN=$READY_LED_PIN

command -v pinctrl >/dev/null 2>&1 || exit 1

# LEDs as outputs, default OFF
pinctrl set "\$WORKING_LED_PIN" op dl
pinctrl set "\$COMPLETE_LED_PIN" op dl
pinctrl set "\$READY_LED_PIN" op dl

# START button as input with pull-up
pinctrl set "\$START_BUTTON_PIN" ip pu

# Quick visible LED test at boot
pinctrl set "\$READY_LED_PIN" op dh
sleep 0.15
pinctrl set "\$READY_LED_PIN" op dl

pinctrl set "\$WORKING_LED_PIN" op dh
sleep 0.15
pinctrl set "\$WORKING_LED_PIN" op dl

pinctrl set "\$COMPLETE_LED_PIN" op dh
sleep 0.15
pinctrl set "\$COMPLETE_LED_PIN" op dl
EOF

    chmod 755 "$GPIO_INIT_SCRIPT"
}

write_gpio_init_service() {
    log "Creating GPIO init systemd service..."

cat > "/etc/systemd/system/$GPIO_INIT_SERVICE_NAME" <<EOF
[Unit]
Description=SD Factory GPIO Initialization
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target $SERVICE_NAME

[Service]
Type=oneshot
ExecStart=$GPIO_INIT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_systemd_service() {
    log "Creating systemd service..."

cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=SD Factory Wio Serial Panel
After=multi-user.target $GPIO_INIT_SERVICE_NAME
Requires=$GPIO_INIT_SERVICE_NAME

[Service]
Type=simple
User=$FACTORY_USER
WorkingDirectory=$FACTORY_HOME
ExecStart=/usr/bin/python3 /home/sdfactory/wio_serial_panel.py
Restart=always
RestartSec=2
StandardOutput=append:/home/sdfactory/logs/wio_serial_panel.log
StandardError=append:/home/sdfactory/logs/wio_serial_panel.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$GPIO_INIT_SERVICE_NAME"
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$GPIO_INIT_SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
}

verify_gpio_tools() {
    log "Verifying GPIO tools..."
    command -v pinctrl >/dev/null 2>&1 || fail "pinctrl command not found after install"
    pinctrl get "$START_BUTTON_PIN" >/dev/null 2>&1 || fail "Unable to access GPIO $START_BUTTON_PIN with pinctrl"
}

summary() {
echo
echo "=============================="
echo " SD FACTORY SETUP COMPLETE"
echo "=============================="
echo
echo "GPIO init service:"
echo "  systemctl status $GPIO_INIT_SERVICE_NAME"
echo
echo "Wio panel service:"
echo "  systemctl status $SERVICE_NAME"
echo
echo "View Wio logs:"
echo "  tail -f /home/sdfactory/logs/wio_serial_panel.log"
echo
echo "Check GPIO states:"
echo "  pinctrl get $START_BUTTON_PIN"
echo "  pinctrl get $WORKING_LED_PIN"
echo "  pinctrl get $COMPLETE_LED_PIN"
echo "  pinctrl get $READY_LED_PIN"
echo
echo "Workflow autostarts on console login"
echo
}

main() {
    require_root
    check_user
    check_required_files

    install_packages
    setup_gpio_user_access
    create_directories
    install_scripts
    write_sudoers
    configure_bash_profile
    write_gpio_init_script
    write_gpio_init_service
    write_systemd_service
    verify_gpio_tools
    summary
}

main