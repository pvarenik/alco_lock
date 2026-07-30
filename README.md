# AlcoLock

A breathalyzer-gated screen lock for Windows/Linux. An MQ-3 alcohol sensor
connected to an Arduino-compatible board feeds live readings over serial to a
PowerShell script, which locks the workstation whenever the reading exceeds a
configured threshold — and only unlocks it after a genuine, fresh, sober
breath is measured.

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

## Uninstalling

```powershell
.\alco_lock.ps1 -Cleanup
```

Prompts for the master password, then removes the scheduled task and the
`C:\ProgramData\AlcoLock` directory.

## License

Personal project — add a license file if you plan to publish this publicly.
