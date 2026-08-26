# ALCOBLOCKER

ALCOBLOCKER is an experimental desktop breath-check project built around an Arduino Uno R3 and an MQ-3 sensor. It periodically presents a fullscreen overlay, establishes a fresh clean-air baseline, waits for a detected breath, and either unlocks the session or keeps it blocked when the configured raw alcohol threshold is reached.

> **Important:** this is an experimental access-control project, not a certified breathalyzer and not a medical, legal, or forensic measurement device. MQ-3 raw ADC values are sensor- and hardware-dependent.

## Quick Start

### Windows

The current Windows release artifact is `AlcoholGuard_36.ps1`. In the examples below the stable, unversioned public name `AlcoholGuard.ps1` is used, as intended for the README and releases.

Self-test first:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -SelfTest
```

Normal installation and start:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1
```

The command with **no parameters** installs or refreshes the `AlcoholBreathGuard` Task Scheduler task and immediately starts the hidden worker with `-Run`.

Developer/debug run without installing the task:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run -DebugMode
```

Persistent logging is opt-in:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run -DebugMode -Log
```

Cleanup:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -CleanUp
```

### Linux

The current Linux release artifact is `AlcoholBlocker_36.py`. The README examples intentionally use the stable, unversioned name `AlcoholBlocker.py`.

> **Linux status:** the Linux implementation has **not been tested on real hardware in this project**. It is provided for educational, demonstration, theoretical, and experimental purposes only. Do not rely on it as a real screening or secure screen-locking system without your own validation.

Self-test:

```bash
python3 AlcoholBlocker.py --self-test
```

Normal UI run:

```bash
python3 AlcoholBlocker.py
```

Debug output without a file log:

```bash
python3 AlcoholBlocker.py --debug
```

Persistent file logging:

```bash
python3 AlcoholBlocker.py --debug --log
```

Cleanup:

```bash
python3 AlcoholBlocker.py --cleanup
```

---

# Windows

## Files

- `AlcoholGuard_36.ps1` — current Windows release artifact.
- `README.md` — project documentation.
- `LICENSE` — MIT license.
- `alco_sensor.ino` — Arduino sketch.

## Windows flags

| Flag | Purpose |
|---|---|
| no flag | Install/update the scheduled task and start a hidden `-Run` worker immediately |
| `-Run` | Start the runtime directly without changing Task Scheduler |
| `-SelfTest` | Run algorithm/configuration tests and exit |
| `-CleanUp` | Stop other runtime processes, remove the scheduled task, and remove AlcoholGuard-owned artifacts |
| `-DebugMode` | Print diagnostic messages to the console |
| `-Log` | Enable persistent `AlcoholGuard.log` file logging; off by default |

`-DebugMode` does **not** create a log file by itself. Persistent logging requires `-Log`.

## Windows launch examples

Normal install/start:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1
```

Install/start with console diagnostics:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -DebugMode
```

Install/start with persistent logs:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Log
```

Install/start with both diagnostics and persistent logs:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -DebugMode -Log
```

Direct runtime:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run
```

Direct runtime with diagnostics:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run -DebugMode
```

Direct runtime with diagnostics and logging:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run -DebugMode -Log
```

Self-test:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -SelfTest
```

Cleanup:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -CleanUp
```

## Windows startup pipeline

### Launch with no parameters

```text
AlcoholGuard.ps1
    |
    +--> create/update Scheduled Task: AlcoholBreathGuard
    |
    +--> create hidden launcher
    |
    +--> start hidden worker with -Run
    |
    +--> installer process exits
             |
             v
       fullscreen runtime
             |
             v
       find Arduino / CH340 automatically
             |
             v
       stabilize clean-air signal
             |
             v
       10-second calibration
       baseline = minimum observed calibration value
             |
             v
       waiting for breath
             |
             v
       breath registered
             |
             +--> reset next-check deadline from breath time
             |
             v
       3-second directional observation
             |
        +----+-------------------+
        |                        |
      sober                    alcohol
        |                        |
        v                        v
     unlock              keep screen blocked
                                  |
                                  v
                         reset next-check deadline
```

## Windows sensor discovery

The script does not hard-code `COM3` or `COM4`. It uses Windows PnP serial-device information and prioritizes common Arduino/USB-UART identifiers such as `CH340`, `CH341`, `Arduino`, `USB-SERIAL`, `FTDI`, and `CP210`.

The expected Arduino stream is:

- `9600` baud;
- one integer per line;
- raw ADC value `0..1023`.

## Windows stabilization and calibration

The current configuration is designed around the observed MQ-3 behavior used during development:

- clean-air ceiling: `150`;
- stabilization minimum: `5 seconds`;
- stabilization window: `50 samples` at the current polling cadence;
- maximum stabilization span: `6` raw ADC counts;
- maximum total drift: `3` counts;
- maximum downward steps in the stabilization window: `20`;
- calibration: `10 seconds`;
- baseline: **minimum value observed during the entire 10-second calibration**.

The minimum-based baseline is intentional. For a settled signal such as `44, 43, 44, 43, 44`, the baseline becomes `43` instead of `44`.

A sensor that is still drifting down is rejected even when it has already fallen below the `150` clean-air ceiling.

## Windows breath detection

Breath detection uses a fixed range around the current baseline:

```text
lower = baseline - 10
upper = baseline + 10
```

Both directions are supported because the observed sensor can react differently depending on the breath/test conditions.

A single out-of-range sample starts the observation. The observation window lasts **3 seconds**. The reading must show a directional change of at least `3` ADC counts and at least `2` steps in the same direction.

The UI derives the displayed observation time directly from the configuration, so the text does not become stale when the setting changes.

## Alcohol threshold

The project uses a simple raw-ADC rule:

```text
alcohol threshold = baseline + 200
```

with an ADC ceiling of `1023`.

This is deliberately a project-specific strong-response threshold, not a BAC or promille conversion.

When the alcohol threshold is reached during a confirmed breath observation, the state becomes `AlcoholDetected`, the screen remains blocked, and the next-check deadline is reset from the moment the alcohol event is registered.

## Passwords

There are two valid unlock passwords:

1. **Daily dynamic password:** current day + current month, always four digits, `DDMM`.
   - January 8 → `0801`.
   - August 1 → `0108`.
2. **Permanent backup password:** `1989`.

The daily password is recalculated at the moment the user submits the password. Therefore midnight is handled without restarting the program: after midnight, the new day's `DDMM` becomes valid immediately.

## Next-check scheduling

The `NEXT CHECK` field is updated at these points:

1. when stabilization succeeds, an initial one-hour deadline is created;
2. when a breath is registered, the one-hour deadline is recalculated from that breath timestamp;
3. if the breath is later classified as alcohol, the deadline is recalculated again from the moment the alcohol event is registered.

This means a long stabilization period does not consume the entire next-check interval.

The current automatic interval is **3600 seconds / 1 hour**.

## Refresh baseline & retest

The single control button performs:

```text
Refresh baseline & retest
    -> stabilization
    -> fresh 10-second calibration
    -> new minimum baseline
    -> new breath range
    -> new alcohol threshold
    -> WaitingForBreath
```

## Logging

Persistent logging is **disabled by default**.

- `-DebugMode` prints diagnostics to the console.
- `-Log` enables `%LOCALAPPDATA%\AlcoholGuard\AlcoholGuard.log`.
- `-DebugMode -Log` does both.

Cleanup removes the application's own log file and launcher artifacts. It does not attempt to erase Windows Event Logs or unrelated operating-system telemetry.

## Scheduled task and hidden startup

The installer creates the `AlcoholBreathGuard` task with an `AtLogOn` trigger. The scheduled task launches `wscript.exe`, which starts PowerShell with `-WindowStyle Hidden`. The intent is to avoid a normal PowerShell console/taskbar button being visible after reboot.

## Windows secure-lock limitation

The application is a user-session fullscreen kiosk overlay, not the Windows secure lock screen. A normal PowerShell/WinForms application cannot intercept `Ctrl+Alt+Del` like a real Windows credential/Winlogon screen.

The project therefore should not be presented as a security boundary.

---

# Linux

## Current Linux release

The current Linux release artifact is `AlcoholBlocker_36.py`.

> This implementation is **not tested on real hardware in this project**. It is an educational/theoretical port intended to demonstrate the same algorithm and UI concept on Linux.

## Linux dependencies

Typical dependencies are:

```bash
sudo pacman -S python-pyside6 python-pyserial
```

or the corresponding packages for another Linux distribution.

## Linux flags

| Flag | Purpose |
|---|---|
| no flag | Start the fullscreen Qt overlay |
| `--self-test` | Run algorithm tests and exit |
| `--debug` | Print diagnostics to the terminal |
| `--log` | Enable persistent log file writing |
| `--cleanup` | Stop/disable the user service and remove the application's own log/state file |

Persistent file logging is opt-in on Linux too.

## Linux examples

Normal run:

```bash
python3 AlcoholBlocker.py
```

Self-test:

```bash
python3 AlcoholBlocker.py --self-test
```

Debug:

```bash
python3 AlcoholBlocker.py --debug
```

Debug + persistent log:

```bash
python3 AlcoholBlocker.py --debug --log
```

Cleanup:

```bash
python3 AlcoholBlocker.py --cleanup
```

## Wayland limitation

On Wayland, application-level fullscreen overlays cannot reliably behave like a secure system lock screen. A normal Qt application is intentionally restricted from globally intercepting compositor-level shortcuts such as `Alt+Tab`, `Meta`, many `Ctrl+Alt+...` combinations, and other session-wide key sequences.

Therefore the Linux version should be treated as an experimental overlay, not as a secure OS lock. X11 and compositor/session-specific mechanisms can provide different behavior, but this project does not claim a universal secure-lock solution for Wayland.

---

# Arduino Uno R3 + MQ-3

## Arduino sketch

The Arduino only reads the MQ-3 analog output and sends the raw ADC value over serial. All stabilization, calibration, breath detection, and threshold logic happens on the computer.

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

The expected serial protocol is `9600` baud and one integer from `0` to `1023` per line.

## Uno R3 -> MQ-3 module

For a typical MQ-3 breakout with `VCC`, `GND`, `AO`, and optional `DO` pins:

```text
Arduino Uno R3        MQ-3 module
----------------      -----------
5V               ---> VCC
GND              ---> GND
A0               ---> AO
(anything)       ---  DO (not used)
```

`DO` is deliberately not used by ALCOBLOCKER. The computer-side algorithm works with the raw analog value from `AO`.

> MQ-3 breakout boards differ. Verify the silkscreen/pin labels and supply requirements of the exact module before wiring it.

## Why raw ADC values are used

The project intentionally works with raw ADC counts instead of claiming BAC/promille conversion. The exact response depends on the MQ-3 module, sensor warm-up, wiring, ADC reference, temperature, and other factors.

---

# MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software.

The only requirement is that the copyright notice and this permission notice are included in substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
