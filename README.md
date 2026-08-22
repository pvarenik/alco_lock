# ALCOBLOCKER

ALCOBLOCKER is an experimental desktop breath-check gate built around an Arduino + MQ-3 sensor. It has a Windows PowerShell implementation and a Linux/Python implementation.

> **Important:** This is an experimental desktop automation project, not a certified breathalyzer, medical device, or reliable BAC/promille measurement system. MQ-3 raw ADC readings depend on warm-up, calibration, sensor condition, temperature, humidity, airflow, contamination, and hardware differences. Do not use this software to make safety-critical decisions such as deciding whether it is safe to drive.

## Quick start

### Windows

```powershell
# Run the existing installed runtime manually
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -Run

# Same, with live diagnostic output
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -Run -DebugMode

# Run the built-in tests without starting the GUI
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -SelfTest
```

When started in normal install mode, the script registers the scheduled task, starts the hidden runtime with `-Run`, and exits. The runtime searches for the Arduino, stabilizes the sensor, calibrates a fresh baseline, waits for a breath, and then either unlocks or stays locked.

### Linux

```bash
# Start the default Linux UI
python3 AlcoholBlocker.py

# Start with diagnostic logging in the terminal
python3 AlcoholBlocker.py --debug

# Run tests without starting the GUI
python3 AlcoholBlocker.py --self-test
```

The Linux application follows the same high-level pipeline: find Arduino/CH340, stabilize the sensor, collect a fresh baseline, wait for a five-second downward breath event, compare the observed signal with `baseline + 200`, and unlock or remain locked.

---

# Hardware: Arduino Uno R3 + MQ-3

ALCOBLOCKER reads the MQ-3 **analog output (AO)** through Arduino Uno R3 pin **A0**. The Arduino sketch sends one raw ADC value (`0..1023`) over the serial port every 500 ms at **9600 baud**. The supplied sketch does not use the MQ-3 digital output (`DO`).

The project targets an Arduino Uno R3 or a compatible clone (for example, an ATmega328 board using a CH340 USB-serial chip) together with a standard 4-pin MQ-3 breakout module (`VCC`, `GND`, `DO`, `AO`).

## Wiring

```text
          Arduino Uno R3                     MQ-3 breakout
        +----------------+                 +----------------+
        |                |                 |                |
        | 5V  ----------+---------------->| VCC            |
        |                |                 |                |
        | GND ----------+---------------->| GND            |
        |                |                 |                |
        | A0  <----------+-----------------| AO             |
        |                |                 |                |
        |                |                 | DO   NC         |
        +----------------+                 +----------------+

Serial communication:
Arduino USB/CH340  <---- USB ---->  Windows / Linux host
                                   9600 baud
                                   one integer / line
                                   every 500 ms
```

### Pin mapping

| Arduino Uno R3 | MQ-3 module | Purpose |
|---|---|---|
| `5V` | `VCC` | Sensor/module power |
| `GND` | `GND` | Common ground |
| `A0` | `AO` | Analog sensor reading |
| — | `DO` | Not used by ALCOBLOCKER |

> **Hardware note:** the repository code assumes a standard 4-pin MQ-3 breakout and reads `AO`. Check the markings and supply requirements of your particular module before powering it; breakout boards can differ.

## Arduino sketch

The complete sketch used by the project is included below. It intentionally does not implement sensor warm-up or baseline calibration on the Arduino itself; the host application performs its stabilization and calibration cycle.

```cpp
// alco_sensor.ino
//
// Streams raw MQ-3 analog readings over serial, one plain integer per line,
// at 9600 baud - the exact protocol ALCOBLOCKER expects.
//
// Hardware: Arduino Uno R3 (or compatible clone, e.g. ATmega328 + CH340) +
// a standard 4-pin MQ-3 breakout module (VCC / GND / DO / AO).

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

The sketch's serial protocol is deliberately simple:

```text
622
623
621
620
...
```

Each line is a raw Arduino ADC reading from `A0`, in the range `0..1023`. The host application is responsible for interpreting those values.

---

# Windows

## Windows implementation

The Windows implementation is a PowerShell 5.1 script using WinForms for the overlay and Windows PnP for serial-device discovery.

Example filename used during development:

```text
AlcoholGuard_v24.ps1
```

Later Windows revisions added UI, cleanup, ten-minute scheduling, improved sensor stabilization, and other refinements. Use the latest Windows script from the repository rather than mixing revisions.

## Windows requirements

- Windows PowerShell 5.1.
- Arduino-compatible board with MQ-3 sensor.
- Arduino outputs one integer per line at `9600` baud.
- Windows must detect the board as a serial device, for example `USB-SERIAL CH340 (COM3)`.
- Scheduled Task registration may require appropriate Windows permissions depending on the account and Task Scheduler configuration.

Example Arduino sketch:

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

## Windows command-line flags

The script supports four switches:

```text
-Run
-CleanUp
-SelfTest
-DebugMode
```

### `-Run`

Starts the actual GUI/runtime instead of installing the scheduled task.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -Run
```

Typical use: direct testing or starting the runtime manually.

### `-DebugMode`

Adds detailed runtime information to the console/log.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -Run -DebugMode
```

Debug output can include:

- Windows PnP serial-port candidates.
- COM-port probing.
- Sensor connection/disconnection.
- Stabilization values.
- Baseline and calculated thresholds.
- State transitions.
- Breath confirmation.
- Alcohol threshold events.
- Hourly/ten-minute scheduling events.

`-DebugMode` is also passed to the scheduled runtime when the script is installed with that switch.

### `-SelfTest`

Runs algorithm/configuration tests and exits.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -SelfTest
```

No GUI or Arduino is required for the algorithm tests.

### `-CleanUp`

Removes the scheduled task and other project-created runtime artifacts according to the cleanup implementation.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -CleanUp
```

The cleanup mode is intended to stop the running AlcoholGuard runtime, remove its scheduled task, release/close its own resources, and remove the application's own log/state artifacts. It does not remove unrelated Windows telemetry or system logs.

## Windows launch examples

### Normal installation / persistent setup

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1
```

Pipeline:

```text
PowerShell script
    |
    +--> register/update Scheduled Task
    |
    +--> start hidden PowerShell child with -Run
    |
    `--> installer process exits
             |
             v
       AlcoholGuard runtime
```

### Install with debug mode

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -DebugMode
```

The scheduled task starts the runtime with `-Run -DebugMode`.

### Manual runtime

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -Run
```

### Manual runtime with debug

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -Run -DebugMode
```

### Self-test

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -SelfTest
```

### Cleanup

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -CleanUp
```

### Flag combinations

```powershell
# Install + pass debug mode to the scheduled runtime
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -DebugMode

# Run + debug
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -Run -DebugMode

# Test only
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -SelfTest

# Cleanup only
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard_v24.ps1 -CleanUp
```

`-Run`, `-CleanUp`, and `-SelfTest` are operational modes and are intended to be used separately. `-DebugMode` is the diagnostic modifier.

## Windows runtime pipeline

### 1. Runtime starts

The GUI is created as a fullscreen, top-most WinForms overlay. A low-level keyboard hook blocks common escape paths while the overlay is locked.

The implementation is a desktop overlay, not the Windows Secure Attention Sequence. A normal application cannot intercept `Ctrl+Alt+Del`.

### 2. Arduino discovery

The script does not hard-code `COM3`, `COM4`, or another port.

It asks Windows PnP for present serial devices, ranks likely Arduino/CH340/USB-serial devices, opens candidates at `9600` baud, and accepts a candidate only after valid sensor output is available.

For example:

```text
USB-SERIAL CH340 (COM3)
USB Serial Device (COM5)
Bluetooth COM Port (COM7)
```

The Arduino/CH340 candidate receives a higher priority and is verified by the `0..1023` serial data format.

### 3. Sensor stabilization

A new baseline is **not** taken immediately after the serial port is detected.

The current logic treats clean air as an expected reading below:

```text
150
```

However, being below `150` is not enough by itself. A sliding window is checked for:

- a small total span;
- small first-to-last drift;
- limited downward movement;
- a final value still below the clean-air ceiling.

This prevents a failure mode such as:

```text
100 -> 95 -> 90 -> 85 -> 80 -> 75 -> 70 -> 65
```

from becoming a false baseline merely because every value eventually became lower than `150`.

High and slowly falling readings are treated as sensor warm-up/glitch conditions. The UI can ask the user to reconnect the sensor or touch/handle it to help it return to a stable state.

### 4. Baseline calibration

Once stabilization is accepted, the runtime collects a fresh calibration window for about ten seconds. The median of the collected samples becomes the new clean-air baseline.

This baseline is recalculated for each new check and when `Refresh baseline & retest` is pressed.

### 5. Breath detection

The current sensor behavior observed during development is that a sober breath tends to move the MQ-3 reading downward.

The runtime therefore watches for a suspicious downward movement. Once a possible breath starts, it observes the signal for up to five seconds and requires an actual downward trend rather than merely one or two noisy samples.

The five-second observation was introduced to avoid the previous behavior where a `BreathDetected` state could sit for a long time waiting for the value to return to baseline.

### 6. Alcohol threshold

The current experimental rule is:

```text
alcohol_threshold = baseline + 200
```

with the ADC ceiling of `1023`.

Examples:

```text
baseline = 45   -> threshold = 245
baseline = 75   -> threshold = 275
baseline = 100  -> threshold = 300
baseline = 150  -> threshold = 350
```

This is a raw ADC threshold, not a blood-alcohol concentration measurement.

### 7. Final decision

A confirmed sober breath causes the overlay to unlock.

If the observed signal reaches the alcohol threshold, the runtime enters `AlcoholDetected` and keeps the overlay locked.

The master password is the emergency override:

```text
1989
```

### 8. New check

The current development/test interval is **10 minutes**.

After a successful unlock:

```text
Unlocked
   |
   +--> schedule next check in 600 seconds
   |
   v
wait
   |
   v
lock overlay
   |
   v
reuse the connected sensor when possible
   |
   v
stabilize again
   |
   v
fresh baseline
   |
   v
wait for breath
```

## Windows UI controls

### Master password

The password field is centered on the screen and provides the master-password override.

### Refresh baseline & retest

This is one combined operation:

```text
button press
    |
    v
flush stale serial data
    |
    v
stabilize sensor
    |
    v
10-second calibration
    |
    v
new baseline / thresholds
    |
    v
start a new breath test immediately
```

## Windows logs

The Windows implementation stores its own log under the user's local application-data directory, under an `AlcoholGuard` folder. Exact location can be changed in the script configuration.

Debug mode also mirrors log messages to the PowerShell console.

---

# Linux

## Linux implementation

The Linux implementation is written in Python and uses Qt/PySide6 for the desktop UI and pyserial for Arduino communication.

Repository variants:

```text
AlcoholBlocker_UI1_ControlPanel.py
AlcoholBlocker_UI2_LargeStatus.py
AlcoholBlocker_UI3_Cockpit.py
```

All three use the same sensor/decision logic and differ only in presentation.

## Linux requirements

- Linux graphical desktop session.
- Python 3.10+ recommended.
- PySide6.
- pyserial.
- Arduino-compatible board with an MQ-3 sensor.

Arch Linux example:

```bash
sudo pacman -S python python-pyside6 python-pyserial
```

If distro packages are unavailable, use a virtual environment:

```bash
python -m venv .venv
. .venv/bin/activate
pip install PySide6 pyserial
```

### Serial permissions

Check the device:

```bash
ls -l /dev/ttyACM* /dev/ttyUSB* 2>/dev/null
```

On Arch Linux the serial device is commonly controlled by the `uucp` group:

```bash
sudo usermod -aG uucp "$USER"
```

Log out and back in after changing group membership.

## Linux command-line flags

The Linux implementation supports:

```text
--debug
--self-test
--cleanup
```

### `--debug`

Run the GUI with additional diagnostic information.

```bash
python3 AlcoholBlocker_UI3_Cockpit.py --debug
```

### `--self-test`

Run algorithm/configuration tests without starting the GUI.

```bash
python3 AlcoholBlocker_UI1_ControlPanel.py --self-test
```

The tests are intended to work without a physical Arduino.

### `--cleanup`

Remove the application's own user-service/state artifacts according to the Linux implementation.

```bash
python3 AlcoholBlocker_UI1_ControlPanel.py --cleanup
```

## Linux launch examples

### UI 1 — Control Panel

```bash
python3 AlcoholBlocker_UI1_ControlPanel.py
python3 AlcoholBlocker_UI1_ControlPanel.py --debug
python3 AlcoholBlocker_UI1_ControlPanel.py --self-test
python3 AlcoholBlocker_UI1_ControlPanel.py --cleanup
```

### UI 2 — Large Status

```bash
python3 AlcoholBlocker_UI2_LargeStatus.py
python3 AlcoholBlocker_UI2_LargeStatus.py --debug
python3 AlcoholBlocker_UI2_LargeStatus.py --self-test
python3 AlcoholBlocker_UI2_LargeStatus.py --cleanup
```

### UI 3 — Industrial / Cockpit

```bash
python3 AlcoholBlocker_UI3_Cockpit.py
python3 AlcoholBlocker_UI3_Cockpit.py --debug
python3 AlcoholBlocker_UI3_Cockpit.py --self-test
python3 AlcoholBlocker_UI3_Cockpit.py --cleanup
```

There is no separate Linux `--run` flag in the Python versions: normal invocation is the runtime.

## Linux pipeline

The Linux pipeline is intentionally aligned with Windows:

```text
start application
      |
      v
find Arduino / CH340 serial device
      |
      v
open at 9600 baud
      |
      v
stabilize sensor
      |
      v
collect fresh baseline
      |
      v
wait for breath
      |
      v
observe downward breath event for up to 5 seconds
      |
      +----------------------+
      |                      |
      v                      v
below alcohol limit      reaches baseline+200
      |                      |
      v                      v
   unlock              AlcoholDetected
```

### Sensor discovery

The Linux version scans available serial devices such as `/dev/ttyACM*` and `/dev/ttyUSB*`, ranks Arduino/CH340/USB-serial candidates, and validates candidates using the expected integer `0..1023` data stream.

### Stabilization and baseline

The same practical rules are used as on Windows: clean air is expected below `150`, slow downward drift is rejected, and a fresh ten-second median baseline is calculated only after the sensor appears stable.

### Breath test

A downward excursion is observed for up to five seconds. A stable/noisy signal is not enough. The purpose is to prevent the old long-lived `BreathDetected` condition from small fluctuations.

### Alcohol threshold

```text
alcohol_threshold = baseline + 200
```

capped at `1023`.

### Retest / baseline refresh

The Linux UI uses one combined control:

```text
Refresh baseline & retest
```

It starts stabilization, recalculates the baseline, recalculates thresholds, and immediately starts another breath test.

## Linux UI variants

### UI 1 — Control Panel

The most balanced layout. It keeps the diagnostic cards visible while giving the state message the main visual emphasis.

### UI 2 — Large Status

A minimal presentation dominated by the current state and sensor reading.

### UI 3 — Industrial / Cockpit

A denser instrument-panel presentation with live signal/trend information and more diagnostics.

## Linux systemd user services

Three service files are provided:

```text
alcoblocker-ui1.service
alcoblocker-ui2.service
alcoblocker-ui3.service
```

Example for UI3:

```bash
mkdir -p ~/.config/systemd/user
cp alcoblocker-ui3.service ~/.config/systemd/user/alcoblocker-ui3.service
systemctl --user daemon-reload
systemctl --user enable --now alcoblocker-ui3.service
```

Check it with:

```bash
systemctl --user status alcoblocker-ui3.service
journalctl --user -u alcoblocker-ui3.service -f
```

The service starts the application in the user's graphical session.

## Linux logging

The Linux implementation stores its own state/log information under the user's XDG state directory, typically:

```text
~/.local/state/alcoblocker/
```

If `XDG_STATE_HOME` is set, the application can use that base instead.

`--cleanup` is intended to remove only project-created service/state artifacts. It does not erase system journals or unrelated OS telemetry.

## Wayland / KDE limitations

This is one of the biggest differences between the Windows and Linux implementations.

The Linux application is a normal Qt desktop overlay. Under **Wayland**, the compositor deliberately controls global keyboard shortcuts and window-system security boundaries. A normal application cannot reliably install the same kind of system-wide low-level keyboard hook that the Windows implementation uses.

That means the Linux version cannot guarantee blocking all of the following while the overlay is visible:

- `Alt+Tab`.
- `Meta` / Super shortcuts.
- compositor-level `Ctrl+Alt+...` shortcuts.
- switching to another workspace or virtual desktop.
- other compositor-owned escape paths.

A fullscreen/top-most Qt window is therefore **not equivalent to a real secure lock screen**.

### X11

On X11, applications have more control over keyboard grabs, so a stronger local kiosk-style overlay is possible. Even there, this project should not be treated as an operating-system secure lock implementation.

### Wayland

For a genuinely kiosk-like deployment on KDE/Wayland, combine ALCOBLOCKER with compositor/session-level kiosk controls or the desktop's own lock-screen mechanisms. The application itself should be considered the breath-check UI/control layer, not the security boundary.

---

# MIT License

MIT is a permissive open-source license. It generally permits use, copying, modification, merging, publication, distribution, sublicensing, and selling of the software, including use inside proprietary products, provided the copyright and license notice are retained and the license terms are followed.

It is permissive, but it is not literally "no restrictions": the copyright/license notice requirement and the warranty/liability disclaimer remain.

See [LICENSE](LICENSE).

# Project status

ALCOBLOCKER is a hobby/experimental project for desktop automation and MQ-3 sensor experimentation. Sensor behavior is hardware-dependent and should be validated experimentally on the intended sensor before relying on any threshold.
