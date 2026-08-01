# AlcoLock

A breathalyzer-gated action blocker. An MQ-3 alcohol sensor connected to an
Arduino-compatible board feeds live readings over serial to a host-side
script, which throws up a fullscreen, always-on-top window whenever the
reading exceeds a configured threshold — and only lets you back in after a
genuine, fresh, sober breath is measured (or you type a master password).

Two equivalent implementations are provided:

- **`alco_lock.ps1`** — PowerShell, for Windows.
- **`alco_lock.py`** — Python, for Linux (see [Linux (Python) version](#linux-python-version)).

Both share the identical sensor-verification logic; only the OS-integration
pieces (the overlay's GUI toolkit, autostart mechanism) differ.

> Personal joke/self-discipline project: a device that blocks a drunk person
> from using their own computer. Not a certified breathalyzer, not a legal
> sobriety test, and not a substitute for one.

## How it works

1. On startup, the script warms up the sensor and calibrates a **clean-air
   baseline** (average reading with no breath on the sensor).
2. It continuously watches the sensor. If a reading exceeds `$threshold`, a
   **fullscreen window opens on top of everything else** — borderless, no
   close button, always-on-top.
3. To make it go away, two things must happen in order:
   - **Re-arm**: the sensor chamber must clear back down close to baseline
     (residual alcohol vapor has to dissipate first).
   - **Fresh breath**: a genuine active breath is detected as a *sharp
     impulse* (a sudden jump in the reading), not just a slow decay curve from
     the previous test. The reading must then stay inside the sober corridor
     for `$soberTime` consecutive seconds.
4. If the breath sample exceeds the threshold, the counter resets and the
   cycle repeats — all shown live in the window (current reading, what stage
   you're in, countdown progress).
5. At any point, typing the correct **master password** into the field at
   the bottom of the window closes it immediately, bypassing the breath
   check entirely.

This two-stage sensor design (re-arm + impulse, not just re-arm) exists
specifically to prevent a false unlock from residual vapor slowly clearing
after one real (or simulated) breath — see
[Known limitations](#known-limitations) for the underlying failure mode this
avoids.

### Why an app window instead of a real OS lock

Earlier versions of this project called the real OS session lock
(`LockWorkStation` on Windows, `loginctl lock-session` on Linux). That turned
out to be the wrong tool for the job:

- It hands the actual unlock step over to the **Windows/Linux account
  password**, which has nothing to do with this project and isn't something
  you want a script fighting you over.
- Windows' lock screen runs on an isolated **Secure Desktop** that no
  ordinary process can draw custom UI on top of — so there was no way to
  show live sensor readings, timers, or a reason while it was up.
- On Linux, a real lock only happens if a locker daemon is installed and
  listening for the signal; otherwise `loginctl lock-session` is a no-op
  that looks like it worked but doesn't.
- Worst of all: nothing stopped the verification loop from calling the real
  lock again 0.5 seconds after you legitimately logged back in, with no
  explanation - which looked exactly like a broken infinite lock loop.

So this project doesn't touch the OS session lock at all anymore. The
fullscreen window **is** the entire mechanism: an ordinary top-level
application window, deliberately configured to be hard to ignore (no
border, no close button, always-on-top, covers the whole screen), that
your own script fully controls and can show anything in.

This is *not* a hardened kiosk lock. It doesn't install keyboard hooks and
doesn't try to block Task Manager, Ctrl+Alt+Del, or the Windows/Super key -
a determined user (i.e., you, five minutes from now) can always get out via
Task Manager / `pkill`. That's intentional: this is a personal joke device,
not something that should risk trapping you with no way out if it ever hits
a bug.

## Hardware

- Arduino Uno or a compatible clone (tested with ATmega328 + CH340 USB-serial
  chip).
- MQ-3 alcohol gas sensor module, analog output wired to an analog input pin.
- The board must stream numeric ADC readings, one integer per line, over
  serial at 9600 baud (default `$baudRate`). Any simple sketch that reads the
  analog pin and does `Serial.println(value)` in a loop is sufficient.

Sensor firmware itself is not included in this repo — this project covers the
host-side (PC) logic only.

## Requirements

**Windows (`alco_lock.ps1`):**
- PowerShell 7+ (`pwsh`), or Windows PowerShell 5.1.
- `System.Windows.Forms` / `System.Drawing` (built into .NET on Windows,
  loaded automatically - nothing extra to install).

**Linux (`alco_lock.py`):** see [Requirements](#requirements-1) under the
Linux section below.

## Installation

1. Wire up the MQ-3 sensor to your board and flash a sketch that streams
   readings over serial.
2. Copy `alco_lock.ps1` anywhere on the target Windows machine.
3. Run it once manually:
   ```powershell
   .\alco_lock.ps1 -Mode Quiet
   ```
   On first run (without `-Debug`), the script will:
   - Re-launch itself elevated (UAC prompt) if not already running as
     Administrator.
   - Copy itself to `C:\ProgramData\AlcoLock\alco_lock.ps1`.
   - Register a Scheduled Task (`AlcoLockSystem`) that runs at logon under the
     `SYSTEM` account.

From then on, it starts automatically every time you log in.

## Usage

```
.\alco_lock.ps1 [-Mode Normal|Quiet] [-Debug] [-Port <name>] [-Cleanup] [-Help]
```

Run `.\alco_lock.ps1 -Help` at any time for a summary with examples directly
in the console, or `Get-Help .\alco_lock.ps1 -Full` for the complete
PowerShell help reference.

| Parameter            | Description |
|-----------------------|-------------|
| `-Mode Normal\|Quiet`  | `Normal`: show the overlay once immediately, verify sobriety, then exit. `Quiet` (default for real use): run continuously in the background and only show the overlay when the threshold is exceeded. Default: `Normal`. |
| `-Debug` / `-d`        | Skips autostart installation and the `-Cleanup` password prompt. The overlay itself always runs the same either way - it's an app window, not a real OS lock, so it's always safe to test. |
| `-Port <name>`         | Force a specific serial port (`COM5`, `/dev/ttyACM0`, etc.), bypassing autodetection. |
| `-Cleanup` / `-DisableAutostart` | Fully remove the scheduled task and installed files, after confirming the master password. |
| `-Help` / `-h` / `-?`  | Print usage and examples, then exit — no sensor, autostart, or overlay logic runs. |

### Examples

```powershell
# Normal use: background monitoring, autodetected port
.\alco_lock.ps1 -Mode Quiet

# Test the overlay without installing autostart
.\alco_lock.ps1 -Mode Quiet -Debug

# Force a specific port when multiple serial devices are connected
.\alco_lock.ps1 -Mode Quiet -Port COM5

# Uninstall
.\alco_lock.ps1 -Cleanup
```

## Serial port autodetection

The script tries, in order:

1. `-Port` override, if given.
2. **Windows**: query `Win32_PnPEntity` for a device name containing
   `Arduino`, `CH340`/`CH341`, `CP210x`, `USB-SERIAL`, or `FTDI`, and extract
   its COM number.
3. **Windows fallback**: the first port returned by
   `[System.IO.Ports.SerialPort]::GetPortNames()`.
4. **Linux**: `/dev/ttyACM*` first (native USB CDC, as on Uno/Leonardo-class
   boards), then `/dev/ttyUSB*` (USB-UART adapters).

If nothing is found, it retries a few times (useful right after logon, before
USB enumeration finishes) before giving up with an explicit error message
telling you to plug in the device or pass `-Port` manually.

## Configuration

All tunables live at the top of the script:

```powershell
$threshold  = 350   # Raw ADC reading that counts as "alcohol detected"
$soberTime  = 5     # Consecutive seconds within the sober range to unlock
$warmupSec  = 10    # Sensor warmup/calibration duration on startup
$masterPass = "..."  # Bypasses the overlay entirely when typed into it
```

Also inside `Show-VerificationOverlay`:

```powershell
$rearmThreshold = $baselineVal + 40  # Chamber must clear below this to re-arm
$minBlowingVal  = $baselineVal + 10  # Floor of the valid breath corridor
$deltaTrigger   = 15                 # Minimum jump to count as a real breath impulse
```

These thresholds depend heavily on your specific MQ-3 unit, its warmup time,
and ambient conditions — expect to tune them after a few real test runs.

> ⚠️ `$masterPass` is a hardcoded plaintext string in the script. Anyone with
> read access to the file (or to `C:\ProgramData\AlcoLock\alco_lock.ps1`) can
> read it. Treat this as a soft speed bump against casual bypass, not a real
> access control — change the default before relying on it for anything.

## Known limitations

- **This is an app-level window, not a real OS lock — on purpose** (see
  [Why an app window instead of a real OS lock](#why-an-app-window-instead-of-a-real-os-lock)
  above). A determined user can always exit via Task Manager, killing the
  process, or similar. That's an accepted tradeoff for a personal joke
  device with no hard-lockout risk, not an oversight.
- **False-unlock from residual vapor**: earlier versions of this script could
  misinterpret a slowly-clearing sensor reading (left over from a previous
  breath) as a fresh sober breath, because the impulse-detection baseline was
  reset to a stale calibration value instead of the sensor's actual last
  reading. This is fixed in the current version, but if you fork/modify the
  breath-detection logic, be careful not to reintroduce it.
- **MQ-3 sensors need real warmup time.** 10 seconds is a placeholder for
  quick testing; real MQ-series sensors are commonly specified with warmup
  times in the range of minutes for a stable baseline. Tune `$warmupSec` for
  your hardware.
- **No native USB HID.** A plain Uno/ATmega328 + CH340 board only has a
  serial link to the PC — it cannot emulate a keyboard, so the board itself
  can't trigger anything on its own; the host script is what shows the
  overlay.

## Linux (Python) version

`alco_lock.py` is a native Linux port with the same detection logic (identical
calibration, re-arm, and impulse-detection stages — including the fix for the
false-unlock-from-residual-vapor bug described above). System integration is
adapted to Linux equivalents instead of Windows APIs:

| Windows (`alco_lock.ps1`)        | Linux (`alco_lock.py`)                          |
|-----------------------------------|--------------------------------------------------|
| Fullscreen overlay via `System.Windows.Forms` | Fullscreen overlay via `tkinter` |
| Task Scheduler (`Normal`: hourly trigger, `Quiet`: at logon) | `systemd --user` timer (`alcolock.timer`, hourly) for `Normal`; `systemd --user` service (`alcolock.service`, `WantedBy=default.target`) for `Quiet` |
| `C:\ProgramData\AlcoLock`        | `~/.local/share/alcolock`                         |

### Requirements

- Python 3.8+
- [pyserial](https://pypi.org/project/pyserial/):
  ```bash
  pip install pyserial --break-system-packages
  ```
- `python3-tk`, for the GUI overlay (usually a separate OS package from
  `python3` itself):
  ```bash
  sudo apt install python3-tk        # Debian/Ubuntu
  sudo dnf install python3-tkinter   # Fedora
  sudo pacman -S tk                  # Arch
  ```
  If it's missing, the script falls back to console-only logging (plus a
  single `notify-send` alert, if available) instead of crashing - but you
  lose the actual blocking window, which defeats the point. Install it for
  real use.

### Usage

```
alco_lock.py [--mode Normal|Quiet] [--debug] [--port <device>] [--cleanup]
```

Run `alco_lock.py --help` for the full list of options and examples.

```bash
# Normal use: background monitoring, autodetected port
python3 alco_lock.py --mode Quiet

# Test the overlay without installing autostart
python3 alco_lock.py --mode Quiet --debug

# Force a specific device when multiple serial adapters are connected
python3 alco_lock.py --mode Quiet --port /dev/ttyACM0

# Uninstall (removes the systemd unit(s) and installed files)
python3 alco_lock.py --cleanup
```

### Notes specific to the Linux version

- **Port autodetection** matches the same `Arduino`/`CH340`/`CH341`/
  `CP210x`/`FTDI`/`USB-SERIAL` description patterns as the Windows version,
  falling back to `/dev/ttyACM*` then `/dev/ttyUSB*` by device node.
- Self-install (`install_self`) writes to `~/.config/systemd/user/`, which
  requires a user systemd instance (the default on virtually all modern
  distros with systemd; not applicable on non-systemd init systems).
- **GUI + systemd caveat**: a `systemd --user` service doesn't automatically
  inherit your graphical session's `DISPLAY`/`XAUTHORITY`, which `tkinter`
  needs to open a window. `install_self` captures these from the environment
  at install time and bakes them into the generated `alcolock.service` unit,
  so run the install step from your actual desktop session (not over a
  plain SSH connection without X forwarding). If the window still doesn't
  appear after installing, check `alcolock.log` for a warning and re-run the
  install from your desktop.

## Logging

Both versions write a persistent, plain-text log (`alcolock.log`, in the
install directory) mirroring everything printed to the console, so the
whole process is reviewable afterward even when running invisibly in
`Quiet` mode (as a hidden scheduled task / systemd service with no visible
console window).

## Uninstalling

```powershell
.\alco_lock.ps1 -Cleanup
```

Prompts for the master password, then removes the scheduled task and the
`C:\ProgramData\AlcoLock` directory. On Linux, the equivalent is
`python3 alco_lock.py --cleanup`.

## License

Personal project — add a license file if you plan to publish this publicly.
