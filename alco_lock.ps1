<#
.SYNOPSIS
    Breathalyzer-gated action blocker with robust hardware disconnect handling.
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
    Write-Host "AlcoLock - Breathalyzer-gated action blocker" -ForegroundColor Cyan
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

function Get-SystemSerialPorts {
    $foundPorts = @()

    # Метод 1: Нативный .NET API
    try {
        $netPorts = [System.IO.Ports.SerialPort]::GetPortNames()
        if ($netPorts) { $foundPorts += $netPorts }
    } catch {}

    # Метод 2: Прямое чтение реестра Windows (на случай сбоя .NET)
    if ($env:OS -eq "Windows_NT") {
        try {
            $regKey = "HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM"
            if (Test-Path $regKey) {
                $regProps = Get-ItemProperty -Path $regKey
                foreach ($prop in $regProps.PSObject.Properties) {
                    if ($prop.Name -notmatch '^PS' -and $prop.Value -match '^COM\d+$') {
                        $foundPorts += $prop.Value
                    }
                }
            }
        } catch {}
    }

    return @($foundPorts | Select-Object -Unique | Sort-Object)
}

function Find-SerialPort {
    param([string]$override = "")
    if ($override) { return $override }

    $ports = Get-SystemSerialPorts
    if ($ports.Count -eq 0) { return $null }
    
    # Исключаем системный порт COM1, если есть другие USB-порты
    $usbPorts = @($ports | Where-Object { $_ -ne "COM1" })
    if ($usbPorts.Count -ge 1) { return $usbPorts[-1] }
    return $ports[0]
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
        IsBusy                  = $false
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

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500

    $timer.Add_Tick({
      if ($state.IsBusy) { return }
      $state.IsBusy = $true

      try {
        if (-not $serialPort -or -not $serialPort.IsOpen -or $serialPort.BytesToRead -le 0) { return }

        $line = ""
        try {
            $line = $serialPort.ReadLine().Trim()
        } catch { return }

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
      } catch { 
      } finally {
        $state.IsBusy = $false
      }
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

    $ctrl = @{ AllowClose = $false; IsBusy = $false }
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
          if ($ctrl.IsBusy) { return }
          $ctrl.IsBusy = $true

          try {
            $ready = $false
            try { $ready = & $checkAction } catch { }
            if ($ready) {
                $ctrl.AllowClose = $true
                $timer.Stop()
                $form.Close()
            }
          } catch { 
          } finally {
            $ctrl.IsBusy = $false
          }
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

        $state = @{ AllowClose = $false; IsBusy = $false }
        $form.Add_FormClosing({
            param($s, $e)
            if (-not $state.AllowClose) { $e.Cancel = $true }
        }.GetNewClosure())

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 500
        $timer.Add_Tick({
            if ($state.IsBusy) { return }
            $state.IsBusy = $true

            try {
                $elapsed = [Math]::Floor(([DateTime]::Now - $startTime).TotalSeconds)
                $remain = $warmupSec - $elapsed
                if ($remain -gt 0) {
                    $ui.Detail.Text = "Warming up and reading baseline... Please wait $remain seconds."
                    if ($serialPort -and $serialPort.IsOpen -and $serialPort.BytesToRead -gt 0) {
                        try {
                            $line = $serialPort.ReadLine().Trim()
                            if ($line -match '^\d+$') {
                                [int]$val = $line
                                if ($val -lt 500) { $samples.Add($val) }
                            }
                        } catch {}
                    }
                } else {
                    $state.AllowClose = $true
                    $timer.Stop()
                    $form.Close()
                }
            } finally {
                $state.IsBusy = $false
            }
        }.GetNewClosure())

        $timer.Start()
        $form.ShowDialog() | Out-Null
        if ($timer) { $timer.Stop(); $timer.Dispose() }
    } else {
        while (([DateTime]::Now - $startTime).TotalSeconds -lt $warmupSec) {
            if ($serialPort -and $serialPort.IsOpen -and $serialPort.BytesToRead -gt 0) {
                try {
                    $line = $serialPort.ReadLine().Trim()
                    if ($line -match '^\d+$') {
                        [int]$val = $line
                        if ($val -lt 500) { $samples.Add($val) }
                    }
                } catch {}
            }
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

function Connect-SensorOnce {
    param([string]$override = "")
    $portName = Find-SerialPort -override $override
    if (-not $portName) { 
        Write-Log "No COM ports detected in system." "DarkGray"
        return $null 
    }

    Write-Log "Attempting connection to $portName..." "Yellow"

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $port = $null
        try {
            $port = New-Object System.IO.Ports.SerialPort $portName, $baudRate, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One
            $port.ReadTimeout = 500
            $port.WriteTimeout = 500
            $port.Open()

            Start-Sleep -Milliseconds 400
            $port.DiscardInBuffer()
            Write-Log "Successfully connected to $portName!" "Green"
            return $port
        } catch [System.UnauthorizedAccessException] {
            Write-Log "ERROR: Port $portName is locked by another process (Arduino IDE, another script, etc.)." "Red"
            if ($port -and $port.IsOpen) { try { $port.Close() } catch {} }
            return $null
        } catch {
            Write-Log "Open attempt $attempt failed for $portName : $_" "DarkGray"
            if ($port -and $port.IsOpen) { try { $port.Close() } catch {} }
            Start-Sleep -Milliseconds 300
        }
    }
    return $null
}

function Connect-Sensor {
    param([string]$override = "")
    for ($attempt = 1; $attempt -le $portRetryAttempts; $attempt++) {
        $port = Connect-SensorOnce -override $override
        if ($port) { return $port }
        Start-Sleep -Seconds $portRetryDelaySec
    }
    return $null
}

# --- MAIN OPERATING LOOP ---
$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex($true, "Global\AlcoLockSingleInstance", [ref]$createdNew)
if (-not $createdNew) { 
    Write-Log "Another AlcoLock process is already running. Exiting." "Yellow"
    exit 
}

$serialPort = Connect-SensorOnce -override $Port
$neededRecoveryUI = $false

if (-not $serialPort) {
    $neededRecoveryUI = $true
    Show-WaitingOverlay -message "Sensor not found or port occupied. Connect the device or enter the master password." -checkAction {
        $script:serialPort = Connect-SensorOnce -override $Port
        return [bool]($script:serialPort -ne $null)
    }.GetNewClosure() -checkIntervalMs 1200
    
    $serialPort = $script:serialPort
}

if ($serialPort) {
    try {
        $showCalibUI = ($Mode -eq "Normal" -or $neededRecoveryUI)
        $calibration = Initialize-Baseline -serialPort $serialPort -ShowUI $showCalibUI
        $globalBaseline = $calibration.Baseline

        if ($Mode -eq "Normal") {
            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
        } else {
            while ($serialPort -and $serialPort.IsOpen) {
                try {
                    if ($serialPort.BytesToRead -gt 0) {
                        $line = $serialPort.ReadLine().Trim()
                        if ($line -match '^\d+$') {
                            [int]$val = $line
                            if ($val -gt $threshold) {
                                Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
                            }
                        }
                    }
                }
                catch {
                    Show-WaitingOverlay -message "Sensor disconnected. Reconnect the device to unlock." -checkAction {
                        $script:serialPort = Connect-SensorOnce -override $Port
                        return [bool]($script:serialPort -ne $null)
                    }.GetNewClosure() -checkIntervalMs 1000

                    $serialPort = $script:serialPort

                    if ($serialPort -and $serialPort.IsOpen) {
                        $calibration = Initialize-Baseline -serialPort $serialPort -ShowUI $true
                        $globalBaseline = $calibration.Baseline
                        if ($calibration.LastReading -gt $threshold) {
                            Show-VerificationOverlay -serialPort $serialPort -baselineVal $globalBaseline
                        }
                    }
                }
                Start-Sleep -Milliseconds 300
            }
        }
    }
    finally {
        if ($serialPort -and $serialPort.IsOpen) { try { $serialPort.Close() } catch {} }
    }
}