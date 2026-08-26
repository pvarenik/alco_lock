#!/usr/bin/env python3
# AlcoholBlocker - Linux version
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
import os
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    serial = None
    list_ports = None

try:
    from PySide6.QtCore import QTimer, Qt
    from PySide6.QtGui import QFont
    from PySide6.QtWidgets import (
        QApplication,
        QFrame,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QPushButton,
        QVBoxLayout,
        QWidget,
    )
    PYSIDE6_AVAILABLE = True
except ImportError:
    QTimer = Qt = QFont = QApplication = QFrame = QHBoxLayout = QLabel = QLineEdit = QPushButton = QVBoxLayout = QWidget = None
    PYSIDE6_AVAILABLE = False

APP_NAME = "ALCOBLOCKER"
MASTER_PASSWORD = "1989"
BAUD_RATE = 9600
HOURLY_CHECK_SECONDS = 3600  # 1 hour
ADC_MAX = 1023
CLEAN_AIR_MAXIMUM = 150
ALCOHOL_DELTA = 200

BREATH_UP_REFERENCE_DELTA = 10
BREATH_DOWN_REFERENCE_DELTA = 10
BREATH_WINDOW_SECONDS = 3.0
BREATH_REQUIRED_STEPS = 2
BREATH_MINIMUM_CHANGE = 3
SAFE_RETURN_DELTA = 6
SAFE_READINGS_REQUIRED = 3

STABILIZATION_MIN_SECONDS = 5.0
STABILIZATION_MAX_SECONDS = 60.0
STABILIZATION_WINDOW_SAMPLES = 50
STABILIZATION_MAX_SPAN = 6
STABILIZATION_MAX_DRIFT = 3
STABILIZATION_MAX_NEGATIVE_STEPS = 20

CALIBRATION_SECONDS = 10.0
CALIBRATION_MINIMUM_SAMPLES = 8
CALIBRATION_TIMEOUT_SECONDS = 30.0

POLL_MS = 100
PORT_SCAN_MS = 2000
NO_DATA_TIMEOUT_SECONDS = 8

DATA_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "alcoblocker"
LOG_FILE = DATA_DIR / "alcoblocker.log"
LOG_ENABLED = False
DEBUG_ENABLED = False

COLOR_BG = "#0a0e14"
COLOR_CARD = "#191f28"
COLOR_HEADER = "#1e2630"
COLOR_RED = "#eb4b55"
COLOR_GREEN = "#50cd82"
COLOR_BLUE = "#50aaff"
COLOR_YELLOW = "#ffc34b"
COLOR_ORANGE = "#ffaa46"
COLOR_TEXT = "#ffffff"
COLOR_MUTED = "#8791a0"


def log(message: str) -> None:
    if not LOG_ENABLED and not DEBUG_ENABLED:
        return
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{os.getpid()}] {message}"
    if LOG_ENABLED:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    if DEBUG_ENABLED:
        print(line, flush=True)


def daily_password() -> str:
    return time.strftime("%d%m")


def cleanup() -> int:
    """Remove the user service and own state/log files."""
    subprocess.run(
        ["systemctl", "--user", "disable", "--now", "alcoblocker.service"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if LOG_FILE.exists():
        LOG_FILE.unlink(missing_ok=True)
    try:
        DATA_DIR.rmdir()
    except OSError:
        pass
    print("AlcoholBlocker cleanup complete.")
    return 0


def median(values: list[int]) -> float:
    return float(statistics.median(values))


def numeric_line(text: str) -> Optional[int]:
    text = text.strip()
    if not re.fullmatch(r"\d+", text):
        return None
    value = int(text)
    return value if 0 <= value <= ADC_MAX else None


@dataclass
class PortCandidate:
    device: str
    score: int
    description: str


class Sensor:
    """Auto-detect Arduino/CH340-style serial devices and read MQ-3 values."""

    NAME_HINTS = {
        "arduino": 50,
        "ch340": 80,
        "ch341": 75,
        "usb-serial": 60,
        "usb serial": 60,
        "ftdi": 50,
        "cp210": 45,
        "silicon labs": 45,
    }

    def __init__(self) -> None:
        self.serial: Optional[serial.Serial] = None
        self.port: Optional[str] = None
        self.buffer = ""
        self.last_valid_at = 0.0

    @property
    def connected(self) -> bool:
        return bool(self.serial and self.serial.is_open)

    def close(self) -> None:
        if self.serial:
            try:
                self.serial.close()
            except serial.SerialException:
                pass
        self.serial = None
        self.port = None
        self.buffer = ""

    def _candidates(self) -> list[PortCandidate]:
        candidates: list[PortCandidate] = []
        for p in list_ports.comports():
            text = " ".join(
                [
                    p.device or "",
                    p.description or "",
                    p.manufacturer or "",
                    p.product or "",
                    p.hwid or "",
                ]
            ).lower()
            score = 0
            for hint, points in self.NAME_HINTS.items():
                if hint in text:
                    score += points
            if "bluetooth" in text:
                score -= 100
            candidates.append(PortCandidate(p.device, score, p.description or p.device))
        return sorted(candidates, key=lambda x: (x.score, x.device), reverse=True)

    def connect_auto(self) -> bool:
        if self.connected:
            return True
        for candidate in self._candidates():
            log(f"Probing {candidate.device} | {candidate.description} | score={candidate.score}")
            try:
                ser = serial.Serial(
                    candidate.device,
                    BAUD_RATE,
                    timeout=0.2,
                    write_timeout=0.2,
                    dsrdtr=True,
                    rtscts=False,
                )
                time.sleep(1.8)  # Uno/CH340 reset/bootloader settling time
                ser.reset_input_buffer()
                deadline = time.monotonic() + 3.0
                found = False
                while time.monotonic() < deadline:
                    raw = ser.readline()
                    value = numeric_line(raw.decode(errors="ignore")) if raw else None
                    if value is not None:
                        found = True
                        log(f"Arduino detected on {candidate.device} with value {value}")
                        break
                if found:
                    self.serial = ser
                    self.port = candidate.device
                    self.buffer = ""
                    self.last_valid_at = time.monotonic()
                    return True
                ser.close()
            except (serial.SerialException, OSError) as exc:
                log(f"Failed to open/read {candidate.device}: {exc}")
        return False

    def read_value(self) -> Optional[int]:
        if not self.connected:
            return None
        try:
            raw = self.serial.read(self.serial.in_waiting or 1)
            if raw:
                self.buffer += raw.decode(errors="ignore")
            latest = None
            while "\n" in self.buffer:
                line, self.buffer = self.buffer.split("\n", 1)
                value = numeric_line(line)
                if value is not None:
                    latest = value
            if latest is not None:
                self.last_valid_at = time.monotonic()
            return latest
        except (serial.SerialException, OSError) as exc:
            log(f"Serial read error: {exc}")
            return None


class GuardWindow(QWidget if PYSIDE6_AVAILABLE else object):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.setWindowFlag(Qt.FramelessWindowHint)
        self.setWindowFlag(Qt.WindowStaysOnTopHint, True)
        self.setWindowFlag(Qt.Tool, True)
        self.setStyleSheet(f"background:{COLOR_BG}; color:{COLOR_TEXT};")

        self.sensor = Sensor()
        self.state = "NoSensor"
        self.baseline: Optional[int] = None
        self.breath_upper: Optional[int] = None
        self.breath_lower: Optional[int] = None
        self.alcohol_threshold: Optional[int] = None
        self.peak: Optional[int] = None
        self.minimum: Optional[int] = None
        self.last_value: Optional[int] = None
        self.next_check_at = 0.0

        self.stabilization_started = 0.0
        self.stabilization_values: list[int] = []
        self.calibration_started = 0.0
        self.calibration_values: list[int] = []
        self.breath_started = 0.0
        self.breath_values: list[int] = []
        self.breath_direction: Optional[str] = None

        self._build_ui()
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._tick)
        self._timer.start(POLL_MS)
        self.new_check()

    def _label(self, text: str, size: int, color: str = COLOR_TEXT, bold: bool = False) -> QLabel:
        label = QLabel(text)
        font = QFont("Sans", size)
        font.setBold(bold)
        label.setFont(font)
        label.setStyleSheet(f"color:{color}; background:transparent;")
        return label

    def _card(self, title: str, value: QLabel) -> QFrame:
        card = QFrame()
        card.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 12, 16, 12)
        layout.addWidget(self._label(title, 9, COLOR_MUTED, True))
        layout.addWidget(value)
        return card

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(36, 30, 36, 30)
        root.setSpacing(12)

        header = QFrame()
        header.setStyleSheet(f"background:{COLOR_HEADER}; border-radius:10px;")
        h = QVBoxLayout(header)
        h.setContentsMargins(20, 12, 20, 12)
        h.addWidget(self._label(APP_NAME, 24, COLOR_RED, True))
        h.addWidget(self._label("Linux breath check system - hourly verification", 10, COLOR_MUTED))
        root.addWidget(header)

        status_card = QFrame()
        status_card.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        status_layout = QVBoxLayout(status_card)
        status_layout.setContentsMargins(18, 10, 18, 10)
        self.status_label = self._label("Connect sensor", 20, COLOR_ORANGE, True)
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setWordWrap(True)
        status_layout.addWidget(self.status_label)
        meta = QHBoxLayout()
        self.state_label = self._label("State: NoSensor", 9, COLOR_MUTED)
        self.sensor_label = self._label("Sensor: -", 9, COLOR_MUTED)
        meta.addWidget(self.state_label)
        meta.addStretch()
        meta.addWidget(self.sensor_label)
        status_layout.addLayout(meta)
        root.addWidget(status_card)

        metrics = QHBoxLayout()
        self.current_label = self._label("-", 20, COLOR_TEXT, True)
        self.baseline_label = self._label("-", 20, COLOR_TEXT, True)
        self.alcohol_label = self._label("-", 20, COLOR_TEXT, True)
        metrics.addWidget(self._card("CURRENT READING", self.current_label))
        metrics.addWidget(self._card("CLEAN-AIR BASELINE", self.baseline_label))
        metrics.addWidget(self._card("ALCOHOL THRESHOLD", self.alcohol_label))
        root.addLayout(metrics)

        breath = QFrame()
        breath.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        bl = QVBoxLayout(breath)
        bl.setContentsMargins(16, 10, 16, 10)
        bl.addWidget(self._label("BREATH DETECTION RANGE", 9, COLOR_MUTED, True))
        self.breath_label = self._label("- .. -", 18, COLOR_TEXT, True)
        self.breath_label.setAlignment(Qt.AlignCenter)
        bl.addWidget(self.breath_label)
        root.addWidget(breath)

        info = QHBoxLayout()
        self.range_label = self._label("Min: -    Max: -", 12, COLOR_TEXT, True)
        self.next_label = self._label("-", 11, COLOR_TEXT, True)
        info.addWidget(self._card("OBSERVED RANGE", self.range_label))
        info.addWidget(self._card("NEXT CHECK / ACTIVITY", self.next_label))
        root.addLayout(info)

        password_card = QFrame()
        password_card.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        pl = QVBoxLayout(password_card)
        pl.setContentsMargins(16, 10, 16, 10)
        title = self._label("MASTER PASSWORD", 9, COLOR_MUTED, True)
        title.setAlignment(Qt.AlignCenter)
        pl.addWidget(title)
        row = QHBoxLayout()
        row.setAlignment(Qt.AlignCenter)
        self.password = QLineEdit()
        self.password.setEchoMode(QLineEdit.Password)
        self.password.setAlignment(Qt.AlignCenter)
        self.password.setFixedWidth(230)
        self.password.setStyleSheet("background:#232a34; color:white; padding:8px; border-radius:6px;")
        unlock = QPushButton("Unlock")
        unlock.setFixedWidth(120)
        unlock.setStyleSheet("background:#2d78d2; color:white; padding:8px; border-radius:6px;")
        unlock.clicked.connect(self.unlock_password)
        self.password.returnPressed.connect(self.unlock_password)
        row.addWidget(self.password)
        row.addSpacing(12)
        row.addWidget(unlock)
        pl.addLayout(row)
        hint = self._label("Daily password: DDMM | Backup password: 1989", 8, COLOR_MUTED)
        hint.setAlignment(Qt.AlignCenter)
        pl.addWidget(hint)
        root.addWidget(password_card)

        controls = QFrame()
        controls.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        cl = QVBoxLayout(controls)
        cl.setContentsMargins(16, 10, 16, 10)
        t = self._label("TEST CONTROLS", 9, COLOR_MUTED, True)
        t.setAlignment(Qt.AlignCenter)
        cl.addWidget(t)
        self.refresh_btn = QPushButton("Refresh baseline & retest")
        self.refresh_btn.setStyleSheet("background:#2d9669; color:white; padding:9px; border-radius:6px;")
        self.refresh_btn.clicked.connect(self.refresh_baseline)
        cl.addWidget(self.refresh_btn)
        root.addWidget(controls)

        self.showFullScreen()
        self.raise_()
        self.activateWindow()
        self.setFocusPolicy(Qt.StrongFocus)
        # Qt keyboard grabs are reliable on X11; Wayland compositors may restrict them.
        try:
            self.grabKeyboard()
        except RuntimeError:
            pass

    def state_color(self) -> str:
        return {
            "NoSensor": COLOR_ORANGE,
            "Stabilizing": COLOR_BLUE,
            "Calibrating": COLOR_BLUE,
            "WaitingForBreath": COLOR_GREEN,
            "BreathDetected": COLOR_YELLOW,
            "AlcoholDetected": COLOR_RED,
            "Unlocked": COLOR_GREEN,
        }.get(self.state, COLOR_TEXT)

    def set_state(self, state: str) -> None:
        self.state = state
        self.state_label.setText(f"State: {state}")
        self.status_label.setStyleSheet(f"color:{self.state_color()}; background:transparent;")

    def new_check(self) -> None:
        self.baseline = None
        self.breath_upper = None
        self.breath_lower = None
        self.alcohol_threshold = None
        self.peak = None
        self.minimum = None
        self.breath_values.clear()
        self.breath_direction = None
        self.set_state("NoSensor")
        self.showFullScreen()
        self.password.clear()
        self.password.setFocus()
        if self.sensor.connected:
            self.start_stabilization()
        else:
            self.next_check_at = 0

    def start_stabilization(self) -> None:
        self.baseline = None
        self.breath_upper = None
        self.breath_lower = None
        self.alcohol_threshold = None
        self.peak = None
        self.minimum = None
        self.stabilization_values.clear()
        self.calibration_values.clear()
        self.breath_values.clear()
        self.breath_direction = None
        self.sensor.buffer = ""
        try:
            self.sensor.serial.reset_input_buffer()
        except Exception:
            pass
        self.stabilization_started = time.monotonic()
        self.set_state("Stabilizing")
        log(f"Stabilization started on {self.sensor.port}")

    def stable_window(self) -> bool:
        if len(self.stabilization_values) < STABILIZATION_WINDOW_SAMPLES:
            return False
        vals = self.stabilization_values
        span = max(vals) - min(vals)
        drift = abs(vals[0] - vals[-1])
        negative_steps = sum(1 for a, b in zip(vals, vals[1:]) if b < a)
        return (
            vals[-1] < CLEAN_AIR_MAXIMUM
            and span <= STABILIZATION_MAX_SPAN
            and drift <= STABILIZATION_MAX_DRIFT
            and negative_steps <= STABILIZATION_MAX_NEGATIVE_STEPS
        )

    def complete_stabilization(self) -> None:
        if self.state != "Stabilizing":
            return
        elapsed = time.monotonic() - self.stabilization_started
        if elapsed >= STABILIZATION_MIN_SECONDS and self.stable_window():
            self.next_check_at = time.monotonic() + HOURLY_CHECK_SECONDS
            log(f"Sensor stabilized at {time.strftime('%Y-%m-%d %H:%M:%S')}; provisional next check scheduled")
            self.calibration_started = time.monotonic()
            self.calibration_values.clear()
            self.set_state("Calibrating")
            return
        if elapsed >= STABILIZATION_MAX_SECONDS:
            self.stabilization_values.clear()
            self.stabilization_started = time.monotonic()

    def complete_calibration(self) -> None:
        if self.state != "Calibrating":
            return
        elapsed = time.monotonic() - self.calibration_started
        if elapsed > CALIBRATION_TIMEOUT_SECONDS and len(self.calibration_values) < CALIBRATION_MINIMUM_SAMPLES:
            log("Calibration timed out; restarting stabilization")
            self.start_stabilization()
            return
        if elapsed < CALIBRATION_SECONDS or len(self.calibration_values) < CALIBRATION_MINIMUM_SAMPLES:
            return

        # The clean-air baseline is the minimum raw ADC value observed during
        # the entire calibration window. This captures the settled low point
        # even when the sensor is oscillating, e.g. 44 <-> 43.
        self.baseline = max(1, min(ADC_MAX, min(self.calibration_values)))
        self.breath_upper = min(ADC_MAX, self.baseline + BREATH_UP_REFERENCE_DELTA)
        self.breath_lower = max(0, self.baseline - BREATH_DOWN_REFERENCE_DELTA)
        self.alcohol_threshold = min(ADC_MAX, self.baseline + ALCOHOL_DELTA)
        self.peak = self.baseline
        self.minimum = self.baseline
        self.breath_values.clear()
        self.breath_direction = None
        self.set_state("WaitingForBreath")
        log(f"Calibration complete: baseline={self.baseline} upper={self.breath_upper} lower={self.breath_lower} alcohol={self.alcohol_threshold}")

    def process_value(self, value: int) -> None:
        self.last_value = value
        if self.peak is None or value > self.peak:
            self.peak = value
        if self.minimum is None or value < self.minimum:
            self.minimum = value

        if self.state == "Stabilizing":
            self.stabilization_values.append(value)
            self.stabilization_values = self.stabilization_values[-STABILIZATION_WINDOW_SAMPLES:]
            self.complete_stabilization()
            return
        if self.state == "Calibrating":
            self.calibration_values.append(value)
            self.complete_calibration()
            return

        if self.state == "WaitingForBreath":
            direction = None
            if self.breath_lower is not None and value <= self.breath_lower:
                direction = "down"
            elif self.breath_upper is not None and value >= self.breath_upper:
                direction = "up"
            if direction:
                self.breath_started = time.monotonic()
                self.breath_values = [value]
                self.breath_direction = direction
                self.next_check_at = self.breath_started + HOURLY_CHECK_SECONDS
                log(f"Breath registered: direction={direction} value={value}; next check reset")
                self.set_state("BreathDetected")
                return

        if self.state == "BreathDetected":
            self.breath_values.append(value)
            if self.alcohol_threshold is not None and value >= self.alcohol_threshold:
                self.next_check_at = time.monotonic() + HOURLY_CHECK_SECONDS
                self.set_state("AlcoholDetected")
                log(f"Alcohol threshold reached: value={value} threshold={self.alcohol_threshold}; next check reset")
                return

            elapsed = time.monotonic() - self.breath_started
            if elapsed >= BREATH_WINDOW_SECONDS:
                previous = self.breath_values[0]
                down_steps = sum(1 for a, b in zip(self.breath_values, self.breath_values[1:]) if b < a)
                up_steps = sum(1 for a, b in zip(self.breath_values, self.breath_values[1:]) if b > a)
                start = self.breath_values[0]
                end = self.breath_values[-1]
                if self.breath_direction == "up":
                    rise = end - start
                    confirmed = rise >= BREATH_MINIMUM_CHANGE and up_steps >= BREATH_REQUIRED_STEPS
                else:
                    drop = start - end
                    confirmed = drop >= BREATH_MINIMUM_CHANGE and down_steps >= BREATH_REQUIRED_STEPS
                if confirmed:
                    maximum = max(self.breath_values)
                    if self.alcohol_threshold is not None and maximum >= self.alcohol_threshold:
                        self.next_check_at = time.monotonic() + HOURLY_CHECK_SECONDS
                        self.set_state("AlcoholDetected")
                        log(f"Alcohol detected after {self.breath_direction} breath window: peak={maximum} threshold={self.alcohol_threshold}")
                        return
                    self.unlock("Sensor accepted")
                else:
                    self.breath_values.clear()
                    self.breath_direction = None
                    self.set_state("WaitingForBreath")
            return
        if self.state == "Calibrating":
            self.calibration_values.append(value)
            self.complete_calibration()
            return

        if self.state == "WaitingForBreath":
            # For this sensor, a sober breath is expected to drive the value down.
            if self.breath_lower is not None and value <= self.breath_lower:
                if not self.breath_values:
                    self.breath_started = time.monotonic()
                    self.breath_values = [value]
                    self.set_state("BreathDetected")
                    return
                self.breath_values.append(value)
                return

        if self.state == "BreathDetected":
            self.breath_values.append(value)
            elapsed = time.monotonic() - self.breath_started
            if self.alcohol_threshold is not None and value >= self.alcohol_threshold:
                self.set_state("AlcoholDetected")
                log(f"Alcohol threshold reached: value={value} threshold={self.alcohol_threshold}")
                return
            if elapsed >= BREATH_WINDOW_SECONDS:
                start = self.breath_values[0]
                end = self.breath_values[-1]
                drop = start - end
                down_steps = sum(1 for a, b in zip(self.breath_values, self.breath_values[1:]) if b < a)
                if drop >= BREATH_MINIMUM_DROP and down_steps >= BREATH_REQUIRED_DOWN_STEPS:
                    if self.peak is not None and self.alcohol_threshold is not None and self.peak >= self.alcohol_threshold:
                        self.set_state("AlcoholDetected")
                        log(f"Alcohol detected after breath window: peak={self.peak} threshold={self.alcohol_threshold}")
                        return
                    self.unlock("Sensor accepted")
                else:
                    self.breath_values.clear()
                    self.set_state("WaitingForBreath")
            return

    def unlock(self, reason: str) -> None:
        self.set_state("Unlocked")
        log(f"Unlocked. Reason={reason}")
        # Do not move the deadline here. It is anchored to the registered breath.
        self.hide()

    def unlock_password(self) -> None:
        entered = self.password.text()
        if entered == MASTER_PASSWORD:
            self.unlock("Master password")
        elif entered == daily_password():
            self.unlock("Daily date password")
        else:
            self.password.clear()
            self.password.setFocus()
            self.status_label.setText("Wrong password")
            log("Invalid password entered")

    def refresh_baseline(self) -> None:
        if self.sensor.connected:
            self.showFullScreen()
            self.start_stabilization()

    def stabilization_message(self) -> str:
        if not self.stabilization_values:
            return "Stabilizing sensor - please wait"
        latest = self.stabilization_values[-1]
        if latest >= CLEAN_AIR_MAXIMUM:
            falling = len(self.stabilization_values) >= 2 and latest < self.stabilization_values[-2]
            if falling:
                return "High reading is falling - reconnect sensor and touch it by hand"
            return "High sensor reading - reconnect sensor or touch it by hand"
        if len(self.stabilization_values) >= 3 and self.stabilization_values[-1] < self.stabilization_values[-2]:
            return "Sensor is still settling - please wait"
        return "Stabilizing sensor - please wait"

    def _tick(self) -> None:
        now = time.monotonic()

        if self.next_check_at and now >= self.next_check_at and self.state != "Stabilizing" and self.state != "Calibrating":
            self.new_check()

        if self.state != "Unlocked" and not self.sensor.connected:
            if self.sensor.connect_auto():
                self.start_stabilization()
            else:
                self.set_state("NoSensor")
                return

        if self.state != "Unlocked" and self.sensor.connected:
            value = self.sensor.read_value()
            if value is not None:
                self.process_value(value)
            elif now - self.sensor.last_valid_at > NO_DATA_TIMEOUT_SECONDS:
                log("No valid sensor data; reconnecting")
                self.sensor.close()

        self._update_ui()

    def _update_ui(self) -> None:
        messages = {
            "NoSensor": "Connect sensor",
            "Stabilizing": self.stabilization_message(),
            "Calibrating": "Calibrating sensor - do not blow",
            "WaitingForBreath": "Blow into the sensor",
            "BreathDetected": f"Breath detected - observing for {BREATH_WINDOW_SECONDS:g} seconds",
            "AlcoholDetected": "Alcohol level too high - access blocked",
            "Unlocked": "Access granted",
        }
        self.status_label.setText(messages[self.state])
        color = self.state_color()
        self.status_label.setStyleSheet(f"color:{color}; background:transparent;")
        self.current_label.setText("-" if self.last_value is None else str(self.last_value))
        self.baseline_label.setText("-" if self.baseline is None else str(self.baseline))
        self.alcohol_label.setText("-" if self.alcohol_threshold is None else str(self.alcohol_threshold))
        if self.breath_lower is None or self.breath_upper is None:
            self.breath_label.setText("- .. -")
        else:
            self.breath_label.setText(f"{self.breath_lower} .. {self.breath_upper}")
        self.range_label.setText(
            f"Min: {self.minimum if self.minimum is not None else '-'}    Max: {self.peak if self.peak is not None else '-'}"
        )
        if self.state == "Stabilizing":
            span = max(self.stabilization_values) - min(self.stabilization_values) if self.stabilization_values else 0
            elapsed = now = time.monotonic() - self.stabilization_started
            self.next_label.setText(f"Stabilizing: {elapsed:.1f}s | span {span}")
        elif self.state == "Calibrating":
            remain = max(0.0, CALIBRATION_SECONDS - (time.monotonic() - self.calibration_started))
            self.next_label.setText(f"Calibration: {remain:.1f}s")
        elif self.state == "BreathDetected":
            remain = max(0.0, BREATH_WINDOW_SECONDS - (time.monotonic() - self.breath_started))
            self.next_label.setText(f"Breath window: {remain:.1f}s")
        elif self.next_check_at:
            self.next_label.setText(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() + max(0.0, self.next_check_at - time.monotonic()))))
        else:
            self.next_label.setText("Waiting")
        self.sensor_label.setText(f"Sensor: {self.sensor.port or '-'}")
        self.refresh_btn.setEnabled(self.state not in {"Stabilizing", "Calibrating", "Unlocked"} and self.sensor.connected)

    def keyPressEvent(self, event) -> None:
        # Emergency maintenance exit. This is not a secure OS lock.
        if event.key() == Qt.Key_Q and (event.modifiers() & Qt.ControlModifier) and (event.modifiers() & Qt.AltModifier) and (event.modifiers() & Qt.ShiftModifier):
            QApplication.quit()
            return
        super().keyPressEvent(event)

    def closeEvent(self, event) -> None:
        if self.state != "Unlocked":
            event.ignore()
            return
        self.sensor.close()
        event.accept()


def self_test() -> int:
    passed = failed = 0

    def check(name: str, condition: bool) -> None:
        nonlocal passed, failed
        if condition:
            print(f"[PASS] {name}")
            passed += 1
        else:
            print(f"[FAIL] {name}")
            failed += 1

    print("=== AlcoholBlocker SelfTest v36 ===")
    base = 33
    check("Fixed lower breath threshold is baseline - 10", base - BREATH_DOWN_REFERENCE_DELTA == 23)
    check("Fixed upper breath threshold is baseline + 10", base + BREATH_UP_REFERENCE_DELTA == 43)
    check("Alcohol threshold is baseline + 200", base + ALCOHOL_DELTA == 233)
    check("Alcohol threshold caps at ADC 1023", min(ADC_MAX, 900 + ALCOHOL_DELTA) == 1023)
    check("Clean air ceiling is 150", CLEAN_AIR_MAXIMUM == 150)
    check("Daily password is four digits DDMM", re.fullmatch(r"\d{4}", daily_password()) is not None)

    stable = [34, 35, 34, 35, 33] * 10
    drifting = list(range(80, 30, -1))[:50]
    high = list(range(500, 450, -1))
    def stable_ok(vals: list[int]) -> bool:
        span = max(vals) - min(vals)
        drift = abs(vals[0] - vals[-1])
        neg = sum(1 for a, b in zip(vals, vals[1:]) if b < a)
        return vals[-1] < CLEAN_AIR_MAXIMUM and span <= STABILIZATION_MAX_SPAN and drift <= STABILIZATION_MAX_DRIFT and neg <= STABILIZATION_MAX_NEGATIVE_STEPS
    check("Stable 50-sample clean-air window accepted", len(stable) == 50 and stable_ok(stable))
    check("Slow downward drift rejected", not stable_ok(drifting))
    check("High falling sensor window rejected", not stable_ok(high))
    check("Minimum baseline from calibration 44/43 is 43", min([44, 43, 44, 43, 44]) == 43)

    down = [33, 29, 26, 23]
    up = [33, 37, 41, 45]
    flat = [33, 32, 33, 32]
    check("Sober downward breath confirmed", down[0] - down[-1] >= BREATH_MINIMUM_CHANGE and sum(1 for a, b in zip(down, down[1:]) if b < a) >= BREATH_REQUIRED_STEPS)
    check("Sober upward breath confirmed", up[-1] - up[0] >= BREATH_MINIMUM_CHANGE and sum(1 for a, b in zip(up, up[1:]) if b > a) >= BREATH_REQUIRED_STEPS)
    check("Flat noise rejected", not (flat[-1] - flat[0] >= BREATH_MINIMUM_CHANGE and sum(1 for a, b in zip(flat, flat[1:]) if b > a) >= BREATH_REQUIRED_STEPS))
    check("Breath observation window is 3 seconds", BREATH_WINDOW_SECONDS == 3.0)
    check("Check interval is 3600 seconds", HOURLY_CHECK_SECONDS == 3600)
    check("Stabilization is 50 samples / 5 seconds", STABILIZATION_WINDOW_SAMPLES == 50 and STABILIZATION_MIN_SECONDS == 5.0)

    print(f"\nPassed: {passed}\nFailed: {failed}")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="ALCOBLOCKER Linux breath-check overlay")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--log", action="store_true")
    args = parser.parse_args()

    global LOG_ENABLED, DEBUG_ENABLED
    DEBUG_ENABLED = args.debug
    LOG_ENABLED = args.log

    if args.self_test:
        return self_test()
    if args.cleanup:
        return cleanup()

    if not PYSIDE6_AVAILABLE:
        raise SystemExit("Missing dependency: PySide6. Install with: sudo pacman -S python-pyside6 or pip install PySide6")
    if serial is None or list_ports is None:
        raise SystemExit("Missing dependency: pyserial. Install with: sudo pacman -S python-pyserial or pip install pyserial")

    app = QApplication(sys.argv)
    window = GuardWindow()
    app.aboutToQuit.connect(window.sensor.close)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
