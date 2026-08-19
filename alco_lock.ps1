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
#>

param(
    [ValidateSet("Normal", "Quiet")]
    [string]$Mode = "Normal",
    
    [Alias("d")]
    [switch]$Debug,

    [switch]$Cleanup,
    [switch]$DisableAutostart,

    [string]$Port = "",

    [Alias("h","?")]
    [switch]$Help
)

if ($Help) {
    Write-Host "See Get-Help for details." -ForegroundColor Cyan
    exit
}

# ================= SETTINGS =================
$portRetryAttempts = 6     
$portRetryDelaySec  = 2
$baudRate   = 9600
$threshold  = 350             
$maxSaneBaseline = 150         
$masterPass = "SuperSecret123" 
$taskName   = "AlcoLockSystem_$Mode" 
$soberTime  = 5                
$warmupSec  = 10               
$installDir = "C:\ProgramData\AlcoLock"
# =============================================

if ($env:OS -eq "Windows_NT") {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
}

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

function Find-SerialPort {
    param([string]$override = "")
    if ($override) { return $override }

    if ($env:OS -eq "Windows_NT") {
        try {
            $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                Where-Object { $_.Name -match '\(COM\d+\)' }

            $known = @($devices | Where-Object {
                $_.Name -match 'Arduino' -or $_.Name -match 'CH340' -or $_.Name -match 'CH341' -or
                $_.Name -match 'USB-SERIAL' -or $_.Name -match 'CP210' -or $_.Name -match 'FTDI'
            })

            if ($known.Count -ge 1 -and $known[0].Name -match '\((COM\d+)\)') {
                return $matches[1]
            }
        } catch {}

        $ports = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
        if ($ports.Count -ge 1) { return $ports[0] }
        return $null
    }
    else {
        $candidates = @()
        $candidates += Get-ChildItem -Path /dev -Filter "ttyACM*" -ErrorAction SilentlyContinue
        $candidates += Get-ChildItem -Path /dev -Filter "ttyUSB*" -ErrorAction SilentlyContinue
        if ($candidates.Count -ge 1) { return $candidates[0].FullName }
        return $null
    }
}

function Resolve-SerialPort {
    param([string]$override = "")
    for ($attempt = 1; $attempt -le $portRetryAttempts; $attempt++) {
        $found = Find-SerialPort -override $override
        if ($found) { return $found }
        Write-Log "Port not found (attempt $attempt/$portRetryAttempts). Retrying..." "Yellow"
        Start-Sleep -Seconds $portRetryDelaySec
    }
    throw "Could not find a serial port."
}

function Show-PasswordDialog {
    param([string]$promptTitle, [string]$promptText)
    if ($Debug) { return $null }
    if ($env:OS -ne "Windows_NT") { return Read-Host "Master password" }
    
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

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $textBox.Text }
    return $null
}

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

    $primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $contentWidth = 760
    $contentX = $primary.X + [int](($primary.Width - $contentWidth) / 2)
    $topY = $primary.Y + [int]($primary.Height * 0.22)

    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text = "AlcoLock"
    $titleLbl.Font = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Bold)
    $titleLbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 85, 85)
    $titleLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $titleLbl.Size = New-Object System.Drawing.Size($contentWidth, 60)
    $titleLbl.Location = New-Object System.Drawing.Point($contentX, $topY)
    $form.Controls.Add($titleLbl)

    $headlineLbl = New-Object System.Windows.Forms.Label
    $headlineLbl.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $headlineLbl.ForeColor = [System.Drawing.Color]::White
    $headlineLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $headlineLbl.Size = New-Object System.Drawing.Size($contentWidth, 60)
    $headlineLbl.Location = New-Object System.Drawing.Point($contentX, ($topY + 90))
    $form.Controls.Add($headlineLbl)

    $detailLbl = New-Object System.Windows.Forms.Label
    $detailLbl.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $detailLbl.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
    $detailLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $detailLbl.Size = New-Object System.Drawing.Size($contentWidth, 90)
    $detailLbl.Location = New-Object System.Drawing.Point($contentX, ($topY + 160))
    $form.Controls.Add($detailLbl)

    $pwLabel = New-Object System.Windows.Forms.Label
    $pwLabel.Text = "Blow into the sensor to unlock, or enter the master password:"
    $pwLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $pwLabel.ForeColor = [System.Drawing.Color]::FromArgb(204, 204, 204)
    $pwLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $pwLabel.Size = New-Object System.Drawing.Size($contentWidth, 26)
    $pwLabel.Location = New-Object System.Drawing.Point($contentX, ($topY + 280))
    $form.Controls.Add($pwLabel)

    $pwBoxWidth = 250
    $btnWidth = 100
    $gap = 10
    $pairWidth = $pwBoxWidth + $gap + $btnWidth
    $pairX = $primary.X + [int](($primary.Width - $pairWidth) / 2)
    $pairY = $topY + 312

    $pwBox = New-Object System.Windows.Forms.TextBox
    $pwBox.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $pwBox.Size = New-Object System.Drawing.Size($pwBoxWidth, 30)
    $pwBox.Location = New-Object System.Drawing.Point($pairX, $pairY)
    $pwBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    $pwBox.UseSystemPasswordChar = $true
    $form.Controls.Add($pwBox)

    $unlockBtn = New-Object System.Windows.Forms.Button
    $unlockBtn.Text = "Unlock"
    $unlockBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $unlockBtn.Size = New-Object System.Drawing.Size($btnWidth, 32)
    $unlockBtn.Location = New-Object System.Drawing.Point(($pairX + $pwBoxWidth + $gap), ($pairY - 1))
    $form.Controls.Add($unlockBtn)

    $errorLbl = New-Object System.Windows.Forms.Label
    $errorLbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $errorLbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 85, 85)
    $errorLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $errorLbl.Size = New-Object System.Drawing.Size($contentWidth, 24)
    $errorLbl.Location = New-Object System.Drawing.Point($contentX, ($pairY + 42))
    $form.Controls.Add($errorLbl)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "✕  Close"
    $closeBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $closeBtn.Size = New-Object System.Drawing.Size(120, 34)
    $closeBtn.Location = New-Object System.Drawing.Point(($primary.X + [int](($primary.Width - 120) / 2)), ($pairY + 70))
    $closeBtn.Visible = $false
    $form.Controls.Add($closeBtn)

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
        CloseButton   = $closeBtn
    }
}

function Show-VerificationOverlay {
    param(
        [System.IO.Ports.SerialPort]$serialPort,
        [int]$baselineVal
    )

    try { $serialPort.DiscardInBuffer() } catch {}

    $rearmThreshold = $baselineVal + 40   
    $minBlowingVal  = $baselineVal + 10   
    $deltaTrigger   = 15                  

    Write-Log "LOCKED! Waiting for the sensor chamber to clear (value must drop below $rearmThreshold)..." "Red"

    $state = @{
        Stage                   = "Rearm"
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

    $ui.CloseButton.Add_Click({
        try { $state.CloseTimer.Stop() } catch {}
        $form.Close()
    }.GetNewClosure())

    $serialPort.ReadTimeout = 400
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500

    $timer.Add_Tick({
      try {
        try {
            $line = $serialPort.ReadLine().Trim()
        } catch {
            return
        }
        if ($line -notmatch '^\d+$') { return }
        [int]$val = $line

        if ($state.Stage -eq "Rearm") {
            $state.LastRearmVal = $val
            if ($val -le $rearmThreshold) {
                Write-Log "Chamber cleared. System ready for a new breath test!" "Green"
                $state.Stage = "Breath"
                $state.PrevVal = $state.LastRearmVal
                $ui.Headline.Text = "Ready - blow into the sensor"
                $ui.Detail.Text = "Needs a sharp jump above $minBlowingVal, then stay below $threshold for $soberTime sec."
            } else {
                $ui.Headline.Text = "Alcohol detected - waiting for the sensor to clear"
                $ui.Detail.Text = "Current reading: $val  (need <= $rearmThreshold)`nDo not blow yet."
            }
            return
        }

        $delta = $val - $state.PrevVal

        if (-not $state.IsBlowingStarted) {
            if ($delta -ge $deltaTrigger -and $val -ge $minBlowingVal) {
                $state.IsBlowingStarted = $true
                Write-Log "Breath IMPULSE detected! Measuring sobriety..." "Yellow"
                $ui.Headline.Text = "Breath detected - keep going"
            } else {
                $ui.Headline.Text = "Ready - blow into the sensor"
                $ui.Detail.Text = "Current reading: $val  (need a sharp jump above $minBlowingVal)"
                $state.PrevVal = $val
                return
            }
        }

        $ui.Detail.Text = "Reading: $val  (must stay < $threshold)`nSober for $($state.ConsecutiveSoberSeconds)/$soberTime sec - keep breathing steadily."

        if ($val -lt $minBlowingVal) {
            $ui.Headline.Text = "Breath interrupted - blow again"
            $state.ConsecutiveSoberSeconds = 0
            $state.IsBlowingStarted = $false
        }
        elseif ($val -lt $threshold) {
            $state.ConsecutiveSoberSeconds++
            if ($state.ConsecutiveSoberSeconds -ge $soberTime) {
                Write-Log "Successful breath test! Access restored." "Green"
                $ui.Headline.Text = "Success!"
                $ui.Detail.Text = "You are clear. Closing automatically."
                $state.AllowClose = $true
                $timer.Stop()
                
                $state.CloseTimer = New-Object System.Windows.Forms.Timer
                $state.CloseTimer.Interval = 700
                $state.CloseTimer.Add_Tick({ try { $state.CloseTimer.Stop(); $form.Close() } catch {} }.GetNewClosure())
                $state.CloseTimer.Start()
                $ui.CloseButton.Visible = $true
            }
        }
        else {
            $ui.Headline.Text = "Still over the limit"
            $ui.Detail.Text = "Reading: $val  (limit: $threshold)`nWait for the sensor to clear, then try again."
            $state.ConsecutiveSoberSeconds = 0
            $state.IsBlowingStarted = $false
        }

        $state.PrevVal = $val
      } catch { }
    }.GetNewClosure())

    $form.Add_Shown({ $form.Activate(); $ui.PasswordBox.Focus() }.GetNewClosure())
    $timer.Start()
    $form.ShowDialog() | Out-Null
    $timer.Stop()
    $timer.Dispose()
}

function Show-WaitingOverlay {
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
          try {
            $ready = $false
            try { $ready = & $checkAction } catch { }
            if ($ready) {
                $ctrl.AllowClose = $true
                $timer.Stop()
                $form.Close()
            }
          } catch { }
        }.GetNewClosure())
        $timer.Start()
    }

    $form.Add_Shown({ $form.Activate(); $ui.PasswordBox.Focus() }.GetNewClosure())
    $form.ShowDialog() | Out-Null
    if ($timer) { $timer.Stop(); $timer.Dispose() }
}

function Remove-AlcoLock {
    $inputPass = Show-PasswordDialog -promptTitle "Remove AlcoLock" -promptText "Enter the master password for full cleanup:"
    if ($inputPass -eq $masterPass) {
        try {
            if ($env:OS -eq "Windows_NT") {
                Unregister-ScheduledTask -TaskName "AlcoLockSystem_Normal" -Confirm:$false -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName "AlcoLockSystem_Quiet" -Confirm:$false -ErrorAction SilentlyContinue
                if (Test-Path $installDir) { Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue }
                [System.Windows.Forms.MessageBox]::Show("AlcoLock has been completely removed from the system!", "Success", 0, 64)
            } else {
                Write-Log "Task and files cleaned up." "Green"
            }
        } catch {}
    } else {
        if ($env:OS -eq "Windows_NT") {
            [System.Windows.Forms.MessageBox]::Show("Incorrect master password!", "Access Denied", 0, 48)
        }
    }
}

function Install-Self {
    if ($Debug) { return }
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
    
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

if ($Cleanup -or $DisableAutostart) {
    Remove-AlcoLock
    exit
}

Install-Self

function Initialize-Baseline {
    param(
        [System.IO.Ports.SerialPort]$serialPort,
        [bool]$ShowUI = $false
    )

    Write-Log "Initializing sensor: starting calibration and warmup ($warmupSec sec)..." "Yellow"
    try { $serialPort.DiscardInBuffer() } catch {}

    $samples = [System.Collections.Generic.List[int]]::new()
    $startTime = [DateTime]::Now

    if ($ShowUI) {
        $ui = New-OverlayForm
        $form = $ui.Form
        $ui.Headline.Text = "Calibrating Sensor"
        $ui.PasswordBox.Visible = $false
        $ui.UnlockButton.Visible = $false
        $ui.ErrorLabel.Visible = $false
        $ui.CloseButton.Visible = $false

        $state = @{ AllowClose = $false }
        $form.Add_FormClosing({
            param($s, $e)
            if (-not $state.AllowClose) { $e.Cancel = $true }
        }.GetNewClosure())

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 500
        $timer.Add_Tick({
            $elapsed = [Math]::Floor(([DateTime]::Now - $startTime).TotalSeconds)
            $remain = $warmupSec - $elapsed
            if ($remain -gt 0) {
                $ui.Detail.Text = "Warming up and reading baseline... Please wait $remain seconds."
                try {
                    $line = $serialPort.ReadLine().Trim()
                    if ($line -match '^\d+$') {
                        [int]$val = $line
                        if ($val -lt 500) { $samples.Add($val) }
                    }
                } catch {}
            } else {
                $state.AllowClose = $true
                $timer.Stop()
                $form.Close()
            }
        }.GetNewClosure())

        $timer.Start()
        $form.ShowDialog() | Out-Null
        if ($timer) { $timer.Stop(); $timer.Dispose() }
    } else {
        while (([DateTime]::Now - $startTime).TotalSeconds -lt $warmupSec) {
            try {
                $line = $serialPort.ReadLine().Trim()
                if ($line -match '^\d+$') {
                    [int]$val = $line
                    if ($val -lt 500) { $samples.Add($val) }
                }
            } catch {}
            Start-Sleep -Milliseconds 500
        }
    }

    $baselineVal = 80
    $lastRawVal = $baselineVal

    if ($samples.Count -gt 0) {
        $halfIndex = [math]::Floor($samples.Count / 2)
        $stableSamples = $samples.GetRange($halfIndex, $samples.Count - $halfIndex)
        
        $sum = 0
        foreach ($s in $stableSamples) { $sum += $s }
        if ($stableSamples.Count -gt 0) {
            $baselineVal = [math]::Round($sum / $stableSamples.Count)
        }
        $lastRawVal = $samples[$samples.Count - 1]

        if ($baselineVal -ge $maxSaneBaseline) {
            $baselineVal = $maxSaneBaseline
        }
    }

    Write-Log "Calibration complete! Clean air baseline: $baselineVal" "Green"
    return [PSCustomObject]@{ Baseline = $baselineVal; LastReading = $lastRawVal }
}

function Connect-Sensor {
    param([string]$override = "")
    try {
        $portName = Resolve-SerialPort -override $override
        $port = New-Object System.IO.Ports.SerialPort $portName, $baudRate, None, 8, One
        $port.ReadTimeout = 1000 # Защита от вечного зависания
        $port.Open()
        return $port
    } catch {
        return $null
    }
}

function Connect-SensorOnce {
    param([string]$override = "")
    try {
        $portName = Find-SerialPort -override $override
        if (-not $portName) { return $null }
        $port = New-Object System.IO.Ports.SerialPort $portName, $baudRate, None, 8, One
        $port.ReadTimeout = 1000 # Защита от вечного зависания
        $port.Open()
        return $port
    } catch {
        return $null
    }
}

# --- MAIN OPERATING LOOP ---
$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex($true, "Global\AlcoLockSingleInstance", [ref]$createdNew)
if (-not $createdNew) { exit }

$serialPort = Connect-Sensor -override $Port
$neededRecoveryUI = $false

if (-not $serialPort) {
    $neededRecoveryUI = $true
    Show-WaitingOverlay -message "Sensor not found. Connect the device to continue, or enter the master password." -checkAction {
        $script:serialPort = Connect-SensorOnce -override $Port
        return [bool]$script:serialPort
    }.GetNewClosure() -checkIntervalMs 2000
    
    # КРИТИЧЕСКИЙ ФИКС: подтягиваем заново подключенный порт в локальную область видимости
    $serialPort = $script:serialPort
}

if ($serialPort) {
    try {
        # Если это Normal режим ИЛИ мы только что восстановились из ошибки - показываем UI калибровки
        $showCalibUI = ($Mode -eq "Normal" -or $neededRecoveryUI)
        $calibration = Initialize-Baseline -serialPort $serialPort -ShowUI $showCalibUI
        $globalBaseline = $calibration.Baseline

        if ($Mode -eq "Normal") {
            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
        } else {
            while ($serialPort.IsOpen) {
                try {
                    $line = $serialPort.ReadLine().Trim()
                    if ($line -match '^\d+$') {
                        [int]$val = $line
                        if ($val -gt $threshold) {
                            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
                        }
                    }
                }
                catch {
                    Show-WaitingOverlay -message "Sensor disconnected. Reconnect the device to unlock." -checkAction {
                        $script:serialPort = Connect-SensorOnce -override $Port
                        return [bool]$script:serialPort
                    }.GetNewClosure() -checkIntervalMs 1000

                    # ФИКС: обновляем переменную для while ($serialPort.IsOpen)
                    $serialPort = $script:serialPort

                    if ($serialPort -and $serialPort.IsOpen) {
                        # Обязательно показываем UI при рекалибровке, чтобы не дать "бесплатных" 10 секунд
                        $calibration = Initialize-Baseline -serialPort $serialPort -ShowUI $true
                        $globalBaseline = $calibration.Baseline
                        if ($calibration.LastReading -gt $threshold) {
                            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
                        }
                    }
                }
                Start-Sleep -Milliseconds 500
            }
        }
    }
    finally {
        if ($serialPort -and $serialPort.IsOpen) { $serialPort.Close() }
    }
}