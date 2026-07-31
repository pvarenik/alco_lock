#!/usr/bin/env python3
"""
AlcoLock (Linux) - breathalyzer-gated screen lock.

Reads sensor readings from a serial port (Arduino/MQ-3), calibrates a
clean-air baseline on startup, and locks the session whenever the reading
exceeds the configured threshold. Access is restored only after a genuine
fresh breath (detected as a sharp impulse, not just a slowly-clearing
residual reading) stays within the sober range for several consecutive
seconds.

Modes:
  Normal - locks once immediately, verifies sobriety, then exits (meant to
           be re-triggered hourly via a systemd timer).
  Quiet  - stays running in the background, silently monitoring the sensor,
           and only locks when the threshold is actually exceeded.

Examples:
  alco_lock.py
      Runs in Normal mode with an autodetected port.

  alco_lock.py --mode Quiet
      Runs continuously in the background (installed at login via systemd).

  alco_lock.py --mode Quiet --debug
      Safe dry run: background monitoring with fake locking (logs only).

  alco_lock.py --mode Quiet --port /dev/ttyACM0
      Forces a specific serial device instead of autodetecting.

  alco_lock.py --cleanup
      Prompts for the master password and, if correct, removes the
      systemd unit(s) and installed files.

Requires: pyserial (pip install pyserial --break-system-packages)
"""

import argparse
import datetime
import getpass
import glob
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print(
        "Missing dependency: pyserial. Install it with:\n"
        "  pip install pyserial --break-system-packages",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    import tkinter as tk
    TKINTER_AVAILABLE = True
except ImportError:
    TKINTER_AVAILABLE = False

# ================= SETTINGS =================
PORT_RETRY_ATTEMPTS = 6      # Port detection attempts at startup
PORT_RETRY_DELAY_SEC = 2

BAUD_RATE = 9600
THRESHOLD = 350               # Alcohol trigger threshold
MASTER_PASSWORD = "SuperSecret123"  # HARDCODED MASTER PASSWORD - change before real use
SERVICE_NAME = "alcolock"     # systemd --user unit name
SOBER_TIME = 5                # Seconds of continuous sober breath required
WARMUP_SEC = 10               # Seconds of clean-air calibration at startup

INSTALL_DIR = Path.home() / ".local" / "share" / "alcolock"
SYSTEMD_USER_DIR = Path.home() / ".config" / "systemd" / "user"
# =============================================

COLORS = {
    "Red": "\033[91m",
    "Green": "\033[92m",
    "Yellow": "\033[93m",
    "Cyan": "\033[96m",
    "Magenta": "\033[95m",
    "White": "\033[97m",
    "Gray": "\033[37m",
    "DarkGray": "\033[90m",
}
RESET = "\033[0m"

# Set from CLI args at startup; used by log() for the "[Mode-Mode]" tag.
CURRENT_MODE = "Normal"

# Persistent log file, so the whole process is reviewable afterward even
# when running invisibly in Quiet mode (as a systemd --user service).
LOG_FILE_PATH = INSTALL_DIR / "alcolock.log"


def log(message, color="Gray"):
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    c = COLORS.get(color, "")
    print(f"{c}[{ts}] [{CURRENT_MODE}-Mode] {message}{RESET}")

    try:
        LOG_FILE_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE_PATH, "a", encoding="utf-8") as f:
            f.write(f"[{ts}] [{CURRENT_MODE}-Mode] {message}\n")
    except Exception:
        pass


# --- SERIAL PORT AUTODETECTION ---
def find_serial_port(override=""):
    if override:
        log(f"Port manually set via --port: {override}", "Cyan")
        return override

    # 1) Try to identify the device by its USB description (real Arduino /
    #    common USB-UART bridge chips found on Uno-compatible boards)
    known_patterns = ("arduino", "ch340", "ch341", "usb-serial", "cp210", "ftdi")
    ports = list(list_ports.comports())
    known = [
        p for p in ports
        if any(k in (p.description or "").lower() for k in known_patterns)
    ]

    if len(known) > 1:
        log("Multiple matching devices found, using the first one. "
            "If it's wrong, set the port manually (--port):", "Yellow")
        for p in known:
            log(f"  - {p.device} ({p.description})", "Yellow")

    if known:
        log(f"Autodetect: found device '{known[0].description}' -> {known[0].device}", "Green")
        return known[0].device

    # 2) Fallback: no description match - prioritize ttyACM (native USB CDC,
    #    as on Uno/Leonardo-class boards), then ttyUSB (USB-UART adapters)
    candidates = sorted(glob.glob("/dev/ttyACM*")) + sorted(glob.glob("/dev/ttyUSB*"))

    if len(candidates) > 1:
        log(f"Multiple devices found ({', '.join(candidates)}), using the first one. "
            "If it's wrong, set --port manually.", "Yellow")

    if candidates:
        log(f"Autodetect (fallback): {candidates[0]}", "Green")
        return candidates[0]

    return None


def resolve_serial_port(override=""):
    for attempt in range(1, PORT_RETRY_ATTEMPTS + 1):
        found = find_serial_port(override)
        if found:
            return found

        log(f"Port not found (attempt {attempt}/{PORT_RETRY_ATTEMPTS}). "
            f"Retrying in {PORT_RETRY_DELAY_SEC} sec...", "Yellow")
        time.sleep(PORT_RETRY_DELAY_SEC)

    raise RuntimeError(
        f"Could not find a serial port after {PORT_RETRY_ATTEMPTS} attempts. "
        "Connect the device or set the port manually: --port /dev/ttyACM0"
    )


# --- SESSION LOCK, NOTIFICATIONS, AND PASSWORD PROMPT ---
_notify_last_shown = {}


def show_notification(title, message, urgency="normal"):
    # urgency: "low", "normal", "critical" (notify-send levels).
    # Some desktop environments render "critical" notifications even over
    # the lock screen; most only show notifications once you're back at an
    # unlocked, interactive desktop.
    if shutil.which("notify-send"):
        try:
            subprocess.run(
                ["notify-send", "-u", urgency, "-a", "AlcoLock", title, message],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return
        except Exception:
            pass
    # Fallback: at least put it in the log clearly if no notifier is available.
    log(f"[NOTIFY] {title} - {message}", "Cyan")


def show_notification_throttled(key, title, message, urgency="normal", min_interval_sec=5):
    # Same as show_notification, but skips repeats of the same message "key"
    # within min_interval_sec - prevents flooding the notification area
    # every 0.5s while a stage is still in progress.
    now = time.monotonic()
    last = _notify_last_shown.get(key)
    if last is not None and (now - last) < min_interval_sec:
        return
    _notify_last_shown[key] = now
    show_notification(title, message, urgency)


def is_session_locked():
    # Best-effort check of whether the session is *actually* still locked
    # right now, so we don't blindly re-issue a lock call (and a matching
    # notification) on every single poll tick.
    session_id = os.environ.get("XDG_SESSION_ID")
    if not session_id:
        return False
    try:
        result = subprocess.run(
            ["loginctl", "show-session", session_id, "-p", "LockedHint", "--value"],
            capture_output=True, text=True, timeout=2,
        )
        return result.stdout.strip() == "yes"
    except Exception:
        return False


_last_lock_call = 0.0
_last_lock_warn = 0.0


def invoke_lock(debug, reason=""):
    global _last_lock_call, _last_lock_warn

    if debug:
        now = time.monotonic()
        if now - _last_lock_call < 3:
            return
        _last_lock_call = now
        suffix = f" Reason: {reason}" if reason else ""
        log(f"[DEBUG] >>> SESSION LOCK CALL <<<{suffix}", "Red")
        return

    if is_session_locked():
        # Already locked - nothing to do. This is the fix for the "instant,
        # unexplained re-lock loop": we no longer call the lock command on
        # every 0.5s tick regardless of state.
        return

    # The session is NOT locked right now - either this is the very first
    # lock of this stage, or the user just authenticated back in. This is
    # also the only moment a notification can actually be seen (you cannot
    # draw custom UI over the real lock screen - that's an OS security
    # boundary, not a limitation of this script) - so explain why before
    # locking again.
    if reason:
        show_notification("AlcoLock", reason, urgency="normal")

    # Try a few common session-lock mechanisms, in order of portability.
    # Which ones are actually available depends on your desktop environment.
    # NOTE: if none of these are available (no locker daemon registered),
    # the call below may silently do nothing visually even though it
    # "succeeds" - see the README for why this depends on your DE.
    lock_commands = [
        ["loginctl", "lock-session"],
        ["xdg-screensaver", "lock"],
        ["dm-tool", "lock"],
        ["gnome-screensaver-command", "-l"],
        ["cinnamon-screensaver-command", "-l"],
        ["xscreensaver-command", "-lock"],
    ]
    for cmd in lock_commands:
        if shutil.which(cmd[0]):
            try:
                subprocess.run(
                    cmd, check=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                return
            except subprocess.CalledProcessError:
                continue

    now = time.monotonic()
    if now - _last_lock_warn >= 10:
        _last_lock_warn = now
        log("[WARNING] Could not find a working screen-lock command for this "
            "desktop environment. Tried: loginctl, xdg-screensaver, dm-tool, "
            "gnome-screensaver-command, cinnamon-screensaver-command, "
            "xscreensaver-command.", "Yellow")


def prompt_master_password(debug):
    if debug:
        log("[DEBUG] Password prompt skipped (--debug active). Returning None.", "Yellow")
        return None
    return getpass.getpass("Master password: ")


# --- REMOVAL AND FULL CLEANUP ---
def remove_alcolock(debug):
    log("Requesting cleanup and system shutdown...", "Yellow")

    input_pass = prompt_master_password(debug)
    if input_pass == MASTER_PASSWORD:
        try:
            for unit in (f"{SERVICE_NAME}.service", f"{SERVICE_NAME}.timer"):
                subprocess.run(
                    ["systemctl", "--user", "disable", "--now", unit],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                unit_path = SYSTEMD_USER_DIR / unit
                if unit_path.exists():
                    unit_path.unlink()

            if INSTALL_DIR.exists():
                shutil.rmtree(INSTALL_DIR, ignore_errors=True)

            subprocess.run(
                ["systemctl", "--user", "daemon-reload"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            log("AlcoLock has been completely removed from the system.", "Green")
        except Exception as e:
            log(f"Error during removal: {e}", "Red")
    else:
        log("Incorrect master password!", "Red")


# --- SELF-INSTALL TO AUTOSTART (systemd --user) ---
def install_self(debug, mode):
    if debug:
        log("[DEBUG] Skipping autostart (--debug active).", "Cyan")
        return

    script_path = Path(__file__).resolve()
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    target_path = INSTALL_DIR / "alco_lock.py"
    shutil.copy2(script_path, target_path)

    SYSTEMD_USER_DIR.mkdir(parents=True, exist_ok=True)
    python_exe = sys.executable
    service_path = SYSTEMD_USER_DIR / f"{SERVICE_NAME}.service"

    if mode == "Normal":
        # One-shot check + hourly timer, mirroring a Windows Task Scheduler
        # trigger with a 1-hour repetition interval.
        service_path.write_text(
            "[Unit]\n"
            "Description=AlcoLock breathalyzer screen lock (one-shot check)\n\n"
            "[Service]\n"
            "Type=oneshot\n"
            f"ExecStart={python_exe} {target_path} --mode Normal\n"
        )
        timer_path = SYSTEMD_USER_DIR / f"{SERVICE_NAME}.timer"
        timer_path.write_text(
            "[Unit]\n"
            "Description=Run AlcoLock hourly\n\n"
            "[Timer]\n"
            "OnBootSec=1min\n"
            "OnUnitActiveSec=1h\n\n"
            "[Install]\n"
            "WantedBy=timers.target\n"
        )
        subprocess.run(["systemctl", "--user", "daemon-reload"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "--user", "enable", "--now", f"{SERVICE_NAME}.timer"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"Installed as a systemd --user timer ({SERVICE_NAME}.timer), running hourly.", "Green")
    else:
        # Bake in the graphical session's environment at install time, since
        # a systemd --user service doesn't reliably inherit DISPLAY/XAUTHORITY
        # otherwise - without this, tkinter would fail to open any window.
        env_lines = ""
        for var in ("DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY"):
            value = os.environ.get(var)
            if value:
                env_lines += f"Environment={var}={value}\n"
        if not env_lines:
            log("[WARNING] Could not detect DISPLAY/XAUTHORITY in this session - "
                "the GUI lock window may not be able to open when run as a "
                "systemd service. Re-run this install from your normal desktop "
                "session (not over SSH) if that happens.", "Yellow")

        service_path.write_text(
            "[Unit]\n"
            "Description=AlcoLock breathalyzer screen lock (background monitor)\n"
            "After=graphical-session.target\n\n"
            "[Service]\n"
            "Type=simple\n"
            f"{env_lines}"
            f"ExecStart={python_exe} {target_path} --mode Quiet\n"
            "Restart=on-failure\n"
            "RestartSec=5\n\n"
            "[Install]\n"
            "WantedBy=default.target\n"
        )
        subprocess.run(["systemctl", "--user", "daemon-reload"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "--user", "enable", "--now", f"{SERVICE_NAME}.service"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"Installed as a systemd --user service ({SERVICE_NAME}.service), enabled at login.", "Green")


# --- STARTUP CALIBRATION AND WARMUP ---
def initialize_baseline(ser):
    log(f"Initializing sensor: starting calibration and warmup ({WARMUP_SEC} sec)...", "Yellow")

    try:
        ser.reset_input_buffer()
    except Exception:
        pass

    samples = []
    start_time = time.monotonic()

    while time.monotonic() - start_time < WARMUP_SEC:
        try:
            line = ser.readline().decode(errors="ignore").strip()
            if line.isdigit():
                val = int(line)
                # Filter out buffer glitches and anomalies (> 500)
                if val < 500:
                    samples.append(val)
                    log(f"Startup calibration: {val} (samples: {len(samples)})", "DarkGray")
                else:
                    log(f"Skipped anomalous spike: {val}", "Yellow")
        except Exception:
            log("Error reading during calibration!", "Red")
        time.sleep(0.5)

    baseline_val = 80  # Default fallback

    if samples:
        # Take the second half of the samples (once the sensor has stabilized)
        half_index = len(samples) // 2
        stable_samples = samples[half_index:]
        baseline_val = round(sum(stable_samples) / len(stable_samples))

    log(f"Calibration complete! Clean air baseline value: {baseline_val}", "Green")
    return baseline_val


# --- SHARED BREATH-TEST AND VALIDATION LOGIC ---
def start_sober_verification_loop(ser, baseline_val, debug, status_cb=None, override_event=None):
    """
    status_cb(headline, detail): optional callback invoked on every state
      change, used to drive the GUI lock overlay (see run_lock_overlay).
    override_event: optional threading.Event - if set (e.g. by a correct
      master password typed into the GUI), returns immediately instead of
      waiting for a real sober breath.
    """
    try:
        ser.reset_input_buffer()
    except Exception:
        pass

    rearm_threshold = baseline_val + 40   # Level the chamber must drop below to be considered clear
    min_blowing_val = baseline_val + 10   # Minimum level for a clean breath
    delta_trigger = 15                    # Minimum sharp jump (+15) to detect an impulse

    # ---------------------------------------------------------
    # STAGE 1: Waiting for the sensor chamber to clear of previous vapors (Re-arm)
    # ---------------------------------------------------------
    log(f"LOCKED! Waiting for the sensor chamber to clear (value must drop below {rearm_threshold})...", "Red")

    # Remember the actual last sensor value from the clearing stage, so we
    # don't "inherit" a stale baseline when moving to Stage 2 (this is the
    # exact bug that used to cause a false unlock from residual vapor).
    last_rearm_val = baseline_val

    while True:
        if override_event and override_event.is_set():
            log("Master password override accepted - skipping the rest of the breath verification.", "Yellow")
            return

        invoke_lock(debug, reason=(
            f"Alcohol detected. Waiting for the sensor to clear before you can "
            f"retest (currently {last_rearm_val}, need <= {rearm_threshold}). Do not blow yet."
        ))
        try:
            line = ser.readline().decode(errors="ignore").strip()
            if line.isdigit():
                val = int(line)
                last_rearm_val = val
                if val <= rearm_threshold:
                    log(f"Chamber cleared ({val} <= {rearm_threshold}). System ready for a new breath test!", "Green")
                    show_notification("AlcoLock", "Sensor cleared. You can breathe into the sensor now.", "normal")
                    if status_cb:
                        status_cb("Sensor cleared!", "You can breathe into the sensor now.")
                    break
                else:
                    log(f"Clearing chamber: {val} (waiting for <= {rearm_threshold})", "DarkGray")
                    show_notification_throttled(
                        "rearm", "AlcoLock - Locked",
                        f"Sensor still elevated: {val} (need <= {rearm_threshold}). "
                        f"Waiting for it to clear - do not blow yet.",
                        urgency="normal", min_interval_sec=5,
                    )
                    if status_cb:
                        status_cb(
                            "🔒 Alcohol detected - waiting for the sensor to clear",
                            f"Current reading: {val}  (need ≤ {rearm_threshold})\nDo not blow yet.",
                        )
        except Exception:
            pass
        time.sleep(0.5)

    # ---------------------------------------------------------
    # STAGE 2: Waiting for an ACTIVE breath IMPULSE and measurement
    # ---------------------------------------------------------
    log(f"Waiting for a sharp breath (impulse +{delta_trigger} over 0.5s, "
        f"corridor: from {min_blowing_val} to {THRESHOLD})...", "Yellow")

    consecutive_sober_seconds = 0
    is_blowing_started = False
    # IMPORTANT: use the actual last sensor value (end of chamber clearing),
    # NOT baseline_val - otherwise the very first reading would produce a
    # fake "jump" relative to a long-stale background level.
    prev_val = last_rearm_val

    while True:
        if override_event and override_event.is_set():
            log("Master password override accepted - skipping the rest of the breath verification.", "Yellow")
            return

        invoke_lock(debug, reason=(
            f"Waiting for a breath test. Blow into the sensor now: needs a sharp "
            f"jump above {min_blowing_val}, then stay below {THRESHOLD} for {SOBER_TIME} sec."
        ))

        try:
            line = ser.readline().decode(errors="ignore").strip()
            if line.isdigit():
                val = int(line)
                delta = val - prev_val  # Rate of change of the value

                # 1. Detect the start of a breath by IMPULSE (sharp upward jump)
                if not is_blowing_started:
                    if delta >= delta_trigger and val >= min_blowing_val:
                        is_blowing_started = True
                        log(f"Breath IMPULSE detected! (Jump of +{delta}, current: {val}). "
                            f"Measuring sobriety ({SOBER_TIME} sec)...", "Yellow")
                        show_notification(
                            "AlcoLock",
                            f"Breath detected! Keep breathing steadily for {SOBER_TIME} seconds...",
                            "normal",
                        )
                    else:
                        log(f"Waiting for breath... Value: {val} (Delta: {delta}, "
                            f"need jump >= +{delta_trigger})", "DarkGray")
                        if status_cb:
                            status_cb(
                                "🫁 Ready when you are - blow into the sensor",
                                f"Current reading: {val}  (need a sharp jump above {min_blowing_val})",
                            )
                        prev_val = val
                        time.sleep(0.5)
                        continue

                # 2. Evaluate the breath itself during the blow
                log(f"Blowing: {val} (Corridor: {min_blowing_val} - {THRESHOLD}, "
                    f"Progress: {consecutive_sober_seconds}/{SOBER_TIME} sec)", "Magenta")
                show_notification_throttled(
                    "blow-progress", "AlcoLock - Measuring",
                    f"Reading: {val} (need < {THRESHOLD}). Sober for "
                    f"{consecutive_sober_seconds}/{SOBER_TIME} sec - keep breathing steadily.",
                    urgency="normal", min_interval_sec=1,
                )
                if status_cb:
                    status_cb(
                        "📏 Measuring your breath...",
                        f"Reading: {val}  (must stay < {THRESHOLD})\n"
                        f"Sober for {consecutive_sober_seconds}/{SOBER_TIME} sec - keep breathing steadily.",
                    )

                if val < min_blowing_val:
                    # Breath interrupted
                    log("Breath interrupted! Resetting counter.", "Yellow")
                    show_notification(
                        "AlcoLock", "Breath interrupted - the test reset. Blow into the sensor again.", "normal",
                    )
                    if status_cb:
                        status_cb("⚠️ Breath interrupted", "The test reset - blow into the sensor again.")
                    consecutive_sober_seconds = 0
                    is_blowing_started = False
                elif val < THRESHOLD:
                    # Sober breath (within the corridor)
                    consecutive_sober_seconds += 1
                    if consecutive_sober_seconds >= SOBER_TIME:
                        log("Successful breath test! Access restored.", "Green")
                        show_notification(
                            "AlcoLock", "Success! You are clear - the screen will stay unlocked.", "normal",
                        )
                        if status_cb:
                            status_cb("✅ Success!", "You are clear. Closing this window...")
                        break
                else:
                    # Drunk breath (alcohol threshold exceeded)
                    log(f"ALCOHOL DETECTED IN BREATH! ({val} >= {THRESHOLD})", "Red")
                    show_notification(
                        "AlcoLock",
                        f"Still over the limit ({val} >= {THRESHOLD}). Wait for the sensor to clear, then try again.",
                        "critical",
                    )
                    if status_cb:
                        status_cb(
                            "❌ Still over the limit",
                            f"Reading: {val}  (limit: {THRESHOLD})\nWait for the sensor to clear, then try again.",
                        )
                    consecutive_sober_seconds = 0
                    is_blowing_started = False

                prev_val = val
        except Exception:
            log("Error reading during breath test (sensor disconnected?)", "Red")

        time.sleep(0.5)


# --- GUI LOCK OVERLAY (Linux has no equivalent of Windows' Secure Desktop
#     lock screen guaranteed to be present, so this window IS the enforced
#     barrier: it stays on top and only closes on a real sober breath or a
#     correct master password) ---
def run_lock_overlay(ser, baseline_val, debug):
    if not TKINTER_AVAILABLE:
        log("[WARNING] tkinter is not installed - falling back to console-only "
            "enforcement. Install it with your package manager, e.g. "
            "'sudo apt install python3-tk'.", "Yellow")
        invoke_lock(debug, reason="Alcohol detected. (GUI unavailable - see console for status.)")
        start_sober_verification_loop(ser, baseline_val, debug)
        return

    override_event = threading.Event()
    done_event = threading.Event()
    status_lock = threading.Lock()
    status_holder = {"headline": "Starting breath test...", "detail": ""}

    def status_cb(headline, detail=""):
        with status_lock:
            status_holder["headline"] = headline
            status_holder["detail"] = detail

    def worker():
        try:
            start_sober_verification_loop(
                ser, baseline_val, debug,
                status_cb=status_cb, override_event=override_event,
            )
        finally:
            done_event.set()

    # Best-effort real OS-level lock too (defense in depth, in case an actual
    # locker daemon is present) - this window is what actually enforces things.
    invoke_lock(debug, reason="Alcohol detected. A verification window has opened.")

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    root = tk.Tk()
    root.title("AlcoLock")
    try:
        root.attributes("-fullscreen", True)
    except Exception:
        root.geometry("900x500")
    root.attributes("-topmost", True)
    root.configure(bg="#1a1a1a")
    # Disable the window-manager close button - the only ways out are a
    # correct master password or a genuine sober breath.
    root.protocol("WM_DELETE_WINDOW", lambda: None)

    tk.Label(
        root, text="🔒 AlcoLock", font=("Sans", 34, "bold"),
        fg="#ff5555", bg="#1a1a1a",
    ).pack(pady=(70, 15))

    headline_lbl = tk.Label(
        root, text="", font=("Sans", 20, "bold"), fg="white", bg="#1a1a1a",
        wraplength=800, justify="center",
    )
    headline_lbl.pack(pady=10)

    detail_lbl = tk.Label(
        root, text="", font=("Sans", 14), fg="#bbbbbb", bg="#1a1a1a",
        wraplength=800, justify="center",
    )
    detail_lbl.pack(pady=10)

    tk.Frame(root, height=2, bg="#444444").pack(fill="x", padx=200, pady=30)

    tk.Label(
        root, text="Blow into the sensor to unlock, or enter the master password:",
        font=("Sans", 12), fg="#cccccc", bg="#1a1a1a",
    ).pack(pady=(0, 10))

    pw_frame = tk.Frame(root, bg="#1a1a1a")
    pw_frame.pack(pady=5)
    pw_var = tk.StringVar()
    pw_entry = tk.Entry(pw_frame, textvariable=pw_var, show="*", font=("Sans", 13), width=24)
    pw_entry.pack(side="left", padx=(0, 10))

    error_lbl = tk.Label(root, text="", font=("Sans", 11), fg="#ff5555", bg="#1a1a1a")

    def try_unlock(_event=None):
        if pw_var.get() == MASTER_PASSWORD:
            override_event.set()
        else:
            error_lbl.config(text="Incorrect password.")
            error_lbl.pack(pady=(5, 0))
            pw_var.set("")

    unlock_btn = tk.Button(pw_frame, text="Unlock", font=("Sans", 12), command=try_unlock)
    unlock_btn.pack(side="left")
    pw_entry.bind("<Return>", try_unlock)
    pw_entry.focus_set()

    def poll():
        with status_lock:
            headline_lbl.config(text=status_holder["headline"])
            detail_lbl.config(text=status_holder["detail"])
        if done_event.is_set():
            root.after(600, root.destroy)  # brief pause so "Success!" is visible
            return
        root.after(300, poll)

    root.after(300, poll)
    root.mainloop()

    # Whichever way the window closed (real success or master-password
    # override), make sure the background thread actually stops.
    override_event.set()
    thread.join(timeout=5)


EXAMPLES_TEXT = """
examples:
  alco_lock.py
      Normal mode, autodetected port.

  alco_lock.py --mode Quiet
      Background monitoring mode (installed at login via systemd).

  alco_lock.py --mode Quiet --debug
      Safe dry run: watch the sensor and simulated lock/unlock logs without
      actually locking your session.

  alco_lock.py --mode Quiet --port /dev/ttyACM0
      Force a specific device instead of autodetecting.

  alco_lock.py --cleanup
      Fully uninstall (prompts for the master password).
"""


def parse_args():
    parser = argparse.ArgumentParser(
        prog="alco_lock.py",
        description="AlcoLock - breathalyzer-gated screen lock (Linux)",
        epilog=EXAMPLES_TEXT,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--mode", choices=["Normal", "Quiet"], default="Normal",
        help="Normal: lock once, verify, exit (default). "
             "Quiet: run continuously in the background.",
    )
    parser.add_argument(
        "-d", "--debug", action="store_true",
        help="Dry run - log actions instead of actually locking the "
             "session or requiring a real password.",
    )
    parser.add_argument(
        "--cleanup", "--disable-autostart", dest="cleanup", action="store_true",
        help="Remove the systemd unit(s) and installed files "
             "(asks for the master password first).",
    )
    parser.add_argument(
        "--port", default="",
        help="Force a specific serial port (e.g. /dev/ttyACM0), "
             "skipping autodetection.",
    )
    return parser.parse_args()


def main():
    global CURRENT_MODE

    args = parse_args()
    CURRENT_MODE = args.mode

    if args.cleanup:
        remove_alcolock(args.debug)
        sys.exit(0)

    install_self(args.debug, CURRENT_MODE)

    log(f"Starting AlcoLock. Mode: {CURRENT_MODE}.", "Green")
    if args.debug:
        log("DEBUG MODE ACTIVE", "Yellow")

    port_name = resolve_serial_port(args.port)
    log(f"Using port: {port_name}", "Green")

    try:
        ser = serial.Serial(port_name, BAUD_RATE, timeout=1)
    except Exception as e:
        log(f"Error opening serial port: {e}", "Red")
        if CURRENT_MODE == "Quiet":
            invoke_lock(args.debug, reason="Could not open the sensor's serial port. Locking until it's available again.")
        sys.exit(1)

    try:
        global_baseline = initialize_baseline(ser)

        if CURRENT_MODE == "Normal":
            # ================= NORMAL MODE =================
            run_lock_overlay(ser, global_baseline, args.debug)
            log("Authentication session complete. Script will exit until next run.", "Cyan")

        else:
            # ================= QUIET MODE =================
            while ser.is_open:
                try:
                    line = ser.readline().decode(errors="ignore").strip()
                    if line.isdigit():
                        val = int(line)
                        log(f"Background monitoring: {val}", "White")

                        if val > THRESHOLD:
                            log(f"THRESHOLD EXCEEDED! ({val} > {THRESHOLD})", "Red")
                            # Reuse the already-known baseline, without another 10-sec warmup
                            run_lock_overlay(ser, global_baseline, args.debug)

                except (serial.SerialException, OSError):
                    log("WARNING: SENSOR DISCONNECTED OR SERIAL CONNECTION LOST!", "Red")
                    invoke_lock(args.debug, reason="Sensor disconnected. Locking until it reconnects.")

                    while not ser.is_open:
                        invoke_lock(args.debug, reason="Sensor disconnected. Reconnect the device to unlock.")
                        time.sleep(1)
                        try:
                            ser.open()
                        except Exception:
                            pass

                    # Recalibrate clean air on reconnect
                    global_baseline = initialize_baseline(ser)
                    run_lock_overlay(ser, global_baseline, args.debug)

                time.sleep(2)
    finally:
        if ser.is_open:
            ser.close()


if __name__ == "__main__":
    main()
