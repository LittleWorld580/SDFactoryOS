#!/bin/bash
set -e

#######################################
# SD FACTORY MACHINE SETUP
#######################################

FACTORY_USER="sdfactory"
FACTORY_HOME="/home/sdfactory"
SERVICE_NAME="wio-serial-panel.service"

log() {
    echo "[SETUP] $*"
}

#######################################
# VERIFY DIRECTORY
#######################################

if [ ! -d "$FACTORY_HOME" ]; then
    echo "ERROR: $FACTORY_HOME does not exist"
    exit 1
fi

log "Using directory: $FACTORY_HOME"

#######################################
# INSTALL REQUIRED PACKAGES
#######################################

log "Installing required Python packages..."

apt update
apt install -y python3-serial

#######################################
# FIX OWNERSHIP
#######################################

log "Fixing ownership..."
chown -R sdfactory:sdfactory "$FACTORY_HOME"

#######################################
# MAKE ALL SCRIPTS EXECUTABLE
#######################################

log "Setting script permissions..."

chmod +x $FACTORY_HOME/*.sh || true
chmod +x $FACTORY_HOME/*.py || true

#######################################
# INSTALL .bash_profile
#######################################

log "Installing .bash_profile..."

cat > "$FACTORY_HOME/.bash_profile" << 'EOF'
# SD Factory boot profile

# Load bashrc
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# Start workflow automatically
if [ -x /home/sdfactory/autosdworkflow.sh ]; then
    /home/sdfactory/autosdworkflow.sh
fi
EOF

chown sdfactory:sdfactory "$FACTORY_HOME/.bash_profile"

#######################################
# CREATE WIO SERIAL PANEL SERVICE
#######################################

log "Installing WIO service..."

cat > /etc/systemd/system/wio-serial-panel.service <<EOF
[Unit]
Description=SD Factory WIO Serial Panel
After=network.target

[Service]
Type=simple
User=sdfactory
WorkingDirectory=/home/sdfactory
ExecStart=/usr/bin/python3 /home/sdfactory/wio_serial_panel.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

#######################################
# ENABLE SERVICE
#######################################

log "Reloading systemd..."

systemctl daemon-reload
systemctl enable wio-serial-panel.service
systemctl restart wio-serial-panel.service

#######################################
# COMPLETE
#######################################

log "SD Factory setup complete."
log "Reboot recommended."