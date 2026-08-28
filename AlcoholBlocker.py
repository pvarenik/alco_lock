#!/usr/bin/env python3
# ALCOBLOCKER - Linux implementation
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
import os
import re
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
        QGridLayout,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QPushButton,
        QVBoxLayout,
        QWidget,
    )
    PYSIDE6_AVAILABLE = True
except ImportError:
    PYSIDE6_AVAILABLE = False
    QApplication = QFrame = QGridLayout = QHBoxLayout = QLabel = QLineEdit = QPushButton = QVBoxLayout = QWidget = None
    QFont = Qt = QTimer = None
    QWidget = object

APP_NAME = "ALCOBLOCKER"
MASTER_PASSWORD = "1989"
CLEANUP_PASSWORD = "cleanup"
BAUD_RATE = 9600
ADC_MAX = 1023
CLEAN_AIR_MAXIMUM = 150
ALCOHOL_DELTA = 200

BREATH_UP_REFERENCE_DELTA = 10
BREATH_DOWN_REFERENCE_DELTA = 10
BREATH_OBSERVATION_SECONDS = 3.0
BREATH_TREND_MINIMUM_DELTA = 3
BREATH_TREND_MINIMUM_STEPS = 2
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

HOURLY_CHECK_SECONDS = 3600
POLL_MS = 100
PORT_SCAN_MS = 2000
NO_DATA_TIMEOUT_SECONDS = 8

STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "alcoblocker"
LOG_FILE = STATE_DIR / "alcoblocker.log"

# Runtime logging is deliberately disabled until --log / ALCOBLOCKER_LOG=1 is enabled.
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


def write_log(message: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{os.getpid()}] {message}"
    if LOG_ENABLED:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    if DEBUG_ENABLED:
        print(line, flush=True)


def cleanup(stop_service: bool = True) -> int:
    command = ["systemctl", "--user", "disable"]
    if stop_service:
        command.append("--now")
    command.append("alcoblocker.service")
    subprocess.run(
        command,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if LOG_FILE.exists():
        LOG_FILE.unlink(missing_ok=True)
    try:
        STATE_DIR.rmdir()
    except OSError:
        pass
    print("AlcoholBlocker cleanup complete.")
    return 0


def numeric_line(text: str) -> Optional[int]:
    text = text.strip()
    if not re.fullmatch(r"\d+", text):
        return None
    value = int(text)
    return value if 0 <= value <= ADC_MAX else None


def daily_password() -> str:
    return time.strftime("%d%m")


@dataclass
class PortCandidate:
    device: str
    score: int
    description: str


class Sensor:
    NAME_HINTS = {
        "ch340": 90,
        "ch341": 85,
        "arduino": 70,
        "usb-serial": 65,
        "usb serial": 65,
        "ftdi": 55,
        "cp210": 50,
        "silicon labs": 50,
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
            except Exception:
                pass
        self.serial = None
        self.port = None
        self.buffer = ""

    def candidates(self) -> list[PortCandidate]:
        result: list[PortCandidate] = []
        if list_ports is None:
            return result
        for p in list_ports.comports():
            text = " ".join(
                [p.device or "", p.description or "", p.manufacturer or "", p.product or "", p.hwid or ""]
            ).lower()
            score = 0
            for hint, points in self.NAME_HINTS.items():
                if hint in text:
                    score += points
            if "bluetooth" in text:
                score -= 100
            result.append(PortCandidate(p.device, score, p.description or p.device))
        return sorted(result, key=lambda x: (x.score, x.device), reverse=True)

    def connect_auto(self) -> bool:
        if self.connected:
            return True
        if serial is None:
            return False
        for candidate in self.candidates():
            write_log(f"Probing {candidate.device} | {candidate.description} | score={candidate.score}")
            try:
                ser = serial.Serial(
                    candidate.device,
                    BAUD_RATE,
                    timeout=0.2,
                    write_timeout=0.2,
                    dsrdtr=True,
                    rtscts=False,
                )
                time.sleep(1.8)
                ser.reset_input_buffer()
                deadline = time.monotonic() + 3.0
                detected = False
                while time.monotonic() < deadline:
                    raw = ser.readline()
                    value = numeric_line(raw.decode(errors="ignore")) if raw else None
                    if value is not None:
                        detected = True
                        write_log(f"Arduino detected on {candidate.device} with value {value}")
                        break
                if detected:
                    self.serial = ser
                    self.port = candidate.device
                    self.last_valid_at = time.monotonic()
                    return True
                ser.close()
            except Exception as exc:
                write_log(f"Failed to open/read {candidate.device}: {exc}")
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
                parsed = numeric_line(line)
                if parsed is not None:
                    latest = parsed
            if latest is not None:
                self.last_valid_at = time.monotonic()
            return latest
        except Exception as exc:
            write_log(f"Serial read error: {exc}")
            return None


class GuardWindow(QWidget):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.setWindowFlag(Qt.FramelessWindowHint)
        self.setWindowFlag(Qt.WindowStaysOnTopHint, True)
        self.setWindowFlag(Qt.Tool, True)
        self.setStyleSheet(f"background:{COLOR_BG}; color:{COLOR_TEXT};")
        self.setFocusPolicy(Qt.StrongFocus)
        self.setWindowState(self.windowState() | Qt.WindowFullScreen)

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
        self.breath_direction: Optional[str] = None
        self.breath_values: list[int] = []
        self.safe_reads = 0
        self.help_index = -1
        self.help_messages = self._help_messages()

        self._build_ui()
        self.timer = QTimer(self)
        self.timer.timeout.connect(self._tick)
        self.timer.start(POLL_MS)
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
        root.setContentsMargins(36, 28, 36, 28)
        root.setSpacing(12)

        header = QFrame()
        header.setStyleSheet(f"background:{COLOR_HEADER}; border-radius:10px;")
        h = QVBoxLayout(header)
        h.setContentsMargins(20, 12, 20, 12)
        h.addWidget(self._label(APP_NAME, 25, COLOR_RED, True))
        h.addWidget(self._label("Linux breath-check system", 10, COLOR_MUTED))
        root.addWidget(header)

        status = QFrame()
        status.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        sl = QVBoxLayout(status)
        sl.setContentsMargins(18, 12, 18, 12)
        self.status_label = self._label("Connect sensor", 25, COLOR_ORANGE, True)
        self.status_label.setAlignment(Qt.AlignCenter)
        sl.addWidget(self.status_label)
        meta = QHBoxLayout()
        self.state_label = self._label("State: NoSensor", 9, COLOR_MUTED)
        self.sensor_label = self._label("Sensor: -", 9, COLOR_MUTED)
        meta.addWidget(self.state_label)
        meta.addStretch()
        meta.addWidget(self.sensor_label)
        sl.addLayout(meta)
        root.addWidget(status)

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
        self.next_label = self._label("Waiting", 11, COLOR_TEXT, True)
        info.addWidget(self._card("OBSERVED RANGE", self.range_label))
        info.addWidget(self._card("NEXT CHECK / ACTIVITY", self.next_label))
        root.addLayout(info)

        password = QFrame()
        password.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        pl = QVBoxLayout(password)
        pl.setContentsMargins(16, 10, 16, 10)
        title = self._label("PASSWORD", 9, COLOR_MUTED, True)
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
        self.hint_label = self._label("Press ? for help", 9, COLOR_MUTED)
        self.hint_label.setAlignment(Qt.AlignCenter)
        pl.addWidget(self.hint_label)
        root.addWidget(password)

        controls = QFrame()
        controls.setStyleSheet(f"background:{COLOR_CARD}; border-radius:10px;")
        cl = QVBoxLayout(controls)
        cl.setContentsMargins(16, 10, 16, 10)
        cl.addWidget(self._label("TEST CONTROLS", 9, COLOR_MUTED, True), alignment=Qt.AlignCenter)
        self.refresh_btn = QPushButton("Refresh baseline & retest")
        self.refresh_btn.setStyleSheet("background:#2d9669; color:white; padding:9px; border-radius:6px;")
        self.refresh_btn.clicked.connect(self.refresh_baseline)
        cl.addWidget(self.refresh_btn)
        root.addWidget(controls)

        self.showFullScreen()
        self.raise_()
        self.activateWindow()
        try:
            self.grabKeyboard()
        except Exception:
            pass

    def _help_messages(self) -> list[str]:
        return [
            "Wait for the sensor to settle before calibration.",
            "Do not blow during stabilization or the calibration period.",
            "Baseline is the minimum sensor value observed during the 10-second calibration.",
            "A slowly falling sensor value is treated as sensor settling, not as a breath.",
            "If the reading is unusually high and falling, reconnect the sensor or touch it by hand.",
            "The breath range is baseline +/- 10 raw ADC counts for the current MQ-3 setup.",
            "One out-of-range reading starts a short breath observation; the trend must still be confirmed.",
            "A strong response at baseline + 200 keeps access blocked.",
            "Refresh baseline & retest starts a fresh stabilization, calibration, and breath test.",
            "Next check is one hour after the relevant completed event; the final two hints describe the passwords.",
            "Daily password: current local day and month in DDMM format. Example: August 1 -> 0108.",
            "Backup password: 1989. It always works.",
        ]

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

    def schedule_next_check(self, base: Optional[float] = None) -> None:
        base = time.monotonic() if base is None else base
        self.next_check_at = base + HOURLY_CHECK_SECONDS
        local = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() + HOURLY_CHECK_SECONDS))
        write_log(f"Next hourly check at {local}")

    def clear_algorithm(self) -> None:
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
        self.safe_reads = 0

    def new_check(self) -> None:
        self.clear_algorithm()
        self.next_check_at = 0.0
        self.set_state("NoSensor")
        self.showFullScreen()
        self.password.clear()
        self.password.setFocus()
        if self.sensor.connected:
            self.start_stabilization()

    def start_stabilization(self) -> None:
        self.clear_algorithm()
        self.sensor.buffer = ""
        try:
            self.sensor.serial.reset_input_buffer()
        except Exception:
            pass
        self.stabilization_started = time.monotonic()
        self.set_state("Stabilizing")
        write_log(f"Stabilization started on {self.sensor.port}")

    def stable_window(self) -> bool:
        if len(self.stabilization_values) < STABILIZATION_WINDOW_SAMPLES:
            return False
        values = self.stabilization_values[-STABILIZATION_WINDOW_SAMPLES:]
        span = max(values) - min(values)
        drift = abs(values[0] - values[-1])
        negative_steps = sum(1 for a, b in zip(values, values[1:]) if b < a)
        return (
            span <= STABILIZATION_MAX_SPAN
            and drift <= STABILIZATION_MAX_DRIFT
            and negative_steps <= STABILIZATION_MAX_NEGATIVE_STEPS
            and values[-1] < CLEAN_AIR_MAXIMUM
        )

    def complete_stabilization(self) -> None:
        if not self.stabilization_values:
            return
        elapsed = time.monotonic() - self.stabilization_started
        if elapsed >= STABILIZATION_MIN_SECONDS and self.stable_window():
            self.calibration_started = time.monotonic()
            self.calibration_values.clear()
            self.set_state("Calibrating")
            write_log("Sensor stabilization accepted; calibration started")
        elif elapsed >= STABILIZATION_MAX_SECONDS:
            write_log("Stabilization timed out; restarting")
            self.start_stabilization()

    def complete_calibration(self) -> None:
        if not self.calibration_values:
            return
        elapsed = time.monotonic() - self.calibration_started
        if elapsed < CALIBRATION_SECONDS and len(self.calibration_values) < CALIBRATION_MINIMUM_SAMPLES:
            return
        if elapsed < CALIBRATION_SECONDS:
            return
        if len(self.calibration_values) < CALIBRATION_MINIMUM_SAMPLES:
            return
        baseline = max(1, min(ADC_MAX, min(self.calibration_values)))
        self.baseline = baseline
        self.breath_upper = min(ADC_MAX, baseline + BREATH_UP_REFERENCE_DELTA)
        self.breath_lower = max(0, baseline - BREATH_DOWN_REFERENCE_DELTA)
        self.alcohol_threshold = min(ADC_MAX, baseline + ALCOHOL_DELTA)
        self.peak = baseline
        self.minimum = baseline
        self.breath_values.clear()
        self.set_state("WaitingForBreath")
        # The first deadline is anchored to the end of stabilization/calibration cycle.
        self.schedule_next_check()
        write_log(
            f"Calibration complete: baseline={baseline} lower={self.breath_lower} "
            f"upper={self.breath_upper} alcoholThreshold={self.alcohol_threshold} "
            f"samples={len(self.calibration_values)}"
        )

    def start_breath(self, value: int, direction: str) -> None:
        self.breath_started = time.monotonic()
        self.breath_direction = direction
        self.breath_values = [value]
        self.set_state("BreathDetected")
        breath_time = time.monotonic()
        self.schedule_next_check(breath_time)
        write_log(f"Breath registered at value={value} direction={direction}")

    def finish_breath(self) -> None:
        if self.breath_direction not in {"up", "down"} or len(self.breath_values) < 2:
            self.breath_values.clear()
            self.set_state("WaitingForBreath")
            return
        start = self.breath_values[0]
        end = self.breath_values[-1]
        rise = end - start
        drop = start - end
        positive_steps = sum(1 for a, b in zip(self.breath_values, self.breath_values[1:]) if b > a)
        negative_steps = sum(1 for a, b in zip(self.breath_values, self.breath_values[1:]) if b < a)
        if self.breath_direction == "up":
            confirmed = rise >= BREATH_TREND_MINIMUM_DELTA and positive_steps >= BREATH_TREND_MINIMUM_STEPS
        else:
            confirmed = drop >= BREATH_TREND_MINIMUM_DELTA and negative_steps >= BREATH_TREND_MINIMUM_STEPS
        if not confirmed:
            write_log(f"Breath observation rejected: direction={self.breath_direction} rise={rise} drop={drop}")
            self.breath_values.clear()
            self.breath_direction = None
            self.set_state("WaitingForBreath")
            return
        if self.peak is not None and self.alcohol_threshold is not None and self.peak >= self.alcohol_threshold:
            self.set_state("AlcoholDetected")
            self.schedule_next_check()
            write_log(f"Alcohol detected: peak={self.peak} threshold={self.alcohol_threshold}")
            self.breath_values.clear()
            return
        write_log(f"Sober {self.breath_direction} breath confirmed")
        self.unlock("Sensor accepted")

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
            if self.breath_upper is not None and value >= self.breath_upper:
                self.start_breath(value, "up")
            elif self.breath_lower is not None and value <= self.breath_lower:
                self.start_breath(value, "down")
            return

        if self.state == "BreathDetected":
            self.breath_values.append(value)
            if self.alcohol_threshold is not None and value >= self.alcohol_threshold:
                self.set_state("AlcoholDetected")
                self.schedule_next_check()
                write_log(f"Alcohol threshold reached immediately: value={value} threshold={self.alcohol_threshold}")
                self.breath_values.clear()
                return
            if time.monotonic() - self.breath_started >= BREATH_OBSERVATION_SECONDS:
                self.finish_breath()

    def unlock(self, reason: str) -> None:
        self.set_state("Unlocked")
        self.schedule_next_check()
        write_log(f"Unlocked. Reason={reason}; next check refreshed")
        self.hide()

    def unlock_password(self) -> None:
        entered = self.password.text().strip()
        if entered == CLEANUP_PASSWORD:
            self.password.clear()
            write_log("Cleanup password accepted; removing service and state")
            cleanup(stop_service=False)
            QApplication.quit()
            return
        if entered == MASTER_PASSWORD:
            self.unlock("Master password")
            return
        if entered == daily_password():
            self.unlock("Daily password")
            return
        self.password.clear()
        self.password.setFocus()
        self.status_label.setText("Wrong password")
        write_log("Invalid password entered")

    def refresh_baseline(self) -> None:
        if self.sensor.connected and self.state != "Unlocked":
            self.showFullScreen()
            self.start_stabilization()
            write_log("Manual baseline refresh requested")
        elif not self.sensor.connected:
            self.set_state("NoSensor")

    def stabilization_message(self) -> str:
        if not self.stabilization_values:
            return "Stabilizing sensor - please wait"
        latest = self.stabilization_values[-1]
        falling = len(self.stabilization_values) >= 2 and latest < self.stabilization_values[-2]
        if latest >= CLEAN_AIR_MAXIMUM:
            return (
                "Sensor reading is high and falling - reconnect sensor and touch it by hand"
                if falling else
                "Sensor reading is high - reconnect sensor or touch it by hand"
            )
        if falling:
            return "Sensor is still settling - please wait"
        return "Stabilizing sensor - please wait"

    def show_next_help(self) -> None:
        self.help_index = (self.help_index + 1) % len(self.help_messages)
        self.hint_label.setText(self.help_messages[self.help_index])
        write_log(f"Help hint shown: {self.help_index + 1}/{len(self.help_messages)}")

    def _tick(self) -> None:
        now = time.monotonic()

        if self.state == "Unlocked" and self.next_check_at and now >= self.next_check_at:
            self.new_check()

        if self.state != "Unlocked" and not self.sensor.connected:
            if self.sensor.connect_auto():
                self.start_stabilization()
            else:
                self.set_state("NoSensor")
                self._update_ui()
                return

        if self.state != "Unlocked" and self.sensor.connected:
            value = self.sensor.read_value()
            if value is not None:
                self.process_value(value)
            elif now - self.sensor.last_valid_at > NO_DATA_TIMEOUT_SECONDS:
                write_log("No valid sensor data; reconnecting")
                self.sensor.close()

        self._update_ui()

    def _update_ui(self) -> None:
        messages = {
            "NoSensor": "Connect sensor",
            "Stabilizing": self.stabilization_message(),
            "Calibrating": "Calibrating sensor - do not blow",
            "WaitingForBreath": "Blow into the sensor",
            "BreathDetected": f"Breath detected - observing for {int(BREATH_OBSERVATION_SECONDS)} seconds",
            "AlcoholDetected": "Alcohol level too high - access blocked",
            "Unlocked": "Access granted",
        }
        self.status_label.setText(messages[self.state])
        self.status_label.setStyleSheet(f"color:{self.state_color()}; background:transparent;")
        self.state_label.setText(f"State: {self.state}")
        self.sensor_label.setText(f"Sensor: {self.sensor.port or '-'}")
        self.current_label.setText("-" if self.last_value is None else str(self.last_value))
        self.baseline_label.setText("-" if self.baseline is None else str(self.baseline))
        self.alcohol_label.setText("-" if self.alcohol_threshold is None else str(self.alcohol_threshold))
        self.breath_label.setText(
            "- .. -" if self.breath_lower is None or self.breath_upper is None
            else f"{self.breath_lower} .. {self.breath_upper}"
        )
        self.range_label.setText(
            f"Min: {self.minimum if self.minimum is not None else '-'}    "
            f"Max: {self.peak if self.peak is not None else '-'}"
        )

        if self.state == "Stabilizing":
            span = max(self.stabilization_values) - min(self.stabilization_values) if self.stabilization_values else 0
            elapsed = time.monotonic() - self.stabilization_started
            self.next_label.setText(f"Stabilizing: {elapsed:.1f}s | span {span}")
        elif self.state == "Calibrating":
            remain = max(0.0, CALIBRATION_SECONDS - (time.monotonic() - self.calibration_started))
            self.next_label.setText(f"Calibration: {remain:.1f}s")
        elif self.state == "BreathDetected":
            remain = max(0.0, BREATH_OBSERVATION_SECONDS - (time.monotonic() - self.breath_started))
            self.next_label.setText(f"Breath window: {remain:.1f}s")
        elif self.next_check_at:
            remain = max(0, int(self.next_check_at - time.monotonic()))
            self.next_label.setText(f"Next check in {remain}s")
        else:
            self.next_label.setText("Waiting")

        self.refresh_btn.setEnabled(self.state not in {"Stabilizing", "Calibrating", "Unlocked"} and self.sensor.connected)

    def keyPressEvent(self, event) -> None:
        # Help shortcut only. No emergency/exit hotkey is implemented.
        if event.key() in {Qt.Key_Question, Qt.Key_Slash, Qt.Key_7} and (event.modifiers() & Qt.ShiftModifier):
            self.show_next_help()
            event.accept()
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

    print("=== AlcoholBlocker SelfTest ===")
    base = 75
    check("Fixed breath lower delta is 10", BREATH_DOWN_REFERENCE_DELTA == 10)
    check("Fixed breath upper delta is 10", BREATH_UP_REFERENCE_DELTA == 10)
    check("Breath lower threshold is below baseline", base - BREATH_DOWN_REFERENCE_DELTA < base)
    check("Breath upper threshold is above baseline", base + BREATH_UP_REFERENCE_DELTA > base)
    check("Baseline 75 alcohol threshold is 275", base + ALCOHOL_DELTA == 275)
    check("Alcohol threshold caps at ADC 1023", min(ADC_MAX, 900 + ALCOHOL_DELTA) == 1023)
    check("Clean air ceiling is 150", CLEAN_AIR_MAXIMUM == 150)
    check("Stabilization minimum is 5 seconds", STABILIZATION_MIN_SECONDS == 5)
    check("Stabilization window is 50 samples", STABILIZATION_WINDOW_SAMPLES == 50)
    check("Calibration is 10 seconds", CALIBRATION_SECONDS == 10)
    check("Hourly interval is 3600 seconds", HOURLY_CHECK_SECONDS == 3600)
    check("Breath observation is 3 seconds", BREATH_OBSERVATION_SECONDS == 3)
    check("Alcohol delta is 200", ALCOHOL_DELTA == 200)

    stable = ([44] * 20) + ([43, 44] * 15)
    drifting = list(range(100, 50, -1))[:50]
    high_falling = list(range(500, 450, -1))

    def stable_ok(vals: list[int]) -> bool:
        if len(vals) < STABILIZATION_WINDOW_SAMPLES:
            return False
        window = vals[-STABILIZATION_WINDOW_SAMPLES:]
        span = max(window) - min(window)
        drift = abs(window[0] - window[-1])
        negative_steps = sum(1 for a, b in zip(window, window[1:]) if b < a)
        return (
            span <= STABILIZATION_MAX_SPAN
            and drift <= STABILIZATION_MAX_DRIFT
            and negative_steps <= STABILIZATION_MAX_NEGATIVE_STEPS
            and window[-1] < CLEAN_AIR_MAXIMUM
        )

    check("Stable 34-44-ish window accepted", stable_ok(stable))
    check("Slow downward drift rejected", not stable_ok(drifting))
    check("High falling readings rejected", not stable_ok(high_falling))

    down = [33, 30, 28, 27]
    up = [33, 36, 38, 39]
    noise = [33, 34, 33, 34, 33, 34]
    check("Downward breath trend confirmed", (down[0] - down[-1] >= BREATH_TREND_MINIMUM_DELTA) and sum(1 for a, b in zip(down, down[1:]) if b < a) >= BREATH_TREND_MINIMUM_STEPS)
    check("Upward breath trend confirmed", (up[-1] - up[0] >= BREATH_TREND_MINIMUM_DELTA) and sum(1 for a, b in zip(up, up[1:]) if b > a) >= BREATH_TREND_MINIMUM_STEPS)
    check("Flat/noisy readings rejected", not ((noise[-1] - noise[0] >= BREATH_TREND_MINIMUM_DELTA and sum(1 for a, b in zip(noise, noise[1:]) if b > a) >= BREATH_TREND_MINIMUM_STEPS) or (noise[0] - noise[-1] >= BREATH_TREND_MINIMUM_DELTA and sum(1 for a, b in zip(noise, noise[1:]) if b < a) >= BREATH_TREND_MINIMUM_STEPS)))
    check("Daily password format is four digits", daily_password().isdigit() and len(daily_password()) == 4)
    check("Master password remains 1989", MASTER_PASSWORD == "1989")
    check("Cleanup password is cleanup", CLEANUP_PASSWORD == "cleanup")
    check("Automatic PnP hints include CH340", "ch340" in Sensor.NAME_HINTS)
    check("Emergency hotkey is not implemented", "EmergencyExit" not in globals())

    print(f"\nPassed: {passed}\nFailed: {failed}")
    return 1 if failed else 0


def main() -> int:
    global LOG_ENABLED, DEBUG_ENABLED
    parser = argparse.ArgumentParser(description="ALCOBLOCKER Linux breath-check overlay")
    parser.add_argument("--self-test", action="store_true", help="run built-in tests")
    parser.add_argument("--cleanup", action="store_true", help="disable service and remove application-owned log/state")
    parser.add_argument("--debug", action="store_true", help="print diagnostic messages")
    parser.add_argument("--log", action="store_true", help="write a persistent log file")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.cleanup:
        return cleanup()

    DEBUG_ENABLED = args.debug
    LOG_ENABLED = args.log

    if not PYSIDE6_AVAILABLE:
        raise SystemExit("Missing dependency: PySide6")
    if serial is None or list_ports is None:
        raise SystemExit("Missing dependency: pyserial")

    app = QApplication(sys.argv)
    window = GuardWindow()
    app.aboutToQuit.connect(window.sensor.close)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
