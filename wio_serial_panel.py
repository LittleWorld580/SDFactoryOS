#!/usr/bin/env python3

import serial
import subprocess
import time
import os
import glob

# =====================================
# CONFIG
# =====================================

BAUD_RATE = 115200
SERIAL_TIMEOUT = 1
COMMAND_TIMEOUT = 300

# HW START BUTTON CONFIG
HW_START_GPIO = 17
HW_START_ACTIVE_LOW = True      # True = press pulls pin LOW, False = press drives pin HIGH
HW_START_PRESS_TIME = 0.25      # seconds

COMMANDS = {
    "REBOOT": "sudo reboot",
    "SHUTDOWN": "sudo shutdown now",
    "ENABLE_TERMINAL": "/home/sdfactory/enableterminal.sh",
    "HW_START_BUTTON": "__HW_START_BUTTON__",
    "WORKFLOW": "/home/sdfactory/autosdworkflow.sh",
    "SDPREP": "/home/sdfactory/autosdprep.sh",
    "AUTO_EJECT": "/home/sdfactory/autoeject.sh",
    "IMAGE_CREATE": "/home/sdfactory/autoimagecreate.sh",
    "DTB_REPLACE": "/home/sdfactory/autodtbreplace.sh",
    "SETTINGS_REPLACE": "/home/sdfactory/autosettingsreplace.sh",
    "EASYROM_REPLACE": "/home/sdfactory/autoeasyromreplace.sh",

    # Future / hidden from Wio menu for now
    "DEVBUTROMUPDATE": "__FUTURE__",
    "DEVROMUPDATE": "__FUTURE__",
    "SDFSETTINGSUPDATE": "__FUTURE__",
    "SDFEASYROMUPDATE": "__FUTURE__",

    # Active visible options
    "SDFOSUPDATE": "/home/sdfactory/sdfactoryosupdate.sh",
    "SETUP": "/home/sdfactory/setup.sh",
}

# =====================================
# HELPERS
# =====================================

def log(msg):
    print(msg, flush=True)

def find_wio_port():
    candidates = []
    candidates.extend(sorted(glob.glob("/dev/ttyACM*")))
    candidates.extend(sorted(glob.glob("/dev/ttyUSB*")))
    return candidates[0] if candidates else None

def short_output(text, limit=180):
    text = (text or "").strip().replace("\r", " ").replace("\n", " | ")
    if len(text) > limit:
        return text[:limit - 3] + "..."
    return text if text else "Done"

def validate_script(path):
    if not os.path.exists(path):
        return False, f"Script not found: {path}"
    if not os.path.isfile(path):
        return False, f"Not a file: {path}"
    if not os.access(path, os.X_OK):
        return False, f"Script not executable: {path}"
    return True, "OK"

def press_hw_start_button():
    try:
        import RPi.GPIO as GPIO
    except Exception as e:
        return False, f"RPi.GPIO not available: {e}"

    try:
        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BCM)

        idle_state = GPIO.HIGH if HW_START_ACTIVE_LOW else GPIO.LOW
        pressed_state = GPIO.LOW if HW_START_ACTIVE_LOW else GPIO.HIGH

        GPIO.setup(HW_START_GPIO, GPIO.OUT, initial=idle_state)

        GPIO.output(HW_START_GPIO, pressed_state)
        time.sleep(HW_START_PRESS_TIME)
        GPIO.output(HW_START_GPIO, idle_state)

        return True, f"HW start button pressed on GPIO {HW_START_GPIO}"

    except Exception as e:
        return False, f"GPIO press failed: {e}"

def run_shell_command(cmd_key):
    if cmd_key not in COMMANDS:
        return False, f"Unknown command: {cmd_key}"

    cmd = COMMANDS[cmd_key]

    try:
        if cmd_key == "REBOOT":
            subprocess.Popen("sudo shutdown -r now", shell=True)
            return True, "Reboot command sent"

        if cmd_key == "SHUTDOWN":
            subprocess.Popen("sudo shutdown now", shell=True)
            return True, "Shutdown command sent"

        if cmd_key == "HW_START_BUTTON":
            return press_hw_start_button()

        if cmd == "__FUTURE__":
            return False, f"{cmd_key} not implemented yet"

        if cmd.startswith("/"):
            valid, msg = validate_script(cmd)
            if not valid:
                return False, msg

            result = subprocess.run(
                ["sudo", cmd],
                capture_output=True,
                text=True,
                timeout=COMMAND_TIMEOUT
            )
        else:
            result = subprocess.run(
                cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=COMMAND_TIMEOUT
            )

        output = (result.stdout or "") + "\n" + (result.stderr or "")
        output = short_output(output)

        if result.returncode == 0:
            return True, output

        return False, f"Exit {result.returncode}: {output}"

    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as e:
        return False, str(e)

# =====================================
# MAIN LOOP
# =====================================

def main():
    while True:
        port = find_wio_port()

        if not port:
            log("Waiting for Wio Terminal serial port...")
            time.sleep(2)
            continue

        log(f"Opening serial port: {port}")

        try:
            with serial.Serial(port, BAUD_RATE, timeout=SERIAL_TIMEOUT) as ser:
                time.sleep(2)
                log("Connected to Wio Terminal")

                ser.write(b"READY\n")
                ser.flush()
                log("TX: READY")

                while True:
                    raw = ser.readline()

                    if not raw:
                        continue

                    line = raw.decode(errors="ignore").replace("\x00", "").strip()

                    if not line:
                        continue

                    log(f"RX: {repr(line)}")

                    if not line.startswith("CMD:"):
                        log(f"Ignoring non-command serial data: {repr(line)}")
                        continue

                    cmd_key = line[4:].strip()

                    if not cmd_key:
                        log("Ignoring empty CMD payload")
                        continue

                    ok, message = run_shell_command(cmd_key)

                    prefix = "OK:" if ok else "ERR:"
                    reply = f"{prefix}{message}\n"

                    try:
                        ser.write(reply.encode())
                        ser.flush()
                        log(f"TX: {reply.strip()}")
                    except Exception as e:
                        log(f"Failed to send serial reply: {e}")

        except serial.SerialException as e:
            log(f"Serial error: {e}")
            time.sleep(2)
        except KeyboardInterrupt:
            log("Stopped by user")
            break
        except Exception as e:
            log(f"Unexpected error: {e}")
            time.sleep(2)

if __name__ == "__main__":
    main()