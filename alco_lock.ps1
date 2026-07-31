<#
.SYNOPSIS
    Breathalyzer-based screen lock. Locks the workstation until a sober breath
    is confirmed by an MQ-3 alcohol sensor connected via an Arduino-compatible board.

.DESCRIPTION
    Reads sensor readings from a serial port (Arduino/MQ-3), calibrates a clean-air
    baseline on startup, and locks the workstation whenever the reading exceeds the
    configured threshold. Access is restored only after a genuine fresh breath
    (detected as a sharp impulse, not just a slowly-clearing residual reading)
    stays within the sober range for several consecutive seconds.

    Modes:
      Normal - locks once immediately, verifies sobriety, then exits (meant to be
               re-triggered hourly by Task Scheduler).
      Quiet  - stays running in the background, silently monitoring the sensor,
               and only locks when the threshold is actually exceeded.

.PARAMETER Mode
    Normal or Quiet. See DESCRIPTION. Default: Normal.

.PARAMETER Debug
    Alias -d. Dry-run mode: skips autostart installation and does not actually
    call LockWorkStation or require a real master password - just logs what
    would have happened. Use this for testing without an installed sensor rig.

.PARAMETER Cleanup
    Removes the scheduled task and the installed copy in C:\ProgramData\AlcoLock
    after confirming the master password.

.PARAMETER DisableAutostart
    Same effect as -Cleanup (kept as a separate, more descriptive alias).

.PARAMETER Port
    Manually specify the serial port, bypassing autodetection.
    Example: -Port COM5 (Windows) or -Port /dev/ttyACM0 (Linux).

.PARAMETER Help
    Alias -h, -?. Prints this usage summary with examples and exits immediately,
    without touching the sensor, autostart, or any locking logic.

.EXAMPLE
    .\alco_lock.ps1
    Runs in Normal mode with autodetected port. Locks immediately, waits for a
    sober breath, then exits.

.EXAMPLE
    .\alco_lock.ps1 -Mode Quiet
    Runs continuously in the background, only locking when alcohol is detected.
    This is the mode installed at logon by the scheduled task.

.EXAMPLE
    .\alco_lock.ps1 -Mode Quiet -Debug
    Safe dry run: background monitoring with fake locking (logs only), useful
    for testing sensor behavior and thresholds without locking your own session.

.EXAMPLE
    .\alco_lock.ps1 -Mode Quiet -Port COM5
    Forces a specific COM port instead of relying on autodetection - useful when
    multiple serial devices are connected at once.

.EXAMPLE
    .\alco_lock.ps1 -Cleanup
    Prompts for the master password and, if correct, fully removes AlcoLock
    (scheduled task + installed files) from the system.

.EXAMPLE
    .\alco_lock.ps1 -Help
    Shows this same summary directly in the console, without invoking Get-Help.

.NOTES
    Full parameter reference: Get-Help .\alco_lock.ps1 -Full
#>

param(
    [ValidateSet("Normal", "Quiet")]
    [string]$Mode = "Normal",
    
    [Alias("d")]
    [switch]$Debug,

    [switch]$Cleanup,
    [switch]$DisableAutostart,

    # Manual port override (takes priority over autodetection). Example: -Port COM5 or -Port /dev/ttyACM0
    [string]$Port = "",

    [Alias("h","?")]
    [switch]$Help
)

if ($Help) {
    Write-Host @"

AlcoLock - breathalyzer-based screen lock
==========================================

USAGE:
  .\alco_lock.ps1 [-Mode Normal|Quiet] [-Debug] [-Port <name>] [-Cleanup] [-Help]

PARAMETERS:
  -Mode <Normal|Quiet>   Normal: lock once, verify, exit (default).
                         Quiet: run continuously in the background.
  -Debug (-d)            Dry run - logs actions instead of actually locking
                         the screen or requiring a real password.
  -Port <name>           Force a specific serial port (e.g. COM5 or
                         /dev/ttyACM0), skipping autodetection.
  -Cleanup               Remove the scheduled task and installed files
                         (asks for the master password first).
  -DisableAutostart      Same as -Cleanup.
  -Help (-h, -?)         Show this help and exit.

EXAMPLES:
  .\alco_lock.ps1
      Normal mode, autodetected port.

  .\alco_lock.ps1 -Mode Quiet
      Background monitoring mode (what runs at logon via Task Scheduler).

  .\alco_lock.ps1 -Mode Quiet -Debug
      Safe dry run: watch the sensor and simulated lock/unlock logs without
      actually locking your session.

  .\alco_lock.ps1 -Mode Quiet -Port COM5
      Force COM5 instead of autodetecting.

  .\alco_lock.ps1 -Port /dev/ttyACM0 -Debug
      Test on Linux against a specific device node.

  .\alco_lock.ps1 -Cleanup
      Fully uninstall (prompts for the master password).

For the full parameter reference, run:
  Get-Help .\alco_lock.ps1 -Full

"@ -ForegroundColor Cyan
    exit
}

# ================= SETTINGS =================
# Port is detected automatically (see Find-SerialPort below).
# To set it manually, use the launch parameter: -Port COM5  or  -Port /dev/ttyACM0
$portRetryAttempts = 6     # Port detection attempts at startup (useful for logon autostart)
$portRetryDelaySec  = 2

$baudRate   = 9600
$threshold  = 350             # Alcohol trigger threshold
$masterPass = "SuperSecret123" # HARDCODED MASTER PASSWORD
$taskName   = "AlcoLockSystem" # Task name in Windows Task Scheduler
$soberTime  = 5                # Seconds of continuous sober breath required
$warmupSec  = 10               # Seconds of clean-air calibration at startup
$installDir = "C:\ProgramData\AlcoLock"
# =============================================

if ($env:OS -eq "Windows_NT") {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
}

# --- DEBUG LOG OUTPUT ---
function Write-Log {
    param([string]$message, [string]$color = "Gray")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [$Mode-Mode] $message" -ForegroundColor $color
}

# --- SERIAL PORT AUTODETECTION ---
function Find-SerialPort {
    param([string]$override = "")

    if ($override) {
        Write-Log "Port manually set via -Port: $override" "Cyan"
        return $override
    }

    if ($env:OS -eq "Windows_NT") {
        # 1) Try to find the port by device description (real Arduino Uno chip and clones)
        try {
            $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                Where-Object { $_.Name -match '\(COM\d+\)' }

            $known = @($devices | Where-Object {
                $_.Name -match 'Arduino' -or $_.Name -match 'CH340' -or $_.Name -match 'CH341' -or
                $_.Name -match 'USB-SERIAL' -or $_.Name -match 'CP210' -or $_.Name -match 'FTDI'
            })

            if ($known.Count -gt 1) {
                Write-Log "Multiple matching devices found, using the first one. If it's wrong, set the port manually (-Port):" "Yellow"
                $known | ForEach-Object { Write-Log "  - $($_.Name)" "Yellow" }
            }

            if ($known.Count -ge 1 -and $known[0].Name -match '\((COM\d+)\)') {
                Write-Log "Autodetect (Windows): found device '$($known[0].Name)' -> $($matches[1])" "Green"
                return $matches[1]
            }
        } catch {
            Write-Log "Failed to query devices via WMI/CIM: $_" "Yellow"
        }

        # 2) Fallback: no exact match found - take the first available COM port
        $ports = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
        if ($ports.Count -gt 1) {
            Write-Log "Multiple COM ports available ($($ports -join ', ')), using the first: $($ports[0]). If it's wrong, set -Port manually." "Yellow"
        }
        if ($ports.Count -ge 1) {
            Write-Log "Autodetect (Windows, fallback): $($ports[0])" "Green"
            return $ports[0]
        }

        return $null
    }
    else {
        # Linux: prioritize ttyACM (native USB CDC, as on Uno/Leonardo), then ttyUSB (USB-UART adapters)
        $candidates = @()
        $candidates += Get-ChildItem -Path /dev -Filter "ttyACM*" -ErrorAction SilentlyContinue
        $candidates += Get-ChildItem -Path /dev -Filter "ttyUSB*" -ErrorAction SilentlyContinue

        if ($candidates.Count -gt 1) {
            Write-Log "Multiple devices found ($($candidates.FullName -join ', ')), using the first one. If it's wrong, set -Port manually." "Yellow"
        }
        if ($candidates.Count -ge 1) {
            Write-Log "Autodetect (Linux): $($candidates[0].FullName)" "Green"
            return $candidates[0].FullName
        }

        return $null
    }
}

function Resolve-SerialPort {
    param([string]$override = "")

    for ($attempt = 1; $attempt -le $portRetryAttempts; $attempt++) {
        $found = Find-SerialPort -override $override
        if ($found) { return $found }

        Write-Log "Port not found (attempt $attempt/$portRetryAttempts). Retrying in $portRetryDelaySec sec..." "Yellow"
        Start-Sleep -Seconds $portRetryDelaySec
    }

    throw "Could not find a serial port after $portRetryAttempts attempts. Connect the device or set the port manually: -Port COM5 (Windows) / -Port /dev/ttyACM0 (Linux)."
}

# --- UI AND LOCKING FUNCTIONS ---
function Show-PasswordDialog {
    param([string]$promptTitle, [string]$promptText)
    
    if ($Debug) {
        Write-Log "[DEBUG] Password dialog skipped (Debug active). Returning $null." "Yellow"
        return $null
    }

    if ($env:OS -ne "Windows_NT") {
        Write-Log "[WARNING] GUI unavailable. Enter the password in the console:" "Yellow"
        return Read-Host "Master password"
    }
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $promptTitle
    $form.Size = New-Object System.Drawing.Size(350,160)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,10)
    $label.Size = New-Object System.Drawing.Size(310,30)
    $label.Text = $promptText
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(10,45)
    $textBox.Size = New-Object System.Drawing.Size(310,20)
    $textBox.UseSystemPasswordChar = $true
    $form.Controls.Add($textBox)

    $button = New-Object System.Windows.Forms.Button
    $button.Location = New-Object System.Drawing.Point(120,80)
    $button.Size = New-Object System.Drawing.Size(100,25)
    $button.Text = "OK"
    $button.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $button
    $form.Controls.Add($button)

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text
    }
    return $null
}

function Invoke-LockPC {
    if ($Debug) {
        Write-Log "[DEBUG] >>> SYSTEM LOCK CALL (LockWorkStation) <<<" "Red"
    } else {
        if ($env:OS -eq "Windows_NT") {
            rundll32.exe user32.dll,LockWorkStation
        } else {
            Write-Log "[WARNING] Screen lock is not supported on this OS." "Yellow"
        }
    }
}

# --- REMOVAL AND FULL CLEANUP ---
function Remove-AlcoLock {
    Write-Log "Requesting cleanup and system shutdown..." "Yellow"
    
    $inputPass = Show-PasswordDialog -promptTitle "Remove AlcoLock" -promptText "Enter the master password for full cleanup:"
    if ($inputPass -eq $masterPass) {
        try {
            if ($env:OS -eq "Windows_NT") {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                if (Test-Path $installDir) { Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue }
                [System.Windows.Forms.MessageBox]::Show("AlcoLock has been completely removed from the system!", "Success", 0, 64)
            } else {
                Write-Log "Task and files cleaned up." "Green"
            }
        }
        catch {
            Write-Log "Error during removal: $_" "Red"
        }
    } else {
        if ($env:OS -eq "Windows_NT") {
            [System.Windows.Forms.MessageBox]::Show("Incorrect master password!", "Access Denied", 0, 48)
        } else {
            Write-Log "Incorrect master password!" "Red"
        }
    }
}

# --- SELF-INSTALL TO AUTOSTART ---
function Install-Self {
    if ($Debug) {
        Write-Log "[DEBUG] Skipping autostart (-Debug active)." "Cyan"
        return
    }

    if ($env:OS -ne "Windows_NT") { return }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $powershell = (Get-Command powershell).Source
        Start-Process $powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode" -Verb RunAs
        exit
    }

    if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir | Out-Null }
    $targetPath = Join-Path $installDir "alco_lock.ps1"
    Copy-Item -Path $PSCommandPath -Destination $targetPath -Force

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$targetPath`" -Mode $Mode"
    
    if ($Mode -eq "Normal") {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1)
    } else {
        $trigger = New-ScheduledTaskTrigger -AtLogOn
    }
    
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User "SYSTEM" -Force | Out-Null
}

# --- CLEANUP HANDLING ---
if ($Cleanup -or $DisableAutostart) {
    Remove-AlcoLock
    exit
}

Install-Self

# --- STARTUP CALIBRATION AND WARMUP ---
function Initialize-Baseline {
    param([System.IO.Ports.SerialPort]$serialPort)

    Write-Log "Initializing sensor: starting calibration and warmup ($warmupSec sec)..." "Yellow"

    try { $serialPort.DiscardInBuffer() } catch {}

    $samples = [System.Collections.Generic.List[int]]::new()
    $startTime = [DateTime]::Now

    while (([DateTime]::Now - $startTime).TotalSeconds -lt $warmupSec) {
        try {
            $line = $serialPort.ReadLine().Trim()
            if ($line -match '^\d+$') {
                [int]$val = $line
                # Filter out buffer glitches and anomalies (> 500)
                if ($val -lt 500) {
                    $samples.Add($val)
                    Write-Log "Startup calibration: $val (samples: $($samples.Count))" "DarkGray"
                } else {
                    Write-Log "Skipped anomalous spike: $val" "Yellow"
                }
            }
        } catch {
            Write-Log "Error reading during calibration!" "Red"
        }
        Start-Sleep -Milliseconds 500
    }

    $baselineVal = 80 # Default fallback

    if ($samples.Count -gt 0) {
        # Take the second half of the samples (once the sensor has stabilized)
        $halfIndex = [math]::Floor($samples.Count / 2)
        $stableSamples = $samples.GetRange($halfIndex, $samples.Count - $halfIndex)
        
        $sum = 0
        foreach ($s in $stableSamples) { $sum += $s }
        $baselineVal = [math]::Round($sum / $stableSamples.Count)
    }

    Write-Log "Calibration complete! Clean air baseline value: $baselineVal" "Green"
    return $baselineVal
}

# --- SHARED BREATH-TEST AND VALIDATION LOGIC ---
function Start-SoberVerificationLoop {
    param(
        [System.IO.Ports.SerialPort]$serialPort,
        [int]$baselineVal
    )

    try { $serialPort.DiscardInBuffer() } catch {}

    $rearmThreshold = $baselineVal + 40   # Level the chamber must drop below to be considered clear
    $minBlowingVal  = $baselineVal + 10   # Minimum level for a clean breath
    $deltaTrigger   = 15                  # Minimum sharp jump (+15) to detect an impulse

    # ---------------------------------------------------------
    # STAGE 1: Waiting for the sensor chamber to clear of previous vapors (Re-arm)
    # ---------------------------------------------------------
    Write-Log "LOCKED! Waiting for the sensor chamber to clear (value must drop below $rearmThreshold)..." "Red"

    # Remember the actual last sensor value from the clearing stage,
    # so we don't "inherit" a stale baseline when moving to Stage 2
    $lastRearmVal = $baselineVal

    while ($true) {
        Invoke-LockPC
        try {
            $line = $serialPort.ReadLine().Trim()
            if ($line -match '^\d+$') {
                [int]$val = $line
                $lastRearmVal = $val
                if ($val -le $rearmThreshold) {
                    Write-Log "Chamber cleared ($val <= $rearmThreshold). System ready for a new breath test!" "Green"
                    break
                } else {
                    Write-Log "Clearing chamber: $val (waiting for <= $rearmThreshold)" "DarkGray"
                }
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }

    # ---------------------------------------------------------
    # STAGE 2: Waiting for an ACTIVE breath IMPULSE and measurement
    # ---------------------------------------------------------
    Write-Log "Waiting for a sharp breath (impulse +$deltaTrigger over 0.5s, corridor: from $minBlowingVal to $threshold)..." "Yellow"

    $consecutiveSoberSeconds = 0
    $isBlowingStarted = $false
    # IMPORTANT: use the actual last sensor value (end of chamber clearing),
    # NOT $baselineVal - otherwise the very first reading would produce a fake "jump"
    # relative to a long-stale background level and falsely trigger as a breath
    $prevVal = $lastRearmVal

    while ($true) {
        Invoke-LockPC

        try {
            $line = $serialPort.ReadLine().Trim()
            if ($line -match '^\d+$') {
                [int]$val = $line
                $delta = $val - $prevVal  # Calculate the rate of change of the value

                # 1. Detect the start of a breath by IMPULSE (sharp upward jump)
                if (-not $isBlowingStarted) {
                    if ($delta -ge $deltaTrigger -and $val -ge $minBlowingVal) {
                        $isBlowingStarted = $true
                        Write-Log "Breath IMPULSE detected! (Jump of +$delta, current: $val). Measuring sobriety ($soberTime sec)..." "Yellow"
                    } else {
                        Write-Log "Waiting for breath... Value: $val (Delta: $delta, need jump >= +$deltaTrigger)" "DarkGray"
                        $prevVal = $val
                        Start-Sleep -Milliseconds 500
                        continue
                    }
                }

                # 2. Evaluate the breath itself during the blow
                Write-Log "Blowing: $val (Corridor: $minBlowingVal - $threshold, Progress: $consecutiveSoberSeconds/$soberTime sec)" "Magenta"

                # Breath interrupted (value dropped below the minimum blowing level)
                if ($val -lt $minBlowingVal) {
                    Write-Log "Breath interrupted! Resetting counter." "Yellow"
                    $consecutiveSoberSeconds = 0
                    $isBlowingStarted = $false
                }
                # Sober breath (within the corridor)
                elseif ($val -lt $threshold) {
                    $consecutiveSoberSeconds++
                    if ($consecutiveSoberSeconds -ge $soberTime) {
                        Write-Log "Successful breath test! Access restored." "Green"
                        break
                    }
                }
                # Drunk breath (alcohol threshold exceeded)
                else {
                    Write-Log "ALCOHOL DETECTED IN BREATH! ($val >= $threshold)" "Red"
                    $consecutiveSoberSeconds = 0
                    $isBlowingStarted = $false
                }

                $prevVal = $val
            }
        }
        catch {
            Write-Log "Error reading during breath test (sensor disconnected?)" "Red"
        }

        Start-Sleep -Milliseconds 500
    }
}

# --- MAIN OPERATING LOOP ---
Write-Log "Starting AlcoLock. Mode: $Mode." "Green"
if ($Debug) { Write-Log "DEBUG MODE ACTIVE" "Yellow" }

$portName = Resolve-SerialPort -override $Port
Write-Log "Using port: $portName" "Green"

$serialPort = New-Object System.IO.Ports.SerialPort $portName, $baudRate, None, 8, One

try {
    $serialPort.Open()

    # Warmup and clean-air measurement is performed ONCE at script startup
    $globalBaseline = Initialize-Baseline -serialPort $serialPort

    if ($Mode -eq "Normal") {
        # ================= NORMAL MODE =================
        Invoke-LockPC
        Start-SoberVerificationLoop -serialPort $serialPort -baselineVal $globalBaseline
        Write-Log "Authentication session complete. Script will exit until next hour." "Cyan"

    } else {
        # ================= QUIET MODE =================
        while ($serialPort.IsOpen) {
            try {
                $line = $serialPort.ReadLine().Trim()
                if ($line -match '^\d+$') {
                    [int]$val = $line
                    Write-Log "Background monitoring: $val" "White"

                    if ($val -gt $threshold) {
                        Write-Log "THRESHOLD EXCEEDED! ($val > $threshold)" "Red"
                        Invoke-LockPC
                        # Reuse the already-known $globalBaseline, without another 10-sec warmup
                        Start-SoberVerificationLoop -serialPort $serialPort -baselineVal $globalBaseline
                    }
                }
            }
            catch {
                Write-Log "WARNING: SENSOR DISCONNECTED OR COM PORT CONNECTION LOST!" "Red"
                Invoke-LockPC
                
                while (-not $serialPort.IsOpen) {
                    Invoke-LockPC
                    Start-Sleep -Seconds 1
                    try { $serialPort.Open() } catch {}
                }
                
                # Recalibrate clean air on reconnect
                $globalBaseline = Initialize-Baseline -serialPort $serialPort
                Start-SoberVerificationLoop -serialPort $serialPort -baselineVal $globalBaseline
            }

            Start-Sleep -Seconds 2
        }
    }
}
catch {
    Write-Log "Error opening COM port: $_" "Red"
    if ($Mode -eq "Quiet") {
        Invoke-LockPC
    }
}
finally {
    if ($serialPort.IsOpen) { $serialPort.Close() }
}
