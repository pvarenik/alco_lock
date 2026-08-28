# ALCOBLOCKER

Experimental desktop breath-check project built around an Arduino Uno R3 and MQ-3 analog gas sensor.

> **Important:** ALCOBLOCKER is not a certified breathalyzer, medical device, legal/forensic measurement device, or secure operating-system lock. It uses raw MQ-3 ADC values and project-specific thresholds.

## Quick start

### Windows

Run the self-test first:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -SelfTest
```

Install/start normally:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1
```

The no-parameter command creates/updates the `AlcoholBreathGuard` scheduled task and starts the hidden runtime immediately.

### Linux

> **Linux status:** the Linux implementation has **not been tested on real hardware in this project**. It is provided for educational, demonstration, theoretical, and experimental purposes only. Do not rely on it as a real screening system or secure lock without your own validation.

Install dependencies, then run:

```bash
python3 AlcoholBlocker.py
```

Self-test:

```bash
python3 AlcoholBlocker.py --self-test
```

---

# Windows

## Files

- `AlcoholGuard.ps1` — final Windows implementation.
- `README.md` — documentation.
- `LICENSE` — MIT license.
- `alco_sensor.ino` — Arduino/MQ-3 sketch.


## Flags

| Flag | Meaning |
|---|---|
| no flag | Install/update scheduled task and start hidden runtime |
| `-Run` | Run the guard directly without installing/updating the task |
| `-SelfTest` | Run built-in tests and exit |
| `-CleanUp` | Stop guard processes, remove scheduled task, and remove AlcoholGuard-owned artifacts |
| `-DebugMode` | Print diagnostic messages to the console |
| `-Log` | Enable persistent file logging; disabled by default |

Examples:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run -DebugMode
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -Run -DebugMode -Log
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -SelfTest
powershell.exe -ExecutionPolicy Bypass -File .\AlcoholGuard.ps1 -CleanUp
```

`-DebugMode` does not create a persistent log file. Use `-Log` when a file is required.

## Windows startup pipeline

```text
install/update task
       |
       v
hidden launcher
       |
       v
runtime starts with -Run
       |
       v
auto-detect Arduino / CH340
       |
       v
sensor stabilization
       |
       v
10-second calibration
baseline = minimum observed calibration value
       |
       v
waiting for breath
       |
       v
one out-of-range reading starts breath observation
       |
       v
3-second directional observation
       |
    +--+------------------+
    |                     |
  sober                 alcohol
    |                     |
    v                     v
unlock              keep blocked
```

## Serial sensor detection

The Windows implementation does not hard-code `COM3` or `COM4`. It searches Windows PnP serial devices and prioritizes Arduino/USB-UART identifiers such as `CH340`, `CH341`, `Arduino`, `USB-SERIAL`, `FTDI`, and `CP210`.

Expected stream:

- `9600` baud;
- one integer per line;
- raw ADC `0..1023`.

## Stabilization and calibration

Current tuning:

- clean-air ceiling: `150`;
- stabilization minimum: `5 seconds`;
- stabilization window: `50 samples`;
- maximum stabilization span: `6` ADC counts;
- maximum total drift: `3` counts;
- maximum downward steps: `20`;
- calibration: `10 seconds`;
- baseline: **minimum value observed during the complete calibration**.

A slowly falling signal is treated as sensor settling rather than clean air. When the sensor is abnormally high, the UI asks the user to reconnect the sensor or touch it by hand.

## Breath detection

The current fixed breath range is:

```text
lower = baseline - 10
upper = baseline + 10
```

Both upward and downward responses are supported.

One sample outside the range starts a breath observation. The observation lasts `3 seconds` and needs a directional change of at least `3` ADC counts with at least `2` same-direction steps.

The UI displays the real configured observation duration.

## Alcohol threshold

The strong-response threshold is:

```text
alcohol threshold = baseline + 200
```

capped at ADC maximum `1023`.

This is a raw project threshold, not a BAC/promille conversion.

When the threshold is reached, the state becomes `AlcoholDetected` and the screen remains blocked until another allowed unlock path or scheduled check.

## Passwords

Two passwords are accepted:

- **Daily password:** local date in `DDMM` format. Examples: `01 August -> 0108`, `9 August -> 0908`.
- **Backup password:** `1989`, always valid.

The daily password is recalculated at the moment of submission, so crossing midnight immediately changes the valid daily password.

## Next check

The automatic interval is **3600 seconds / 1 hour**.

The `NEXT CHECK` deadline is refreshed when the relevant event occurs:

- after stabilization establishes the current cycle;
- when a breath is registered;
- when a breath is classified as alcohol;
- after successful password unlock.

The time is written to the console in debug mode and to the persistent log only when `-Log` is enabled.

## Refresh baseline & retest

The single button performs:

```text
stabilization
    -> 10-second calibration
    -> new minimum baseline
    -> new breath range
    -> new alcohol threshold
    -> waiting for breath
```

## Help

Press `Shift+/` on an English keyboard or `Shift+7` on a Russian keyboard to cycle through detailed help hints in the UI.

There is no emergency/unlock hotkey.

## Logging

No persistent log is written by default.

- `-DebugMode` -> console diagnostics.
- `-Log` -> `%LOCALAPPDATA%\AlcoholGuard\AlcoholGuard.log`.
- `-DebugMode -Log` -> both.

Cleanup removes the application's own log and launcher artifacts. It does not attempt to erase Windows Event Logs or unrelated OS telemetry.

## Scheduled task and hidden startup

The scheduled task uses an `AtLogOn` trigger. The task launches `wscript.exe`, which starts PowerShell with `-WindowStyle Hidden`, so the worker is intended to run without a normal PowerShell console on the taskbar.

## Windows security limitation

This is a fullscreen user-session overlay, not the secure Windows credential/Winlogon screen. It cannot provide the security guarantees of the real Windows lock screen.

---

# Linux

## Current implementation

The final Linux source is `AlcoholBlocker.py`.

> **Testing status:** this Linux implementation has **not been tested on real hardware in this project**. It is an educational/theoretical/experimental port. Behavior, serial-device handling, fullscreen behavior, and especially lock semantics should be validated on the target machine before practical use.

## Dependencies

Arch Linux example:

```bash
sudo pacman -S python-pyside6 python-pyserial
```

## Linux flags

```text
(no flag)   start the fullscreen application
--self-test run built-in tests
--debug    print diagnostics
--log      write a persistent log
--cleanup  stop/disable the user service and remove application-owned log/state
```

Examples:

```bash
python3 AlcoholBlocker.py
python3 AlcoholBlocker.py --self-test
python3 AlcoholBlocker.py --debug
python3 AlcoholBlocker.py --debug --log
python3 AlcoholBlocker.py --cleanup
```

Linux logging is also opt-in.

## systemd user service

The repository includes `alcoblocker.service`. It uses the stable, unversioned path `~/.local/bin/AlcoholBlocker.py`.

Install:

```bash
mkdir -p ~/.local/bin ~/.config/systemd/user
cp AlcoholBlocker.py ~/.local/bin/AlcoholBlocker.py
cp alcoblocker.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now alcoblocker.service
```

Check:

```bash
systemctl --user status alcoblocker.service
```

View service output:

```bash
journalctl --user -u alcoblocker.service -f
```

Stop/disable:

```bash
systemctl --user disable --now alcoblocker.service
```

After updating the program:

```bash
cp AlcoholBlocker.py ~/.local/bin/AlcoholBlocker.py
systemctl --user restart alcoblocker.service
```

## Linux algorithm

The Linux port follows the same project parameters as the final Windows implementation:

- clean-air ceiling `150`;
- `5` second / `50` sample stabilization window;
- `10` second minimum-value calibration;
- breath range `baseline +/- 10`;
- `3` second breath observation;
- minimum directional change `3` with `2` same-direction steps;
- alcohol threshold `baseline + 200` capped at `1023`;
- automatic check interval `3600` seconds.

It also supports the dynamic `DDMM` password and permanent backup password `1989`.

## Wayland limitation

Wayland deliberately restricts applications from acting as universal secure lock screens or intercepting compositor-level shortcuts. A normal Qt application cannot reliably provide the same global keyboard interception as a real OS lock screen.

Therefore the Linux implementation should be considered an experimental fullscreen overlay rather than a secure system lock.

---

# Arduino Uno R3 + MQ-3

## Sketch

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

## Wiring

Typical MQ-3 module:

```text
Arduino Uno R3      MQ-3
----------------    --------
5V              ->  VCC
GND             ->  GND
A0              ->  AO
                    DO not used
```

The software intentionally uses the analog output `AO`; the digital output `DO` is not used.

## Raw ADC values

The project deliberately works with raw ADC values. MQ-3 readings depend on the particular module, warm-up state, wiring, environment, and hardware configuration, so raw values are not treated as BAC or promille.

---

# MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
