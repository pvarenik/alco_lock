# ALCOBLOCKER

ALCOBLOCKER is a hobby/project desktop breath-check application built around an Arduino Uno R3 + MQ-3 sensor. It periodically locks a graphical overlay, asks the user to blow into the sensor, establishes a fresh clean-air baseline, and decides whether the observed breath should unlock the screen or remain blocked.

> **Important:** this project is an experimental access-control/automation tool, not a certified breathalyzer and not a medical, legal, or forensic alcohol measurement device. MQ-3 raw ADC values are sensor-dependent and must not be interpreted as BAC/promille without proper calibration.

## Quick Start

### Windows — quickest path

Files:

- `AlcoholGuard_UI1_ControlPanel.ps1` — Control Panel UI
- `AlcoholGuard_UI2_LargeStatus.ps1` — Large Status UI
- `AlcoholGuard_UI3_Cockpit.ps1` — Industrial/Cockpit UI

Run the first UI with no parameters:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1
```

With no parameters the script **installs/updates the `AlcoholBreathGuard` Task Scheduler task and starts a hidden `-Run` worker immediately**. It is the normal installation/start command. If Windows denies task registration, run PowerShell as Administrator.

Before using the sensor, test the code:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1 -SelfTest
```

Run in visible diagnostic mode:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1 -Run -DebugMode
```

### Linux — quickest path

Files:

- `AlcoholBlocker_UI1_ControlPanel.py`
- `AlcoholBlocker_UI2_LargeStatus.py`
- `AlcoholBlocker_UI3_Cockpit.py`
- `alcoblocker-ui1.service`
- `alcoblocker-ui2.service`
- `alcoblocker-ui3.service`

Test first:

```bash
python3 AlcoholBlocker_UI1_ControlPanel.py --self-test
```

Run the UI:

```bash
python3 AlcoholBlocker_UI1_ControlPanel.py
```

Debug:

```bash
python3 AlcoholBlocker_UI1_ControlPanel.py --debug
```

Linux uses a fullscreen Qt overlay rather than a true secure lock screen. On Wayland, applications are deliberately restricted from globally intercepting compositor-level shortcuts such as `Alt+Tab`, `Meta`, and many `Ctrl+Alt+...` combinations. The README's Linux section explains the limitation and possible compositor/session-level approaches.

---

# Windows

## Windows UI variants

### UI1 — Control Panel

`AlcoholGuard_UI1_ControlPanel.ps1`

The balanced/default interface: status card, live sensor value, clean-air baseline, alcohol threshold, breath range, observed range, next scheduled check, master-password field, and `Refresh baseline & retest`.

### UI2 — Large Status

`AlcoholGuard_UI2_LargeStatus.ps1`

A simpler interface with a much larger primary status and sensor value. Useful when the application is primarily a screen gate and diagnostics are secondary.

### UI3 — Cockpit

`AlcoholGuard_UI3_Cockpit.ps1`

A denser instrument-panel style UI intended for debugging and sensor tuning.

## Windows command-line flags

Every Windows UI script supports these parameters:

| Flag | Meaning |
|---|---|
| *(none)* | Install/update the scheduled task, then start a hidden `-Run` worker immediately |
| `-Run` | Start the actual runtime directly; do not install the scheduled task |
| `-DebugMode` | Keep diagnostic logging in the console in addition to the log file |
| `-SelfTest` | Run algorithm/configuration tests and exit |
| `-CleanUp` | Stop other ALCOBLOCKER runtime processes, remove the scheduled task, and remove ALCOBLOCKER's own log artifacts |

### All useful Windows launch examples

Install + start normally:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1
```

Install + start with debug worker:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1 -DebugMode
```

Run directly without touching Task Scheduler:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1 -Run
```

Run directly with debug output:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1 -Run -DebugMode
```

Run the self-test:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1 -SelfTest
```

Run cleanup:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_UI1_ControlPanel.ps1 -CleanUp
```

The same commands apply to UI2 and UI3 by replacing the filename.

## Windows startup pipeline

### Normal launch with no parameters

```text
AlcoholGuard_UI*.ps1
        |
        +--> Register/refresh Scheduled Task: AlcoholBreathGuard
        |
        +--> Start hidden PowerShell worker with -Run
        |
        +--> installer process exits
                 |
                 v
          Guard runtime starts
                 |
                 v
          create mutex / build UI / install keyboard hook
                 |
                 v
          first scheduled check
                 |
                 v
          find Arduino through Windows PnP
                 |
                 v
          Stabilizing
                 |
                 v
          10-second baseline calibration
                 |
                 v
          WaitingForBreath
```

### `-Run`

`-Run` skips task registration. It starts the runtime directly. This is the preferred mode for development and debugging when you do not want to change Task Scheduler.

### `-SelfTest`

Self-test does not open the GUI. It exercises the numeric calibration/alcohol/breath logic and exits with code `0` when all tests pass and `1` when at least one test fails.

Current Windows self-test coverage includes:

- baseline median and adaptive breath thresholds;
- `AlcoholThreshold = baseline + 200`, capped by ADC `1023`;
- clean-air ceiling `150`;
- stabilization-window acceptance/rejection;
- high/falling sensor rejection;
- slow monotonic drift rejection;
- 5-second downward breath observation;
- flat/noisy and fall-then-rise breath rejection;
- configuration values such as the 10-minute interval and automatic PnP COM detection.

### `-CleanUp`

Cleanup is intended to remove the application's own runtime setup:

1. find other ALCOBLOCKER `-Run` PowerShell processes;
2. terminate those runtime processes;
3. stop/remove the `AlcoholBreathGuard` scheduled task;
4. remove `%LOCALAPPDATA%\AlcoholGuard\AlcoholGuard.log` and the directory if empty.

The cleanup process does not terminate itself.

## Windows runtime logic

### 1. Arduino discovery

The script does not hard-code `COM3`/`COM4`. It enumerates Windows PnP serial devices, prioritizes common Arduino/USB-UART names such as `CH340`, and accepts a candidate after it can use the serial stream at `9600` baud and receive numeric sensor values.

The Arduino is expected to output one raw ADC value (`0..1023`) per line.

### 2. Sensor stabilization

A newly connected sensor does not immediately become the baseline. The runtime first waits for a stable window.

The current safety assumptions are:

- clean-air maximum: `150`;
- stabilization window: `8` samples;
- maximum span: `6`;
- maximum total drift: `3`;
- maximum downward-trend steps: `3`;
- minimum stabilization time: `4` seconds;
- maximum stabilization time: `60` seconds.

This rejects situations such as `100 -> 95 -> 90 -> ...`, even when the values are already below `150`.

For very high/falling readings, the UI asks the user to reconnect the sensor and/or touch it by hand to help it settle.

### 3. Baseline calibration

Once the sensor is considered stable, the runtime collects a fresh 10-second calibration sample set and uses the median as the clean-air baseline.

The baseline is refreshed for each new scheduled check and can also be refreshed manually with `Refresh baseline & retest`.

### 4. Breath detection

A breath-like event is first detected from the adaptive breath thresholds around the baseline.

The current breath observation then lasts up to **5 seconds**. The intended sober-breath pattern is a sustained downward trend for the current sensor configuration: the reading must fall by at least the configured minimum amount and contain enough downward steps.

Flat/noisy readings and readings that fall and then rise are rejected instead of leaving the application in `BreathDetected` indefinitely.

### 5. Alcohol threshold

The current rule is:

```text
AlcoholThreshold = min(1023, baseline + 200)
```

Example:

```text
baseline 75  -> 275
baseline 90  -> 290
baseline 150 -> 350
baseline 250 -> 450
baseline 620 -> 820
```

This is a raw sensor threshold, not a BAC measurement.

### 6. Decision

For a confirmed sober downward breath, the screen is unlocked.

If the observed peak reaches the alcohol threshold, the state becomes `AlcoholDetected` and the screen stays blocked. The master password remains the emergency unlock path.

### 7. Next scheduled check

The current test interval is **10 minutes / 600 seconds**. At the next check the overlay locks again, an already-open sensor connection is reused, and stabilization + baseline calibration are performed again before another breath test.

## Windows log

Default log file:

```text
%LOCALAPPDATA%\AlcoholGuard\AlcoholGuard.log
```

For a typical user this is:

```text
C:\Users\<username>\AppData\Local\AlcoholGuard\AlcoholGuard.log
```

`-DebugMode` additionally prints log messages to the console.

## Windows limitations

The Windows UI is a user-session kiosk overlay, not the Windows secure lock screen. A normal PowerShell application cannot intercept `Ctrl+Alt+Del` at the secure-desktop level. The project therefore should not be treated as a security boundary against a determined local user.

---

# Linux

## Linux UI variants

### UI1 — Control Panel

`AlcoholBlocker_UI1_ControlPanel.py`

Balanced daily-use interface.

### UI2 — Large Status

`AlcoholBlocker_UI2_LargeStatus.py`

Minimal, status-first interface.

### UI3 — Cockpit

`AlcoholBlocker_UI3_Cockpit.py`

Dense diagnostic/instrument interface.

All three share the same core behavior and sensor thresholds; only the presentation differs.

## Linux command-line flags

| Flag | Meaning |
|---|---|
| *(none)* | Start the selected Qt UI normally |
| `--debug` | Start the UI with diagnostic logging enabled |
| `--self-test` | Run algorithm/configuration tests and exit |
| `--cleanup` | Stop/clean up the user's ALCOBLOCKER runtime/service setup as implemented by the script |

Examples:

```bash
python3 AlcoholBlocker_UI1_ControlPanel.py
python3 AlcoholBlocker_UI1_ControlPanel.py --debug
python3 AlcoholBlocker_UI1_ControlPanel.py --self-test
python3 AlcoholBlocker_UI1_ControlPanel.py --cleanup
```

Replace the filename with UI2 or UI3 for the other interfaces.

## Linux systemd user services

Example UI1 service:

```bash
systemctl --user daemon-reload
systemctl --user enable --now alcoblocker-ui1.service
```

UI2:

```bash
systemctl --user enable --now alcoblocker-ui2.service
```

UI3:

```bash
systemctl --user enable --now alcoblocker-ui3.service
```

## Linux runtime pipeline

The Linux pipeline mirrors the Windows algorithm:

```text
start Python UI
      |
      v
find serial device (Arduino / CH340 / USB-serial)
      |
      v
Stabilizing
      |
      v
10-second baseline calibration
      |
      v
WaitingForBreath
      |
      v
5-second breath observation
      |
      +---- sober downward trend ----> unlock overlay
      |
      +---- alcohol threshold reached -> keep blocked
      |
      v
next scheduled check
```

## Wayland / KDE limitations

This is the most important Linux caveat.

A normal Qt/Python application on Wayland cannot reliably install a global low-level keyboard hook equivalent to the Windows implementation. The compositor deliberately owns the global keyboard shortcuts and secure session controls.

In practice this means an ALCOBLOCKER fullscreen overlay cannot guarantee that the user cannot escape it with compositor-level actions such as:

- `Alt+Tab`;
- `Meta`/Super shortcuts;
- `Ctrl+Alt+...` combinations owned by the desktop environment;
- virtual-terminal/session switching;
- compositor/session-level logout or lock controls.

The overlay can still be fullscreen, always-on-top where the compositor permits it, and visually block normal interaction inside the application, but it should **not** be described as a secure lock screen on Wayland.

For stronger kiosk behavior on Linux, the appropriate solution is session/compositor-level configuration, a dedicated kiosk session, or integration with the desktop/session's own locking mechanism rather than relying on a regular Qt application alone.

## Linux dependencies

The project uses:

- Python 3;
- PySide6;
- pyserial.

On Arch Linux, install the distribution packages if available in your environment, or use a virtual environment/pip as appropriate.

Example:

```bash
sudo pacman -S python python-pyside6 python-pyserial
```

## Linux serial protocol

The Python application expects the Arduino to continuously output decimal ADC values from `0` to `1023`, one value per line, at `9600` baud.

---

# Arduino Uno R3 + MQ-3

The Arduino is intentionally simple: it reads the MQ-3 analog output and sends raw ADC values to the host. All stabilization, baseline, breath detection, and alcohol-threshold logic runs on Windows/Linux.

## Wiring

For a typical MQ-3 breakout with `VCC`, `GND`, `AO` and optional `DO` pins:

| MQ-3 | Arduino Uno R3 | Purpose |
|---|---|---|
| `VCC` | `5V` | Sensor power |
| `GND` | `GND` | Common ground |
| `AO` | `A0` | Analog sensor value |
| `DO` | not connected | Not used by ALCOBLOCKER |

ASCII wiring diagram:

```text
                 Arduino Uno R3
             +----------------------+
             |                      |
MQ-3 VCC ----| 5V                   |
MQ-3 GND ----| GND                  |
MQ-3 AO -----| A0                   |
MQ-3 DO -----| NC                   |
             |                      |
             +----------------------+
```

> MQ-3 breakout boards vary. Check the labels and electrical requirements of your particular module before wiring it.

## Arduino sketch

The repository includes `alco_sensor.ino`.

```cpp
const int MQ3_PIN = A0;
const unsigned long SAMPLE_INTERVAL_MS = 500;

void setup() {
  Serial.begin(9600);
}

void loop() {
  int value = analogRead(MQ3_PIN);
  Serial.println(value);
  delay(SAMPLE_INTERVAL_MS);
}
```

The host applications expect exactly this basic serial contract:

```text
9600 baud
one integer per line
0..1023
approximately every 500 ms
```

---

# License

This project is released under the **MIT License**.

In practical terms, MIT is a permissive license: you may use, copy, modify, merge, publish, distribute, sublicense, and sell copies of the software, including in commercial and closed-source projects. The main conditions are that the copyright notice and license text are retained in copies/distributions, and the software is provided without warranty.

See `LICENSE` for the complete license text.
