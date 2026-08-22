#!/usr/bin/env python3
# AlcoholBlocker - Linux version
# UI variant: ALCOBLOCKER UI2 - Large Status
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
UI_VARIANT = "ALCOBLOCKER UI2 - Large Status"
SERVICE_NAME = "alcoblocker-ui2"
MASTER_PASSWORD = "1989"
BAUD_RATE = 9600
HOURLY_CHECK_SECONDS = 600  # 10 minutes, matching the current Windows build
ADC_MAX = 1023
CLEAN_AIR_MAXIMUM = 150
ALCOHOL_DELTA = 200

BREATH_REFERENCE_BASELINE = 75.0
BREATH_UP_REFERENCE_DELTA = 10.0
BREATH_DOWN_REFERENCE_DELTA = 8.0
BREATH_ADAPTIVE_POWER = 1.0
BREATH_MINIMUM_DELTA = 4.0
BREATH_MAXIMUM_DELTA = 30.0

BREATH_WINDOW_SECONDS = 5.0
BREATH_REQUIRED_DOWN_STEPS = 2
BREATH_MINIMUM_DROP = 4
SAFE_RETURN_DELTA = 6
SAFE_READINGS_REQUIRED = 3

STABILIZATION_MIN_SECONDS = 4.0
STABILIZATION_MAX_SECONDS = 60.0
STABILIZATION_WINDOW_SAMPLES = 8
STABILIZATION_MAX_SPAN = 6
STABILIZATION_MAX_DRIFT = 3
STABILIZATION_MAX_NEGATIVE_STEPS = 3

CALIBRATION_SECONDS = 10.0
CALIBRATION_MINIMUM_SAMPLES = 8
CALIBRATION_TIMEOUT_SECONDS = 30.0

POLL_MS = 100
PORT_SCAN_MS = 2000
NO_DATA_TIMEOUT_SECONDS = 8

DATA_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "alcoblocker"
LOG_FILE = DATA_DIR / "alcoblocker.log"

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
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{os.getpid()}] {message}"
    with LOG_FILE.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    if os.environ.get("ALCOBLOCKER_DEBUG") == "1":
        print(line, flush=True)


def cleanup() -> int:
    """Remove the user service and own state/log files."""
    subprocess.run(
        ["systemctl", "--user", "disable", "--now", f"{SERVICE_NAME}.service"],
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
        self.safe_reads = 0

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
        root=QVBoxLayout(self); root.setContentsMargins(50,40,50,40); root.setSpacing(16); root.setAlignment(Qt.AlignCenter)
        head=self._label(APP_NAME,28,COLOR_RED,True); head.setAlignment(Qt.AlignCenter); root.addWidget(head); sub=self._label("BREATH CHECK SYSTEM",10,COLOR_MUTED,True); sub.setAlignment(Qt.AlignCenter); root.addWidget(sub)
        status=self._label("CONNECT SENSOR",25,COLOR_ORANGE,True); status.setAlignment(Qt.AlignCenter); status.setMinimumHeight(70); root.addWidget(status); self.status_label=status
        big=QFrame(); big.setStyleSheet(f"background:{COLOR_CARD};border-radius:18px;"); bl=QVBoxLayout(big); bl.setContentsMargins(35,28,35,28)
        self.current_label=self._label("-",72,COLOR_TEXT,True); self.current_label.setAlignment(Qt.AlignCenter); bl.addWidget(self.current_label); basecap=self._label("CURRENT READING / BASELINE",9,COLOR_MUTED,True); basecap.setAlignment(Qt.AlignCenter); bl.addWidget(basecap); root.addWidget(big)
        line=QHBoxLayout(); self.baseline_label=self._label("Baseline: -",13,COLOR_TEXT,True); self.alcohol_label=self._label("Alcohol: -",13,COLOR_RED,True); self.sensor_label=self._label("Sensor: -",11,COLOR_MUTED); self.state_label=self._label("State: NoSensor",11,COLOR_MUTED); line.addWidget(self.baseline_label); line.addStretch(); line.addWidget(self.alcohol_label); root.addLayout(line)
        status2=QFrame(); status2.setStyleSheet(f"background:{COLOR_CARD};border-radius:12px;"); s2=QVBoxLayout(status2); self.breath_label=self._label("Breath range: - .. -",14,COLOR_TEXT,True); self.breath_label.setAlignment(Qt.AlignCenter); s2.addWidget(self.breath_label); self.range_label=self._label("Min: -    Max: -",11,COLOR_MUTED); self.range_label.setAlignment(Qt.AlignCenter); s2.addWidget(self.range_label); self.next_label=self._label("Waiting",11,COLOR_MUTED); self.next_label.setAlignment(Qt.AlignCenter); s2.addWidget(self.next_label); root.addWidget(status2)
        passcard=QFrame(); passcard.setStyleSheet(f"background:{COLOR_CARD};border-radius:12px;"); pl=QVBoxLayout(passcard); cap=self._label("MASTER PASSWORD",9,COLOR_MUTED,True); cap.setAlignment(Qt.AlignCenter); pl.addWidget(cap); row=QHBoxLayout(); row.setAlignment(Qt.AlignCenter); self.password=QLineEdit(); self.password.setEchoMode(QLineEdit.Password); self.password.setAlignment(Qt.AlignCenter); self.password.setFixedWidth(220); self.password.setStyleSheet("background:#232a34;color:white;padding:8px;border-radius:6px;"); b=QPushButton("UNLOCK"); b.setFixedWidth(110); b.setStyleSheet(f"background:{COLOR_BLUE};color:white;padding:8px;border-radius:6px;"); b.clicked.connect(self.unlock_password); self.password.returnPressed.connect(self.unlock_password); row.addWidget(self.password); row.addSpacing(10); row.addWidget(b); pl.addLayout(row); root.addWidget(passcard)
        self.refresh_btn=QPushButton("REFRESH BASELINE & RETEST"); self.refresh_btn.setFixedWidth(330); self.refresh_btn.setStyleSheet(f"background:{COLOR_GREEN};color:white;padding:10px;border-radius:7px;"); self.refresh_btn.clicked.connect(self.refresh_baseline); root.addWidget(self.refresh_btn,0,Qt.AlignCenter)
        self.showFullScreen(); self.raise_(); self.activateWindow(); self.setFocusPolicy(Qt.StrongFocus)
        try: self.grabKeyboard()
        except RuntimeError: pass

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
        self.safe_reads = 0
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
        self.safe_reads = 0
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
            log(f"Sensor stabilized: {self.stabilization_values}")
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
        self.baseline = max(1, min(ADC_MAX, round(median(self.calibration_values))))
        up = BREATH_UP_REFERENCE_DELTA * (BREATH_REFERENCE_BASELINE / self.baseline) ** BREATH_ADAPTIVE_POWER
        down = BREATH_DOWN_REFERENCE_DELTA * (BREATH_REFERENCE_BASELINE / self.baseline) ** BREATH_ADAPTIVE_POWER
        up = max(BREATH_MINIMUM_DELTA, min(BREATH_MAXIMUM_DELTA, up))
        down = max(BREATH_MINIMUM_DELTA, min(BREATH_MAXIMUM_DELTA, down))
        self.breath_upper = min(ADC_MAX, round(self.baseline + up))
        self.breath_lower = max(0, round(self.baseline - down))
        self.alcohol_threshold = min(ADC_MAX, self.baseline + ALCOHOL_DELTA)
        self.peak = self.baseline
        self.minimum = self.baseline
        self.breath_values.clear()
        self.safe_reads = 0
        self.set_state("WaitingForBreath")
        log(
            f"Calibration complete: baseline={self.baseline} upper={self.breath_upper} "
            f"lower={self.breath_lower} alcohol={self.alcohol_threshold}"
        )

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
        self.next_check_at = time.monotonic() + HOURLY_CHECK_SECONDS
        self.hide()

    def unlock_password(self) -> None:
        if self.password.text() == MASTER_PASSWORD:
            self.unlock("Master password")
        else:
            self.password.clear()
            self.password.setFocus()
            self.status_label.setText("Wrong password")
            log("Invalid master password entered")

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

        if self.state == "Unlocked" and now >= self.next_check_at:
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
        messages={"NoSensor":"CONNECT SENSOR","Stabilizing":self.stabilization_message().upper(),"Calibrating":"CALIBRATING - DO NOT BLOW","WaitingForBreath":"BLOW INTO THE SENSOR","BreathDetected":"OBSERVING BREATH - 5 SEC","AlcoholDetected":"ALCOHOL TOO HIGH - ACCESS BLOCKED","Unlocked":"ACCESS GRANTED"}
        self.status_label.setText(messages[self.state]); self.status_label.setStyleSheet(f"color:{self.state_color()};background:transparent;")
        self.current_label.setText("-" if self.last_value is None else str(self.last_value)); self.baseline_label.setText(f"Baseline: {self.baseline if self.baseline is not None else '-'}"); self.alcohol_label.setText(f"Alcohol: {self.alcohol_threshold if self.alcohol_threshold is not None else '-'}"); self.breath_label.setText(f"Breath range: {self.breath_lower} .. {self.breath_upper}" if self.breath_lower is not None and self.breath_upper is not None else "Breath range: - .. -"); self.range_label.setText(f"Min: {self.minimum if self.minimum is not None else '-'}    Max: {self.peak if self.peak is not None else '-'}"); self.sensor_label.setText(f"Sensor: {self.sensor.port or '-'}"); self.state_label.setText(f"State: {self.state}")
        if self.state=="Stabilizing": self.next_label.setText(f"Stabilizing {time.monotonic()-self.stabilization_started:.1f}s")
        elif self.state=="Calibrating": self.next_label.setText(f"Calibration {max(0,CALIBRATION_SECONDS-(time.monotonic()-self.calibration_started)):.1f}s")
        elif self.state=="BreathDetected": self.next_label.setText(f"Breath window {max(0,BREATH_WINDOW_SECONDS-(time.monotonic()-self.breath_started)):.1f}s")
        elif self.state=="Unlocked" and self.next_check_at: self.next_label.setText(f"Next check {max(0,int(self.next_check_at-time.monotonic()))}s")
        else: self.next_label.setText("Waiting")
        self.refresh_btn.setEnabled(self.state not in {"Stabilizing","Calibrating","Unlocked"} and self.sensor.connected)

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

    print("=== AlcoholBlocker SelfTest ===")
    base = 75
    up = max(BREATH_MINIMUM_DELTA, min(BREATH_MAXIMUM_DELTA, BREATH_UP_REFERENCE_DELTA * (BREATH_REFERENCE_BASELINE / base) ** BREATH_ADAPTIVE_POWER))
    down = max(BREATH_MINIMUM_DELTA, min(BREATH_MAXIMUM_DELTA, BREATH_DOWN_REFERENCE_DELTA * (BREATH_REFERENCE_BASELINE / base) ** BREATH_ADAPTIVE_POWER))
    check("Breath lower threshold", base - down < base)
    check("Breath upper threshold", base + up > base)
    check("Alcohol threshold is baseline + 200", base + ALCOHOL_DELTA == 275)
    check("Alcohol threshold caps at ADC 1023", min(ADC_MAX, 900 + ALCOHOL_DELTA) == 1023)
    check("Clean air ceiling is 150", CLEAN_AIR_MAXIMUM == 150)

    stable = [45, 44, 45, 46, 45, 44, 45, 45]
    drifting = [100, 96, 92, 88, 84, 80, 76, 72]
    high = [500, 480, 460, 440, 420, 400, 380, 360]
    def stable_ok(vals: list[int]) -> bool:
        span = max(vals) - min(vals)
        drift = abs(vals[0] - vals[-1])
        neg = sum(1 for a, b in zip(vals, vals[1:]) if b < a)
        return vals[-1] < CLEAN_AIR_MAXIMUM and span <= STABILIZATION_MAX_SPAN and drift <= STABILIZATION_MAX_DRIFT and neg <= STABILIZATION_MAX_NEGATIVE_STEPS
    check("Stable clean-air window accepted", stable_ok(stable))
    check("Slow downward drift rejected", not stable_ok(drifting))
    check("High falling sensor window rejected", not stable_ok(high))

    breath = [75, 71, 68, 66, 64, 63]
    not_breath = [75, 74, 75, 74, 75, 74]
    check("Sober downward breath confirmed", breath[0] - breath[-1] >= BREATH_MINIMUM_DROP and sum(1 for a, b in zip(breath, breath[1:]) if b < a) >= BREATH_REQUIRED_DOWN_STEPS)
    check("Flat noise rejected", not (not_breath[0] - not_breath[-1] >= BREATH_MINIMUM_DROP and sum(1 for a, b in zip(not_breath, not_breath[1:]) if b < a) >= BREATH_REQUIRED_DOWN_STEPS))

    print(f"\nPassed: {passed}\nFailed: {failed}")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="ALCOBLOCKER Linux breath-check overlay")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.cleanup:
        return cleanup()

    if args.debug:
        os.environ["ALCOBLOCKER_DEBUG"] = "1"

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
