<#
.SYNOPSIS
    Breathalyzer-gated action blocker. Shows a fullscreen, always-on-top
    overlay until a sober breath is confirmed by an MQ-3 alcohol sensor
    connected via an Arduino-compatible board.

.DESCRIPTION
    Reads sensor readings from a serial port (Arduino/MQ-3), calibrates a
    clean-air baseline on startup, and shows a fullscreen blocking window
    whenever the reading exceeds the configured threshold. This is an
    app-level overlay (not a real Windows session lock via LockWorkStation) -
    it stays on top of everything, disables its own close button, and only
    closes after a genuine fresh breath (detected as a sharp impulse, not
    just a slowly-clearing residual reading) stays within the sober range
    for several consecutive seconds, or the master password is entered.

    Modes:
      Normal - shows the overlay once immediately, verifies sobriety, then
               exits (meant to be re-triggered hourly by Task Scheduler).
      Quiet  - stays running in the background, silently monitoring the
               sensor, and only shows the overlay when the threshold is
               actually exceeded.

.PARAMETER Mode
    Normal or Quiet. See DESCRIPTION. Default: Normal.

.PARAMETER Debug
    Alias -d. Skips autostart installation and the password prompt used by
    -Cleanup. The verification overlay itself still runs normally either way -
    it's an app window, not a real OS lock, so it's always safe to test.

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
  -Debug (-d)            Skips autostart install and the -Cleanup password
                         prompt. The overlay itself always runs normally.
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
$maxSaneBaseline = 150         # Reject/clamp calibration if the "clean air" baseline comes out this high or more
$masterPass = "SuperSecret123" # HARDCODED MASTER PASSWORD
$taskName   = "AlcoLockSystem" # Task name in Windows Task Scheduler
$soberTime  = 5                # Seconds of continuous sober breath required
$warmupSec  = 10               # Seconds of clean-air calibration at startup
$installDir = "C:\ProgramData\AlcoLock"
# =============================================

if ($env:OS -eq "Windows_NT") {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
}

# --- DEBUG LOG OUTPUT (console + persistent file, so the process is
#     reviewable afterward even when running invisibly in Quiet mode) ---
$script:logFilePath = if ($env:OS -eq "Windows_NT") {
    Join-Path $installDir "alcolock.log"
} else {
    Join-Path (Join-Path $HOME ".local/share/alcolock") "alcolock.log"
}

function Write-Log {
    param([string]$message, [string]$color = "Gray")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [$Mode-Mode] $message" -ForegroundColor $color

    try {
        $logDir = Split-Path $script:logFilePath -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $script:logFilePath -Value "[$timestamp] [$Mode-Mode] $message" -ErrorAction SilentlyContinue
    } catch {}
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

# --- FULLSCREEN BLOCKING OVERLAY (replaces LockWorkStation entirely) ---
# Windows' native lock screen (Secure Desktop) can't display live status, so
# instead of locking the OS session, this app-level window IS the barrier:
# always-on-top, borderless, spans all monitors, and disables its own close
# button. The only ways out are a genuine sober breath or the master password.

function New-OverlayForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "AlcoLock"
    $form.FormBorderStyle = "None"
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
    $form.StartPosition = "Manual"
    $form.Bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $form.ControlBox = $false
    $form.ShowInTaskbar = $true

    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text = "AlcoLock"
    $titleLbl.Font = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Bold)
    $titleLbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 85, 85)
    $titleLbl.AutoSize = $true
    $titleLbl.Location = New-Object System.Drawing.Point(60, 60)
    $form.Controls.Add($titleLbl)

    $headlineLbl = New-Object System.Windows.Forms.Label
    $headlineLbl.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $headlineLbl.ForeColor = [System.Drawing.Color]::White
    $headlineLbl.Size = New-Object System.Drawing.Size(760, 60)
    $headlineLbl.Location = New-Object System.Drawing.Point(60, 150)
    $form.Controls.Add($headlineLbl)

    $detailLbl = New-Object System.Windows.Forms.Label
    $detailLbl.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $detailLbl.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
    $detailLbl.Size = New-Object System.Drawing.Size(760, 90)
    $detailLbl.Location = New-Object System.Drawing.Point(60, 220)
    $form.Controls.Add($detailLbl)

    $pwLabel = New-Object System.Windows.Forms.Label
    $pwLabel.Text = "Blow into the sensor to unlock, or enter the master password:"
    $pwLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $pwLabel.ForeColor = [System.Drawing.Color]::FromArgb(204, 204, 204)
    $pwLabel.AutoSize = $true
    $pwLabel.Location = New-Object System.Drawing.Point(60, 340)
    $form.Controls.Add($pwLabel)

    $pwBox = New-Object System.Windows.Forms.TextBox
    $pwBox.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $pwBox.Size = New-Object System.Drawing.Size(250, 30)
    $pwBox.Location = New-Object System.Drawing.Point(60, 370)
    $pwBox.UseSystemPasswordChar = $true
    $form.Controls.Add($pwBox)

    $unlockBtn = New-Object System.Windows.Forms.Button
    $unlockBtn.Text = "Unlock"
    $unlockBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $unlockBtn.Size = New-Object System.Drawing.Size(100, 32)
    $unlockBtn.Location = New-Object System.Drawing.Point(320, 369)
    $form.Controls.Add($unlockBtn)

    $errorLbl = New-Object System.Windows.Forms.Label
    $errorLbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $errorLbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 85, 85)
    $errorLbl.AutoSize = $true
    $errorLbl.Location = New-Object System.Drawing.Point(60, 412)
    $form.Controls.Add($errorLbl)

    # Fight back a little if the user alt-tabs away - not real security (a
    # determined user can still kill the process via Task Manager), just
    # keeps the window from being trivially ignored.
    $form.Add_Deactivate({
        $form.TopMost = $false
        $form.TopMost = $true
    }.GetNewClosure())

    return [PSCustomObject]@{
        Form          = $form
        Headline      = $headlineLbl
        Detail        = $detailLbl
        PasswordBox   = $pwBox
        UnlockButton  = $unlockBtn
        ErrorLabel    = $errorLbl
    }
}

function Show-VerificationOverlay {
    param(
        [System.IO.Ports.SerialPort]$serialPort,
        [int]$baselineVal
    )

    try { $serialPort.DiscardInBuffer() } catch {}

    $rearmThreshold = $baselineVal + 40   # Level the chamber must drop below to be considered clear
    $minBlowingVal  = $baselineVal + 10   # Minimum level for a clean breath
    $deltaTrigger   = 15                  # Minimum sharp jump (+15) to detect an impulse

    Write-Log "LOCKED! Waiting for the sensor chamber to clear (value must drop below $rearmThreshold)..." "Red"

    $state = @{
        Stage                   = "Rearm"   # "Rearm" or "Breath"
        LastRearmVal            = $baselineVal
        PrevVal                 = $baselineVal
        ConsecutiveSoberSeconds = 0
        IsBlowingStarted        = $false
        AllowClose              = $false
    }

    $ui = New-OverlayForm
    $form = $ui.Form
    $ui.Headline.Text = "Alcohol detected"
    $ui.Detail.Text = "Waiting for the sensor to clear before you can retest. Do not blow yet."

    $form.Add_FormClosing({
        param($s, $e)
        if (-not $state.AllowClose) { $e.Cancel = $true }
    }.GetNewClosure())

    $tryUnlock = {
        if ($ui.PasswordBox.Text -eq $masterPass) {
            Write-Log "Master password override accepted - closing the overlay." "Yellow"
            $state.AllowClose = $true
            $form.Close()
        } else {
            $ui.ErrorLabel.Text = "Incorrect password."
            $ui.PasswordBox.Text = ""
        }
    }.GetNewClosure()

    $ui.UnlockButton.Add_Click($tryUnlock)
    $ui.PasswordBox.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { & $tryUnlock }
    }.GetNewClosure())

    $serialPort.ReadTimeout = 400
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500

    $timer.Add_Tick({
      try {
        try {
            $line = $serialPort.ReadLine().Trim()
        } catch {
            return  # read timeout / no data this tick - fine, just wait for the next one
        }
        if ($line -notmatch '^\d+$') { return }
        [int]$val = $line

        if ($state.Stage -eq "Rearm") {
            $state.LastRearmVal = $val
            if ($val -le $rearmThreshold) {
                Write-Log "Chamber cleared ($val <= $rearmThreshold). System ready for a new breath test!" "Green"
                Write-Log "Waiting for a sharp breath (impulse +$deltaTrigger over 0.5s, corridor: from $minBlowingVal to $threshold)..." "Yellow"
                $state.Stage = "Breath"
                $state.PrevVal = $state.LastRearmVal
                $ui.Headline.Text = "Ready - blow into the sensor"
                $ui.Detail.Text = "Needs a sharp jump above $minBlowingVal, then stay below $threshold for $soberTime sec."
            } else {
                Write-Log "Clearing chamber: $val (waiting for <= $rearmThreshold)" "DarkGray"
                $ui.Headline.Text = "Alcohol detected - waiting for the sensor to clear"
                $ui.Detail.Text = "Current reading: $val  (need <= $rearmThreshold)`nDo not blow yet."
            }
            return
        }

        # Stage = Breath
        $delta = $val - $state.PrevVal

        if (-not $state.IsBlowingStarted) {
            if ($delta -ge $deltaTrigger -and $val -ge $minBlowingVal) {
                $state.IsBlowingStarted = $true
                Write-Log "Breath IMPULSE detected! (Jump of +$delta, current: $val). Measuring sobriety ($soberTime sec)..." "Yellow"
                $ui.Headline.Text = "Breath detected - keep going"
            } else {
                Write-Log "Waiting for breath... Value: $val (Delta: $delta, need jump >= +$deltaTrigger)" "DarkGray"
                $ui.Headline.Text = "Ready - blow into the sensor"
                $ui.Detail.Text = "Current reading: $val  (need a sharp jump above $minBlowingVal)"
                $state.PrevVal = $val
                return
            }
        }

        Write-Log "Blowing: $val (Corridor: $minBlowingVal - $threshold, Progress: $($state.ConsecutiveSoberSeconds)/$soberTime sec)" "Magenta"
        $ui.Detail.Text = "Reading: $val  (must stay < $threshold)`nSober for $($state.ConsecutiveSoberSeconds)/$soberTime sec - keep breathing steadily."

        if ($val -lt $minBlowingVal) {
            Write-Log "Breath interrupted! Resetting counter." "Yellow"
            $ui.Headline.Text = "Breath interrupted - blow again"
            $state.ConsecutiveSoberSeconds = 0
            $state.IsBlowingStarted = $false
        }
        elseif ($val -lt $threshold) {
            $state.ConsecutiveSoberSeconds++
            if ($state.ConsecutiveSoberSeconds -ge $soberTime) {
                Write-Log "Successful breath test! Access restored." "Green"
                $ui.Headline.Text = "Success!"
                $ui.Detail.Text = "You are clear. Closing this window..."
                $state.AllowClose = $true
                $timer.Stop()
                $closeTimer = New-Object System.Windows.Forms.Timer
                $closeTimer.Interval = 700
                $closeTimer.Add_Tick({ try { $closeTimer.Stop(); $form.Close() } catch {} }.GetNewClosure())
                $closeTimer.Start()
            }
        }
        else {
            Write-Log "ALCOHOL DETECTED IN BREATH! ($val >= $threshold)" "Red"
            $ui.Headline.Text = "Still over the limit"
            $ui.Detail.Text = "Reading: $val  (limit: $threshold)`nWait for the sensor to clear, then try again."
            $state.ConsecutiveSoberSeconds = 0
            $state.IsBlowingStarted = $false
        }

        $state.PrevVal = $val
      } catch {
          Write-Log "Unexpected error in verification timer tick (ignored, will retry): $_" "Yellow"
      }
    }.GetNewClosure())

    $form.Add_Shown({ $form.Activate(); $ui.PasswordBox.Focus() }.GetNewClosure())
    $timer.Start()
    $form.ShowDialog() | Out-Null
    $timer.Stop()
    $timer.Dispose()
}

function Show-WaitingOverlay {
    # Simpler overlay for scenarios with no live sensor data to test against
    # (sensor disconnected, port failed to open): shows a message and only
    # accepts the master password, optionally auto-closing via $checkAction
    # (e.g. polling for the sensor to reconnect).
    param(
        [string]$message,
        [scriptblock]$checkAction = $null,
        [int]$checkIntervalMs = 1000
    )

    $ctrl = @{ AllowClose = $false }
    $ui = New-OverlayForm
    $form = $ui.Form
    $ui.Headline.Text = "AlcoLock"
    $ui.Detail.Text = $message

    $form.Add_FormClosing({
        param($s, $e)
        if (-not $ctrl.AllowClose) { $e.Cancel = $true }
    }.GetNewClosure())

    $tryUnlock = {
        if ($ui.PasswordBox.Text -eq $masterPass) {
            $ctrl.AllowClose = $true
            $form.Close()
        } else {
            $ui.ErrorLabel.Text = "Incorrect password."
            $ui.PasswordBox.Text = ""
        }
    }.GetNewClosure()

    $ui.UnlockButton.Add_Click($tryUnlock)
    $ui.PasswordBox.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { & $tryUnlock }
    }.GetNewClosure())

    $timer = $null
    if ($checkAction) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $checkIntervalMs
        $timer.Add_Tick({
            $ready = $false
            try {
                $ready = & $checkAction
            } catch {
                Write-Log "checkAction failed this tick (will retry): $_" "Yellow"
            }
            if ($ready) {
                $ctrl.AllowClose = $true
                $timer.Stop()
                $form.Close()
            }
        }.GetNewClosure())
        $timer.Start()
    }

    $form.Add_Shown({ $form.Activate(); $ui.PasswordBox.Focus() }.GetNewClosure())
    $form.ShowDialog() | Out-Null
    if ($timer) { $timer.Stop(); $timer.Dispose() }
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
    
    # RestartCount/RestartInterval: if the process is killed (Task Manager,
    # crash, etc.), Task Scheduler relaunches it instead of leaving the
    # machine unmonitored until next logon - the Linux side already gets
    # this for free from systemd's Restart=on-failure.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

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
    $lastRawVal = $baselineVal

    if ($samples.Count -gt 0) {
        # Take the second half of the samples (once the sensor has stabilized)
        $halfIndex = [math]::Floor($samples.Count / 2)
        $stableSamples = $samples.GetRange($halfIndex, $samples.Count - $halfIndex)
        
        $sum = 0
        foreach ($s in $stableSamples) { $sum += $s }
        $baselineVal = [math]::Round($sum / $stableSamples.Count)
        $lastRawVal = $samples[$samples.Count - 1]

        if ($baselineVal -ge $maxSaneBaseline) {
            Write-Log "WARNING: calibrated baseline ($baselineVal) is unusually high - the air may not have been clean during startup (e.g. alcohol was already present). Clamping to $maxSaneBaseline so detection doesn't get silently weakened." "Yellow"
            $baselineVal = $maxSaneBaseline
        }
    }

    Write-Log "Calibration complete! Clean air baseline value: $baselineVal" "Green"
    return [PSCustomObject]@{ Baseline = $baselineVal; LastReading = $lastRawVal }
}

# --- SENSOR CONNECTION (never throws - returns $null on failure so the
#     caller can route to the blocking overlay instead of silently exiting).
#     Used both for the initial connection and every reconnect, so that
#     turning the device off/unplugging it can never be used to cancel
#     verification - a missing sensor always demands the master password
#     or a real reconnect, the same as a mid-session disconnect does. ---
function Connect-Sensor {
    param([string]$override = "")
    try {
        $portName = Resolve-SerialPort -override $override
        $port = New-Object System.IO.Ports.SerialPort $portName, $baudRate, None, 8, One
        $port.Open()
        Write-Log "Using port: $portName" "Green"
        return $port
    } catch {
        Write-Log "Could not connect to the sensor: $_" "Red"
        return $null
    }
}

# Single-attempt variant, safe to call from a WinForms Timer.Add_Tick handler
# (i.e. from checkAction inside Show-WaitingOverlay). Connect-Sensor calls
# Resolve-SerialPort, which internally retries with Start-Sleep for up to
# ~12+ seconds - doing that on the UI thread freezes the whole window (no
# keyboard input gets through, and Windows may treat it as "Not Responding"
# and let Alt+F4 bypass the app's own close-cancellation entirely). The
# Timer's own recurring tick already provides the retry cadence, so this
# version tries exactly once and returns immediately either way.
function Connect-SensorOnce {
    param([string]$override = "")
    try {
        $portName = Find-SerialPort -override $override
        if (-not $portName) { return $null }
        $port = New-Object System.IO.Ports.SerialPort $portName, $baudRate, None, 8, One
        $port.Open()
        Write-Log "Using port: $portName" "Green"
        return $port
    } catch {
        return $null
    }
}

# --- MAIN OPERATING LOOP ---
Write-Log "Starting AlcoLock. Mode: $Mode." "Green"

# Single-instance guard: if another copy already holds the serial port
# (e.g. Quiet mode running continuously while the Normal-mode hourly trigger
# also fires), a second instance would fail to open the port and could be
# mistaken for "sensor not found" - refuse to fight over it instead.
# (Mutex is released automatically by the OS when this process exits.)
$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex($true, "Global\AlcoLockSingleInstance", [ref]$createdNew)
if (-not $createdNew) {
    Write-Log "Another AlcoLock instance is already running - exiting to avoid fighting over the serial port." "Yellow"
    exit
}
if ($Debug) { Write-Log "DEBUG MODE ACTIVE" "Yellow" }

$serialPort = Connect-Sensor -override $Port

if (-not $serialPort) {
    Show-WaitingOverlay -message "Sensor not found. Connect the device to continue, or enter the master password." -checkAction {
        $script:serialPort = Connect-SensorOnce -override $Port
        return [bool]$script:serialPort
    }.GetNewClosure() -checkIntervalMs 2000
}

if ($serialPort) {
    try {
        # Warmup and clean-air measurement is performed ONCE at script startup
        $calibration = Initialize-Baseline -serialPort $serialPort
        $globalBaseline = $calibration.Baseline

        if ($Mode -eq "Normal") {
            # ================= NORMAL MODE =================
            # Intentionally unconditional: this is a periodic sobriety check-in
            # (e.g. hourly via Task Scheduler), not a reaction to a detected
            # spike - the whole point is to make sure the person at the
            # computer stays sober, checked at regular intervals.
            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
            Write-Log "Check complete. Script will exit until next hour." "Cyan"

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
                            # Reuse the already-known $globalBaseline, without another 10-sec warmup
                            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
                        }
                    }
                }
                catch {
                    Write-Log "WARNING: SENSOR DISCONNECTED OR COM PORT CONNECTION LOST!" "Red"

                    Show-WaitingOverlay -message "Sensor disconnected. Reconnect the device to unlock, or enter the master password." -checkAction {
                        $script:serialPort = Connect-SensorOnce -override $Port
                        return [bool]$script:serialPort
                    }.GetNewClosure() -checkIntervalMs 1000

                    if ($serialPort -and $serialPort.IsOpen) {
                        # Recalibrate clean air on reconnect
                        $calibration = Initialize-Baseline -serialPort $serialPort
                        $globalBaseline = $calibration.Baseline
                        if ($calibration.LastReading -gt $threshold) {
                            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
                        } else {
                            Write-Log "Sensor reconnected, reading is sober ($($calibration.LastReading) <= $threshold) - resuming background monitoring." "Green"
                        }
                    }
                }

                Start-Sleep -Seconds 2
            }
        }
    }
    finally {
        if ($serialPort.IsOpen) { $serialPort.Close() }
    }
} else {
    Write-Log "No sensor connection available (master password was used to bypass) - exiting." "Yellow"
}
