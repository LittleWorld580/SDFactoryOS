#!/usr/bin/env python3
import RPi.GPIO as GPIO
import time
import random

# ================================
# CONFIG
# ================================
LEDS = [17, 27, 22, 23]  # BCM pins (update if needed)
DELAY_FAST = 0.05
DELAY_MED = 0.1
DELAY_SLOW = 0.2

# ================================
# SETUP
# ================================
GPIO.setmode(GPIO.BCM)

for pin in LEDS:
    GPIO.setup(pin, GPIO.OUT)
    GPIO.output(pin, GPIO.LOW)

def all_off():
    for pin in LEDS:
        GPIO.output(pin, GPIO.LOW)

def all_on():
    for pin in LEDS:
        GPIO.output(pin, GPIO.HIGH)

# ================================
# PATTERNS
# ================================

def scanner(cycles=10):
    for _ in range(cycles):
        for pin in LEDS:
            all_off()
            GPIO.output(pin, GPIO.HIGH)
            time.sleep(DELAY_FAST)
        for pin in reversed(LEDS):
            all_off()
            GPIO.output(pin, GPIO.HIGH)
            time.sleep(DELAY_FAST)

def strobe(cycles=20):
    for _ in range(cycles):
        all_on()
        time.sleep(0.03)
        all_off()
        time.sleep(0.03)

def wave(cycles=10):
    for _ in range(cycles):
        for i in range(len(LEDS)):
            all_off()
            for j in range(i + 1):
                GPIO.output(LEDS[j], GPIO.HIGH)
            time.sleep(DELAY_MED)
        for i in reversed(range(len(LEDS))):
            all_off()
            for j in range(i + 1):
                GPIO.output(LEDS[j], GPIO.HIGH)
            time.sleep(DELAY_MED)

def random_flash(cycles=30):
    for _ in range(cycles):
        all_off()
        GPIO.output(random.choice(LEDS), GPIO.HIGH)
        time.sleep(0.05)

def burst(cycles=5):
    for _ in range(cycles):
        for _ in range(3):
            all_on()
            time.sleep(0.05)
            all_off()
            time.sleep(0.05)
        time.sleep(0.2)

# ================================
# MAIN LOOP
# ================================
try:
    while True:
        scanner()
        strobe()
        wave()
        random_flash()
        burst()

except KeyboardInterrupt:
    pass
finally:
    all_off()
    GPIO.cleanup()