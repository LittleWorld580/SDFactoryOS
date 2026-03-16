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

# GPIO CONFIG
START_BUTTON_PIN=17
WORKING_LED_PIN=27
COMPLETE_LED_PIN=22
READY_LED_PIN=23

REQUIRED_FILES=(
autoimagecreate.sh
autosdprep.sh
autosdworkflow.sh
autosettingsreplace.sh
enableterminal.sh
wio_serial_panel.py
autodtbreplace.sh
autoeasyromreplace.sh
autoeject.sh
sdfactoryosupdate.sh
sdfactoryeasyromsupdate.sh
sdfactorysettingsupdate.sh
)

#######################################
# FUNCTIONS
#######################################

log(){
echo "[SETUP] $*"
}

fail(){
echo "[SETUP ERROR] $*" >&2
exit 1
}

require_root(){
[ "${EUID:-0}" -eq 0 ] || fail "Run with sudo"
}

check_user(){
id "$FACTORY_USER" >/dev/null 2>&1 || fail "User $FACTORY_USER does not exist"
}

check_required_files(){
log "Checking required files..."

for file in "${REQUIRED_FILES[@]}"; do
    [ -f "$SCRIPT_DIR/$file" ] || fail "Missing required file: $file"
done
}

#######################################
# PACKAGE INSTALL
#######################################

install_packages(){
log "Installing packages..."

apt-get update

apt-get install -y \
git \
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

#######################################
# USER + GPIO ACCESS
#######################################

setup_gpio_user_access(){
log "Configuring GPIO access..."

getent group gpio >/dev/null 2>&1 || groupadd --system gpio
usermod -aG gpio "$FACTORY_USER"
}

#######################################
# DIRECTORY SETUP
#######################################

create_directories(){
log "Creating directories..."

mkdir -p "$FACTORY_HOME"
mkdir -p "$FACTORY_HOME/logs"

mkdir -p /mnt/sdboot
mkdir -p /mnt/sdroot
mkdir -p /mnt/easyroms
mkdir -p /mnt/settingsroot

chown -R "$FACTORY_USER:$FACTORY_USER" "$FACTORY_HOME"
}

#######################################
# SCRIPT INSTALL
#######################################

install_scripts(){
log "Installing factory scripts..."

for file in "${REQUIRED_FILES[@]}"; do
    install "$SCRIPT_DIR/$file" "$FACTORY_HOME/$file"
    chown "$FACTORY_USER:$FACTORY_USER" "$FACTORY_HOME/$file"
    log "Installed $file"
done
}

#######################################
# MAKE ALL SCRIPTS EXECUTABLE
#######################################

make_scripts_executable(){
log "Making all factory scripts executable individually..."

for file in "${REQUIRED_FILES[@]}"; do
    chmod +x "$FACTORY_HOME/$file"
    chown "$FACTORY_USER:$FACTORY_USER" "$FACTORY_HOME/$file"
    log "chmod +x applied to $FACTORY_HOME/$file"
done
}

#######################################
# SUDOERS RULES
#######################################

write_sudoers(){
log "Creating sudo rules..."

cat > "$SUDOERS_FILE" <<EOF
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autosdworkflow.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autosdprep.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autoimagecreate.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autodtbreplace.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autosettingsreplace.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autoeasyromreplace.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/autoeject.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/enableterminal.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/sdfactoryosupdate.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/sdfactoryeasyromsupdate.sh
sdfactory ALL=(ALL) NOPASSWD: /home/sdfactory/sdfactorysettingsupdate.sh
sdfactory ALL=(ALL) NOPASSWD: /usr/sbin/shutdown
sdfactory ALL=(ALL) NOPASSWD: /usr/bin/systemctl
sdfactory ALL=(ALL) NOPASSWD: /usr/bin/pinctrl
EOF

chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"
}

#######################################
# GPIO INIT SCRIPT
#######################################

write_gpio_init_script(){
log "Creating GPIO init script..."

cat > "$GPIO_INIT_SCRIPT" <<EOF
#!/bin/bash

START_BUTTON_PIN=$START_BUTTON_PIN
WORKING_LED_PIN=$WORKING_LED_PIN
COMPLETE_LED_PIN=$COMPLETE_LED_PIN
READY_LED_PIN=$READY_LED_PIN

pinctrl set "\$WORKING_LED_PIN" op dl
pinctrl set "\$COMPLETE_LED_PIN" op dl
pinctrl set "\$READY_LED_PIN" op dl

pinctrl set "\$START_BUTTON_PIN" ip pu

pinctrl set "\$READY_LED_PIN" op dh
sleep 0.2
pinctrl set "\$READY_LED_PIN" op dl
EOF

chmod 755 "$GPIO_INIT_SCRIPT"
}

#######################################
# SYSTEMD SERVICES
#######################################

write_systemd_services(){
log "Creating systemd services..."

cat > /etc/systemd/system/$GPIO_INIT_SERVICE_NAME <<EOF
[Unit]
Description=SD Factory GPIO Init

[Service]
Type=oneshot
ExecStart=$GPIO_INIT_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=Wio Serial Panel
After=$GPIO_INIT_SERVICE_NAME

[Service]
User=$FACTORY_USER
WorkingDirectory=$FACTORY_HOME
ExecStart=/usr/bin/python3 $FACTORY_HOME/wio_serial_panel.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$GPIO_INIT_SERVICE_NAME"
systemctl enable "$SERVICE_NAME"
}

#######################################
# SUMMARY
#######################################

summary(){
echo
echo "=================================="
echo " SD FACTORY INSTALL COMPLETE"
echo "=================================="
echo
echo "Service status:"
echo "systemctl status $SERVICE_NAME"
echo
echo "Logs:"
echo "tail -f $FACTORY_HOME/logs/wio_serial_panel.log"
echo
echo "GPIO test:"
echo "pinctrl get $START_BUTTON_PIN"
echo
}

#######################################
# MAIN
#######################################

main(){
require_root
check_user
check_required_files

install_packages
setup_gpio_user_access
create_directories

install_scripts
make_scripts_executable

write_sudoers
write_gpio_init_script
write_systemd_services

summary
}

main