# AlcoLock

A breathalyzer-gated screen lock. An MQ-3 alcohol sensor connected to an
Arduino-compatible board feeds live readings over serial to a host-side
script, which locks the session whenever the reading exceeds a configured
threshold — and only unlocks it after a genuine, fresh, sober breath is
measured.

Two equivalent implementations are provided:

- **`alco_lock.ps1`** — PowerShell, for Windows (primary deployment target).
- **`alco_lock.py`** — Python, for Linux (see [Linux (Python) version](#linux-python-version)).

Both share the identical sensor-verification logic; only the OS-integration
pieces (screen lock, password prompt, autostart) differ.

> Personal self-discipline tool. Not a certified breathalyzer, not a legal
> sobriety test, and not a substitute for one.

## How it works

1. On startup, the script warms up the sensor and calibrates a **clean-air
   baseline** (average reading with no breath on the sensor).
2. It continuously watches the sensor. If a reading exceeds `$threshold`, the
   workstation is locked immediately.
3. To unlock, two things must happen in order:
   - **Re-arm**: the sensor chamber must clear back down close to baseline
     (residual alcohol vapor has to dissipate first).
   - **Fresh breath**: a genuine active breath is detected as a *sharp
     impulse* (a sudden jump in the reading), not just a slow decay curve from
     the previous test. The reading must then stay inside the sober corridor
     for `$soberTime` consecutive seconds.
4. If the breath sample exceeds the threshold, the counter resets and the
   cycle repeats.

This two-stage design exists specifically to prevent a false unlock from
residual vapor slowly clearing after one real (or simulated) breath — see
[Known limitations](#known-limitations) for the underlying failure mode this
avoids.

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

- PowerShell 7+ (`pwsh`) — developed and tested cross-platform (Linux for
  development/debugging, Windows for deployment).
- Windows is required for actual screen locking (`LockWorkStation`) and for
  autostart via Task Scheduler. On Linux, the script runs and logs normally
  but cannot lock the screen or self-install.

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
| `-Mode Normal\|Quiet`  | `Normal`: lock once immediately, verify sobriety, then exit. `Quiet` (default for real use): run continuously in the background and lock only when the threshold is exceeded. Default: `Normal`. |
| `-Debug` / `-d`        | Dry run. Skips autostart installation; logs what *would* lock/unlock instead of actually calling `LockWorkStation` or requiring a real password. |
| `-Port <name>`         | Force a specific serial port (`COM5`, `/dev/ttyACM0`, etc.), bypassing autodetection. |
| `-Cleanup` / `-DisableAutostart` | Fully remove the scheduled task and installed files, after confirming the master password. |
| `-Help` / `-h` / `-?`  | Print usage and examples, then exit — no sensor, autostart, or locking logic runs. |

### Examples

```powershell
# Normal use: background monitoring, real locking, autodetected port
.\alco_lock.ps1 -Mode Quiet

# Safe dry run: watch sensor + fake lock/unlock logs, no real locking
.\alco_lock.ps1 -Mode Quiet -Debug

# Force a specific port when multiple serial devices are connected
.\alco_lock.ps1 -Mode Quiet -Port COM5

# Test on Linux against a specific device node
.\alco_lock.ps1 -Port /dev/ttyACM0 -Debug

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
$masterPass = "..."  # Used only by -Cleanup to authorize uninstall
```

Also inside `Start-SoberVerificationLoop`:

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

- **No real Windows unlock is performed.** The script *locks* the session via
  `LockWorkStation`; the actual password entry to unlock Windows is still
  done by the user. AlcoLock only decides *when* to force that lock screen up
  and re-lock the session if you unlock before passing a breath test.
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
  serial link to the PC — it cannot emulate a keyboard. If you want the board
  itself to trigger `Win+L` without any host script running, you need a board
  with native USB HID (Leonardo, Micro, Pro Micro, Due, ESP32-S3, RP2040,
  etc.) and its own tradeoffs (antivirus/EDR may flag keystroke-injection
  capable USB devices).

## Linux (Python) version

`alco_lock.py` is a native Linux port with the same detection logic (identical
calibration, re-arm, and impulse-detection stages — including the fix for the
false-unlock-from-residual-vapor bug described above). System integration is
adapted to Linux equivalents instead of Windows APIs:

| Windows (`alco_lock.ps1`)        | Linux (`alco_lock.py`)                          |
|-----------------------------------|--------------------------------------------------|
| `rundll32 user32.dll,LockWorkStation` | `loginctl lock-session` (falls back to `xdg-screensaver`, `dm-tool`, `gnome-screensaver-command`, `cinnamon-screensaver-command`, or `xscreensaver-command` — whichever is available) |
| GUI password dialog (WinForms)   | Console prompt via `getpass`                      |
| Task Scheduler (`Normal`: hourly trigger, `Quiet`: at logon) | `systemd --user` timer (`alcolock.timer`, hourly) for `Normal`; `systemd --user` service (`alcolock.service`, `WantedBy=default.target`) for `Quiet` |
| `C:\ProgramData\AlcoLock`        | `~/.local/share/alcolock`                         |

### Requirements

- Python 3.8+
- [pyserial](https://pypi.org/project/pyserial/):
  ```bash
  pip install pyserial --break-system-packages
  ```

### Usage

```
alco_lock.py [--mode Normal|Quiet] [--debug] [--port <device>] [--cleanup]
```

Run `alco_lock.py --help` for the full list of options and examples.

```bash
# Normal use: background monitoring, real locking, autodetected port
python3 alco_lock.py --mode Quiet

# Safe dry run: watch sensor + fake lock/unlock logs, no real locking
python3 alco_lock.py --mode Quiet --debug

# Force a specific device when multiple serial adapters are connected
python3 alco_lock.py --mode Quiet --port /dev/ttyACM0

# Uninstall (removes the systemd unit(s) and installed files)
python3 alco_lock.py --cleanup
```

### Notes specific to the Linux version

- **Screen-lock command availability varies by desktop environment.** The
  script tries several common ones in order and logs a warning if none are
  found — check that at least one of them works on your system before
  relying on this for real (test with `--debug` off in a throwaway session
  first, or just run the lock command by hand to confirm it works).
- **Port autodetection** matches the same `Arduino`/`CH340`/`CH341`/
  `CP210x`/`FTDI`/`USB-SERIAL` description patterns as the Windows version,
  falling back to `/dev/ttyACM*` then `/dev/ttyUSB*` by device node.
- Self-install (`install_self`) writes to `~/.config/systemd/user/`, which
  requires a user systemd instance (the default on virtually all modern
  distros with systemd; not applicable on non-systemd init systems).

## Notifications and visibility

Both implementations now actively tell you what's happening instead of
silently locking and unlocking:

- **Desktop notifications** at every meaningful transition: why you were
  locked, live sensor readings while waiting for the chamber to clear,
  breath-test progress (`X/5 sec`), and the final success/failure/interrupted
  outcome. Windows uses a system tray balloon tip (`NotifyIcon`, no extra
  install needed); Linux uses `notify-send` if available.
- **Real lock-state detection**, instead of blindly re-issuing the lock
  command on every 0.5s poll: Windows checks whether `logonui.exe` (the
  process that draws the lock screen) is running; Linux checks
  `loginctl show-session $XDG_SESSION_ID -p LockedHint`. The script only
  re-locks (and re-notifies) when it detects you've actually gotten back to
  an unlocked desktop — which also happens to be the only moment a
  notification can render at all.
- **A persistent log file** (`alcolock.log` in the install directory) mirrors
  everything printed to the console, so the full process is reviewable
  afterward even when running invisibly in `Quiet` mode (as a hidden
  scheduled task / systemd service with no visible window).

### Why you can't see anything *during* the actual lock screen

This is an intentional OS security boundary, not a gap in the script: Windows
renders its lock screen on a separate **Secure Desktop**, and Linux screen
lockers run as their own isolated surface — neither lets an ordinary
process draw custom UI on top of them. So notifications only appear in the
brief window when you're genuinely back at your desktop (right before the
script re-locks it), not while the lock screen itself is showing. That
window is exactly when the "why am I locked again?" explanation is most
useful anyway.

### Linux-specific caveat: no locker daemon = no real lock

`loginctl lock-session` only sends a signal to systemd-logind saying "mark
this session as locked" — it does **not** draw a password screen by itself.
An actual lock screen only appears if a locker daemon (`light-locker`,
`gnome-screensaver`, `xscreensaver`, `i3lock` + a wrapper, etc.) is running
and subscribed to that signal. If none is installed/running, the session is
marked "locked" internally but nothing visually changes and there's no
password prompt to bypass — which is very likely what you're seeing if the
script appears to loop without ever asking for a password. Install and
enable one of the above for your desktop environment if you want a real,
enforced lock.

## GUI lock overlay (Linux)

Since Linux has no guaranteed equivalent of Windows' Secure Desktop lock
screen (see the locker-daemon caveat above), `alco_lock.py` enforces the
lock itself with its own always-on-top window, built with `tkinter`. This
window **is** the barrier - it opens whenever the threshold is exceeded, and
the only ways out are:

1. A genuine sober breath (the same re-arm + impulse-detection logic
   described above, running live and updating the window as it happens), or
2. Typing the master password into the field at the bottom of the window.

The window disables its own close button, stays topmost and fullscreen, and
also fires a best-effort real OS-level lock (`loginctl lock-session` etc.)
underneath as defense in depth, in case a locker daemon *is* present.

Requirements: `python3-tk` (usually a separate OS package from `python3`
itself):
```bash
sudo apt install python3-tk        # Debian/Ubuntu
sudo dnf install python3-tkinter   # Fedora
sudo pacman -S tk                  # Arch
```
If it's missing, the script falls back to console-only enforcement (same
behavior as before) rather than crashing.

### GUI + systemd caveat

A `systemd --user` service doesn't automatically inherit your graphical
session's `DISPLAY`/`XAUTHORITY`, which `tkinter` needs to open a window.
`install_self` captures these from the environment at install time and
bakes them into the generated `alcolock.service` unit, so run the install
step from your actual desktop session (not over a plain SSH connection
without X forwarding) for the GUI to work once installed. If the window
still doesn't appear after installing, check `alcolock.log` for a
`DISPLAY/XAUTHORITY` warning and re-run the install from your desktop.

## Uninstalling

```powershell
.\alco_lock.ps1 -Cleanup
```

Prompts for the master password, then removes the scheduled task and the
`C:\ProgramData\AlcoLock` directory.

## License

Personal project — add a license file if you plan to publish this publicly.
