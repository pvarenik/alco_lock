#requires -Version 5.1

<##
    AlcoholGuard.ps1

    Purpose:
      - Detect Arduino MQ-3 sensor over serial.
      - Lock the desktop with a fullscreen overlay.
      - Ask the user to blow into the sensor.
      - Require a confirmed breath event, then require values <= 350.
      - Allow emergency unlock with master password 1989.
      - Run immediately at logon and repeat the check every hour.
      - Remove the scheduled task with -CleanUp.
      - Run algorithm tests with -SelfTest.
      - Show diagnostic values with -DebugMode.

    IMPORTANT:
      This is a user-session kiosk overlay, NOT the Windows secure lock screen.
      Ctrl+Alt+Del is intentionally not interceptable by a normal PowerShell app.

    Arduino expected serial output:
      0..1023, one value per line, 9600 baud.
#>

param(
    [switch]$Run,
    [switch]$CleanUp,
    [switch]$SelfTest,
    [switch]$DebugMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CONFIGURATION
# ============================================================

$TaskName = 'AlcoholBreathGuard'
$MasterPassword = '1989'

# Set to 'COM5' to avoid scanning every COM port.
# Leave as $null for automatic detection.
$PreferredComPort = $null

$BaudRate = 9600
$AlcoholLimit = 350
$ArduinoSampleIntervalMs = 500

# Calibration of clean air.
$CalibrationSeconds = 10
$CalibrationMinimumSamples = 8

# Breath detection.
# Example: baseline=200 -> threshold=max(245,230)=245.
$BlowDelta = 45
$BlowRatio = 1.15

# Require at least 2 elevated samples in a 3-sample rolling window.
$BreathWindowSize = 3
$BreathRequiredHits = 2

# Strong spike can trigger immediately.
$StrongBreathDelta = 120

# After breath detection, require consecutive safe readings <= AlcoholLimit.
$SafeReadingsRequired = 3

# Hourly checking.
$HourlyCheckSeconds = 3600

# Polling / reconnect.
$UiTickMs = 100
$SensorReadEveryMs = 100
$PortScanIntervalMs = 2000

# Persistent log.
$LogDirectory = Join-Path $env:LOCALAPPDATA 'AlcoholGuard'
$LogFile = Join-Path $LogDirectory 'AlcoholGuard.log'

# ============================================================
# GLOBAL STATE
# ============================================================

$script:SerialPort = $null
$script:SensorPort = $null
$script:SensorConnected = $false

$script:State = 'NoSensor'
# NoSensor
# Calibrating
# WaitingForBreath
# BreathDetected
# Unlocked

$script:Baseline = $null
$script:BreathThreshold = $null
$script:LastUiValue = $null
$script:LastLogValue = $null

$script:CalibrationStartedUtc = $null
$script:CalibrationReadings = New-Object System.Collections.Generic.List[int]
$script:RecentReadings = New-Object System.Collections.Generic.List[int]
$script:SafeReadings = 0

$script:CurrentCheckStartedUtc = $null
$script:NextCheckUtc = $null
$script:LastUiMessage = ''

$script:Forms = @()
$script:StatusLabels = @()
$script:CurrentValueLabel = $null
$script:BaselineLabel = $null
$script:ThresholdLabel = $null
$script:StateLabel = $null
$script:NextCheckLabel = $null
$script:PasswordBox = $null
$script:PasswordButton = $null
$script:Timer = $null

$script:KeyboardHookInstalled = $false
$script:Mutex = $null

# ============================================================
# LOGGING
# ============================================================

function Write-GuardLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    try {
        if (-not (Test-Path $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        }

        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $env:USERNAME, $Message
        Add-Content -Path $LogFile -Value $line -Encoding UTF8

        if ($DebugMode) {
            Write-Host $line
        }
    }
    catch {
        # Logging must never stop the guard.
    }
}

# ============================================================
# HELPERS
# ============================================================

function Get-Median {
    param(
        [Parameter(Mandatory)]
        [int[]]$Values
    )

    if ($Values.Count -eq 0) {
        return $null
    }

    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count

    if (($count % 2) -eq 1) {
        return [double]$sorted[[int]($count / 2)]
    }

    return ([double]$sorted[($count / 2) - 1] + [double]$sorted[$count / 2]) / 2.0
}

function Set-State {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('NoSensor','Calibrating','WaitingForBreath','BreathDetected','Unlocked')]
        [string]$NewState
    )

    if ($script:State -ne $NewState) {
        Write-GuardLog "State: $($script:State) -> $NewState"
    }

    $script:State = $NewState
}

function Clear-SensorAlgorithmState {
    $script:Baseline = $null
    $script:BreathThreshold = $null
    $script:CalibrationStartedUtc = $null
    $script:CalibrationReadings.Clear()
    $script:RecentReadings.Clear()
    $script:SafeReadings = 0
}

function Start-Calibration {
    if (-not $script:SensorConnected) {
        Set-State -NewState 'NoSensor'
        return
    }

    Clear-SensorAlgorithmState
    $script:CalibrationStartedUtc = [DateTime]::UtcNow
    Set-State -NewState 'Calibrating'
    Write-GuardLog "Calibration started on $($script:SensorPort)"
}

function Close-SerialPort {
    try {
        if ($null -ne $script:SerialPort) {
            if ($script:SerialPort.IsOpen) {
                $script:SerialPort.Close()
            }
            $script:SerialPort.Dispose()
        }
    }
    catch {
        Write-GuardLog "Serial close error: $($_.Exception.Message)"
    }

    $script:SerialPort = $null
    $script:SensorPort = $null
    $script:SensorConnected = $false
    Clear-SensorAlgorithmState
    Set-State -NewState 'NoSensor'
}

function Test-NumericSensorLine {
    param(
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    $value = 0
    if (-not [int]::TryParse($Line.Trim(), [ref]$value)) {
        return $false
    }

    return ($value -ge 0 -and $value -le 1023)
}

function Open-ArduinoPort {
    param(
        [Parameter(Mandatory)]
        [string]$PortName
    )

    $port = $null

    try {
        $port = New-Object System.IO.Ports.SerialPort(
            $PortName,
            $BaudRate,
            [System.IO.Ports.Parity]::None,
            8,
            [System.IO.Ports.StopBits]::One
        )

        $port.ReadTimeout = 250
        $port.WriteTimeout = 250
        $port.DtrEnable = $false
        $port.RtsEnable = $false

        $port.Open()
        Start-Sleep -Milliseconds 300

        $deadline = [DateTime]::UtcNow.AddMilliseconds(1200)

        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $line = $port.ReadLine().Trim()
                if (Test-NumericSensorLine -Line $line) {
                    Write-GuardLog "Arduino detected on $PortName"
                    return $port
                }
            }
            catch [TimeoutException] {
                # Keep waiting until deadline.
            }
        }

        $port.Close()
        $port.Dispose()
        return $null
    }
    catch {
        try {
            if ($null -ne $port) {
                $port.Close()
                $port.Dispose()
            }
        }
        catch {
        }
        return $null
    }
}

function Find-Arduino {
    if ($script:SensorConnected -and $null -ne $script:SerialPort -and $script:SerialPort.IsOpen) {
        return $true
    }

    $ports = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredComPort)) {
        $ports = @($PreferredComPort)
    }
    else {
        try {
            $ports = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
        }
        catch {
            $ports = @()
        }
    }

    foreach ($portName in $ports) {
        $candidate = Open-ArduinoPort -PortName $portName
        if ($null -ne $candidate) {
            $script:SerialPort = $candidate
            $script:SensorPort = $portName
            $script:SensorConnected = $true
            Start-Calibration
            return $true
        }
    }

    return $false
}

function Read-SensorValue {
    if (-not $script:SensorConnected -or $null -eq $script:SerialPort -or -not $script:SerialPort.IsOpen) {
        return $null
    }

    $latest = $null

    try {
        while ($true) {
            try {
                $line = $script:SerialPort.ReadLine().Trim()
                if (Test-NumericSensorLine -Line $line) {
                    $parsed = 0
                    if ([int]::TryParse($line, [ref]$parsed)) {
                        $latest = $parsed
                    }
                }
            }
            catch [TimeoutException] {
                break
            }
        }

        return $latest
    }
    catch {
        Write-GuardLog "Serial read error: $($_.Exception.Message)"
        Close-SerialPort
        return $null
    }
}

# ============================================================
# ALGORITHM
# ============================================================

function Complete-CalibrationIfReady {
    if ($script:State -ne 'Calibrating') {
        return
    }

    if ($null -eq $script:CalibrationStartedUtc) {
        return
    }

    $elapsed = ([DateTime]::UtcNow - $script:CalibrationStartedUtc).TotalSeconds

    if ($elapsed -lt $CalibrationSeconds) {
        return
    }

    if ($script:CalibrationReadings.Count -lt $CalibrationMinimumSamples) {
        return
    }

    # Median is deliberately used instead of average so that one accidental
    # strong spike during calibration has less influence on the baseline.
    $baselineDouble = Get-Median -Values @($script:CalibrationReadings)
    $baseline = [int][Math]::Round([double]$baselineDouble)
    $baseline = [Math]::Max(1, [Math]::Min(1023, $baseline))

    $deltaThreshold = $baseline + $BlowDelta
    $ratioThreshold = [int][Math]::Ceiling($baseline * $BlowRatio)

    $threshold = [Math]::Max($deltaThreshold, $ratioThreshold)
    $threshold = [Math]::Min(1023, $threshold)

    $script:Baseline = $baseline
    $script:BreathThreshold = $threshold
    $script:RecentReadings.Clear()
    $script:SafeReadings = 0

    Set-State -NewState 'WaitingForBreath'
    Write-GuardLog "Calibration complete: baseline=$baseline breathThreshold=$threshold samples=$($script:CalibrationReadings.Count)"
}

function Process-SensorReading {
    param(
        [Parameter(Mandatory)]
        [int]$Value
    )

    $script:LastUiValue = $Value

    if ($script:State -eq 'Calibrating') {
        $script:CalibrationReadings.Add($Value)
        Complete-CalibrationIfReady
        return
    }

    if ($script:State -eq 'WaitingForBreath' -or $script:State -eq 'BreathDetected') {
        $script:RecentReadings.Add($Value)

        while ($script:RecentReadings.Count -gt $BreathWindowSize) {
            $script:RecentReadings.RemoveAt(0)
        }
    }

    if ($script:State -eq 'WaitingForBreath') {
        if ($null -eq $script:BreathThreshold -or $null -eq $script:Baseline) {
            return
        }

        $hits = @($script:RecentReadings | Where-Object { $_ -ge $script:BreathThreshold }).Count

        if ($hits -ge $BreathRequiredHits -or $Value -ge ($script:Baseline + $StrongBreathDelta)) {
            $script:SafeReadings = 0
            Set-State -NewState 'BreathDetected'
            Write-GuardLog "Breath detected: value=$Value baseline=$($script:Baseline) threshold=$($script:BreathThreshold) recent=[$($script:RecentReadings -join ',')]"
        }

        return
    }

    if ($script:State -eq 'BreathDetected') {
        if ($Value -le $AlcoholLimit) {
            $script:SafeReadings++
        }
        else {
            $script:SafeReadings = 0
        }

        if ($script:SafeReadings -ge $SafeReadingsRequired) {
            Unlock-Screen -Reason 'Sensor accepted'
        }
    }
}

# ============================================================
# GUI
# ============================================================

function Set-UiMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($script:LastUiMessage -eq $Message) {
        return
    }

    $script:LastUiMessage = $Message

    foreach ($label in $script:StatusLabels) {
        try {
            $label.Text = $Message
        }
        catch {
        }
    }
}

function Update-Ui {
    try {
        switch ($script:State) {
            'NoSensor' {
                Set-UiMessage -Message 'Connect sensor'
            }
            'Calibrating' {
                Set-UiMessage -Message 'Calibrating sensor - do not blow'
            }
            'WaitingForBreath' {
                Set-UiMessage -Message 'Blow into the sensor'
            }
            'BreathDetected' {
                Set-UiMessage -Message 'Breath detected - checking reading'
            }
            'Unlocked' {
                Set-UiMessage -Message 'Access granted'
            }
        }

        $script:StateLabel.Text = "State: $($script:State)"

        if ($null -ne $script:LastUiValue) {
            $script:CurrentValueLabel.Text = "Reading: $($script:LastUiValue)"
        }
        else {
            $script:CurrentValueLabel.Text = 'Reading: -'
        }

        if ($null -ne $script:Baseline) {
            $script:BaselineLabel.Text = "Baseline: $($script:Baseline)"
        }
        else {
            $script:BaselineLabel.Text = 'Baseline: -'
        }

        if ($null -ne $script:BreathThreshold) {
            $script:ThresholdLabel.Text = "Breath threshold: $($script:BreathThreshold)"
        }
        else {
            $script:ThresholdLabel.Text = 'Breath threshold: -'
        }

        if ($script:State -eq 'Unlocked') {
            $script:NextCheckLabel.Text = "Next check: $($script:NextCheckUtc.ToLocalTime().ToString('HH:mm:ss'))"
        }
        elseif ($null -ne $script:CurrentCheckStartedUtc -and $script:State -eq 'Calibrating') {
            $remaining = [Math]::Max(0, $CalibrationSeconds - ([DateTime]::UtcNow - $script:CurrentCheckStartedUtc).TotalSeconds)
            $script:NextCheckLabel.Text = "Calibration remaining: {0:N1}s" -f $remaining
        }
        else {
            $script:NextCheckLabel.Text = "Sensor port: $($script:SensorPort)"
        }
    }
    catch {
        # Never let a GUI update kill the monitoring process.
    }
}

function Build-LockForm {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.Screen]$Screen,
        [Parameter(Mandatory)]
        [bool]$IsPrimary
    )

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Bounds = $Screen.Bounds
    $form.BackColor = [System.Drawing.Color]::Black
    $form.ForeColor = [System.Drawing.Color]::White
    $form.KeyPreview = $true
    $form.Text = 'AlcoholGuard'

    $form.add_FormClosing({
        param($sender, $eventArgs)
        if ($script:State -ne 'Unlocked') {
            $eventArgs.Cancel = $true
        }
    })

    $status = New-Object System.Windows.Forms.Label
    $status.AutoSize = $false
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $status.Font = New-Object System.Drawing.Font('Segoe UI', 32, [System.Drawing.FontStyle]::Bold)
    $status.ForeColor = [System.Drawing.Color]::White
    $status.BackColor = [System.Drawing.Color]::Black
    $status.Width = [int]($Screen.Bounds.Width * 0.85)
    $status.Height = 100
    $status.Left = [int](($Screen.Bounds.Width - $status.Width) / 2)
    $status.Top = [int]($Screen.Bounds.Height * 0.34)
    $status.Text = 'Connect sensor'
    $form.Controls.Add($status)
    $script:StatusLabels += $status

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.AutoSize = $false
    $valueLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $valueLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12)
    $valueLabel.ForeColor = [System.Drawing.Color]::Silver
    $valueLabel.BackColor = [System.Drawing.Color]::Black
    $valueLabel.Width = 360
    $valueLabel.Height = 28
    $valueLabel.Left = [int](($Screen.Bounds.Width - 360) / 2)
    $valueLabel.Top = [int]($Screen.Bounds.Height * 0.50)
    $valueLabel.Text = 'Reading: -'
    $form.Controls.Add($valueLabel)
    if ($IsPrimary) { $script:CurrentValueLabel = $valueLabel }

    $baselineLabel = New-Object System.Windows.Forms.Label
    $baselineLabel.AutoSize = $false
    $baselineLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $baselineLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $baselineLabel.ForeColor = [System.Drawing.Color]::Gray
    $baselineLabel.BackColor = [System.Drawing.Color]::Black
    $baselineLabel.Width = 360
    $baselineLabel.Height = 24
    $baselineLabel.Left = [int](($Screen.Bounds.Width - 360) / 2)
    $baselineLabel.Top = [int]($Screen.Bounds.Height * 0.54)
    $baselineLabel.Text = 'Baseline: -'
    $form.Controls.Add($baselineLabel)
    if ($IsPrimary) { $script:BaselineLabel = $baselineLabel }

    $thresholdLabel = New-Object System.Windows.Forms.Label
    $thresholdLabel.AutoSize = $false
    $thresholdLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $thresholdLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $thresholdLabel.ForeColor = [System.Drawing.Color]::Gray
    $thresholdLabel.BackColor = [System.Drawing.Color]::Black
    $thresholdLabel.Width = 360
    $thresholdLabel.Height = 24
    $thresholdLabel.Left = [int](($Screen.Bounds.Width - 360) / 2)
    $thresholdLabel.Top = [int]($Screen.Bounds.Height * 0.58)
    $thresholdLabel.Text = 'Breath threshold: -'
    $form.Controls.Add($thresholdLabel)
    if ($IsPrimary) { $script:ThresholdLabel = $thresholdLabel }

    $stateLabel = New-Object System.Windows.Forms.Label
    $stateLabel.AutoSize = $false
    $stateLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $stateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $stateLabel.ForeColor = [System.Drawing.Color]::DimGray
    $stateLabel.BackColor = [System.Drawing.Color]::Black
    $stateLabel.Width = 500
    $stateLabel.Height = 22
    $stateLabel.Left = [int](($Screen.Bounds.Width - 500) / 2)
    $stateLabel.Top = [int]($Screen.Bounds.Height * 0.62)
    $stateLabel.Text = 'State: NoSensor'
    $form.Controls.Add($stateLabel)
    if ($IsPrimary) { $script:StateLabel = $stateLabel }

    $nextLabel = New-Object System.Windows.Forms.Label
    $nextLabel.AutoSize = $false
    $nextLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $nextLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $nextLabel.ForeColor = [System.Drawing.Color]::DimGray
    $nextLabel.BackColor = [System.Drawing.Color]::Black
    $nextLabel.Width = 500
    $nextLabel.Height = 22
    $nextLabel.Left = [int](($Screen.Bounds.Width - 500) / 2)
    $nextLabel.Top = [int]($Screen.Bounds.Height * 0.65)
    $nextLabel.Text = 'Sensor port: -'
    $form.Controls.Add($nextLabel)
    if ($IsPrimary) { $script:NextCheckLabel = $nextLabel }

    if ($IsPrimary) {
        $passwordBox = New-Object System.Windows.Forms.TextBox
        $passwordBox.Width = 240
        $passwordBox.Height = 35
        $passwordBox.Left = [int](($Screen.Bounds.Width - 240) / 2)
        $passwordBox.Top = [int]($Screen.Bounds.Height * 0.71)
        $passwordBox.Font = New-Object System.Drawing.Font('Segoe UI', 15)
        $passwordBox.PasswordChar = '*'
        $passwordBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        $passwordBox.TabStop = $true
        $form.Controls.Add($passwordBox)
        $script:PasswordBox = $passwordBox

        $button = New-Object System.Windows.Forms.Button
        $button.Width = 180
        $button.Height = 36
        $button.Left = [int](($Screen.Bounds.Width - 180) / 2)
        $button.Top = [int]($Screen.Bounds.Height * 0.78)
        $button.Text = 'Unlock'
        $button.Font = New-Object System.Drawing.Font('Segoe UI', 11)
        $button.TabStop = $true
        $button.Add_Click({ Unlock-WithPassword })
        $form.Controls.Add($button)
        $script:PasswordButton = $button

        $passwordBox.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                Unlock-WithPassword
                $eventArgs.SuppressKeyPress = $true
                $eventArgs.Handled = $true
            }
        })
    }

    $script:Forms += $form
    return $form
}

function Show-LockOverlay {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    foreach ($form in $script:Forms) {
        try {
            $form.Show()
            $form.TopMost = $true
            $form.BringToFront()
        }
        catch {
        }
    }

    if ($null -ne $script:PasswordBox) {
        try { $script:PasswordBox.Focus() } catch { }
    }
}

function Hide-LockOverlay {
    foreach ($form in $script:Forms) {
        try { $form.Hide() } catch { }
    }
}

function Unlock-Screen {
    param(
        [string]$Reason = 'Unknown'
    )

    if ($script:State -eq 'Unlocked') {
        return
    }

    Set-State -NewState 'Unlocked'
    Write-GuardLog "Unlocked. Reason=$Reason"
    Set-UiMessage -Message 'Access granted'

    try {
        if ($script:Timer.Enabled) {
            # Keep timer alive so the next hourly check can lock again.
        }
    }
    catch {
    }

    Hide-LockOverlay
    Schedule-NextHourlyCheck
}

function Unlock-WithPassword {
    if ($null -eq $script:PasswordBox) {
        return
    }

    if ($script:PasswordBox.Text -eq $MasterPassword) {
        $script:PasswordBox.Clear()
        Unlock-Screen -Reason 'Master password'
        return
    }

    $script:PasswordBox.Clear()
    try { $script:PasswordBox.Focus() } catch { }
    Set-UiMessage -Message 'Wrong password - blow into the sensor'
    Write-GuardLog 'Invalid master password entered'
}

# ============================================================
# GLOBAL KEYBOARD HOOK
# ============================================================

function Initialize-KeyboardBlockerType {
    if ($null -ne ('AlcoholGuard.KeyboardBlocker' -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AlcoholGuard
{
    public static class KeyboardBlocker
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;

        private const int VK_TAB = 0x09;
        private const int VK_ESCAPE = 0x1B;
        private const int VK_F4 = 0x73;
        private const int VK_LWIN = 0x5B;
        private const int VK_RWIN = 0x5C;
        private const int VK_LMENU = 0xA4;
        private const int VK_RMENU = 0xA5;
        private const int VK_LCONTROL = 0xA2;
        private const int VK_RCONTROL = 0xA3;
        private const int VK_LSHIFT = 0xA0;
        private const int VK_RSHIFT = 0xA1;

        private static IntPtr _hook = IntPtr.Zero;
        private static LowLevelKeyboardProc _proc = HookCallback;

        public static void Install()
        {
            if (_hook != IntPtr.Zero) return;

            using (Process process = Process.GetCurrentProcess())
            using (ProcessModule module = process.MainModule)
            {
                _hook = SetWindowsHookEx(
                    WH_KEYBOARD_LL,
                    _proc,
                    GetModuleHandle(module.ModuleName),
                    0);
            }
        }

        public static void Uninstall()
        {
            if (_hook == IntPtr.Zero) return;
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }

        private static bool IsDown(int vk)
        {
            return (GetAsyncKeyState(vk) & 0x8000) != 0;
        }

        private static bool ShouldBlock(int vk)
        {
            bool alt = IsDown(VK_LMENU) || IsDown(VK_RMENU);
            bool ctrl = IsDown(VK_LCONTROL) || IsDown(VK_RCONTROL);
            bool shift = IsDown(VK_LSHIFT) || IsDown(VK_RSHIFT);
            bool win = IsDown(VK_LWIN) || IsDown(VK_RWIN);

            if (vk == VK_LWIN || vk == VK_RWIN) return true;
            if (win) return true;
            if (vk == VK_TAB && alt) return true;
            if (vk == VK_F4 && alt) return true;
            if (vk == VK_ESCAPE && alt) return true;
            if (vk == VK_ESCAPE && ctrl) return true;
            if (vk == VK_ESCAPE && ctrl && shift) return true;

            return false;
        }

        private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 &&
                (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN))
            {
                int vkCode = Marshal.ReadInt32(lParam);
                if (ShouldBlock(vkCode)) return (IntPtr)1;
            }

            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(
            int idHook,
            LowLevelKeyboardProc lpfn,
            IntPtr hMod,
            uint dwThreadId);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr CallNextHookEx(
            IntPtr hhk,
            int nCode,
            IntPtr wParam,
            IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);
    }
}
'@
}

function Start-KeyboardHook {
    Initialize-KeyboardBlockerType
    [AlcoholGuard.KeyboardBlocker]::Install()
    $script:KeyboardHookInstalled = $true
    Write-GuardLog 'Keyboard hook installed'
}

function Stop-KeyboardHook {
    try {
        if ($script:KeyboardHookInstalled -and $null -ne ('AlcoholGuard.KeyboardBlocker' -as [type])) {
            [AlcoholGuard.KeyboardBlocker]::Uninstall()
        }
    }
    catch {
    }
    $script:KeyboardHookInstalled = $false
}

# ============================================================
# CHECK CYCLE
# ============================================================

function Start-NewCheck {
    Write-GuardLog 'Starting new hourly check'

    $script:CurrentCheckStartedUtc = [DateTime]::UtcNow
    $script:LastUiValue = $null
    $script:NextCheckUtc = $null

    Set-State -NewState 'NoSensor'
    Show-LockOverlay

    if ($null -ne $script:PasswordBox) {
        try {
            $script:PasswordBox.Clear()
            $script:PasswordBox.Focus()
        }
        catch {
        }
    }

    # If a previous serial connection died, try to reconnect.
    if ($script:SensorConnected -and ($null -eq $script:SerialPort -or -not $script:SerialPort.IsOpen)) {
        Close-SerialPort
    }

    if (-not (Find-Arduino)) {
        Write-GuardLog 'No Arduino sensor detected'
    }

    Update-Ui
}

function Schedule-NextHourlyCheck {
    $script:NextCheckUtc = [DateTime]::UtcNow.AddSeconds($HourlyCheckSeconds)
    Write-GuardLog "Next hourly check at $($script:NextCheckUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
}

# ============================================================
# TASK SCHEDULER
# ============================================================

function Register-GuardTask {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Cannot determine the current script path.'
    }

    $powershellExe = Join-Path $PSHome 'powershell.exe'
    if (-not (Test-Path $powershellExe)) {
        $powershellExe = (Get-Command powershell.exe).Source
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
    }

    # Pass the script path as one quoted value in a single argument string.
    # This avoids the broken Start-Process -ArgumentList quoting used before.
    $escapedScriptPath = $PSCommandPath.Replace('"', '\"')
    $debugArgument = if ($DebugMode) { ' -DebugMode' } else { '' }
    $argumentString = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Run{1}' -f $escapedScriptPath, $debugArgument

    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $argumentString
    $trigger = New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Seconds 5)

    $userId = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'AlcoholBreathGuard hourly sensor overlay' `
        -Force | Out-Null

    Write-Host "Scheduled task '$TaskName' installed."
}

function Remove-GuardTask {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Host "Scheduled task '$TaskName' not found."
            return
        }

        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed."
    }
    catch {
        Write-Warning "Could not remove scheduled task: $($_.Exception.Message)"
    }
}

# ============================================================
# SELF TESTS
# ============================================================

function Invoke-SelfTest {
    $script:TestPassed = 0
    $script:TestFailed = 0

    function Assert-Test {
        param(
            [string]$Name,
            [bool]$Condition
        )

        if ($Condition) {
            Write-Host "[PASS] $Name" -ForegroundColor Green
            $script:TestPassed++
        }
        else {
            Write-Host "[FAIL] $Name" -ForegroundColor Red
            $script:TestFailed++
        }
    }

    Write-Host '=== AlcoholGuard SelfTest ===' -ForegroundColor Cyan

    $baselineData = @(198,201,200,199,202,201,200,198,201,200)
    [double]$baseline = [double](Get-Median -Values $baselineData)
    Assert-Test 'Median baseline is 200' ($baseline -eq 200)

    [double]$threshold = [Math]::Max(
        [double]($baseline + [double]$BlowDelta),
        [double]([Math]::Ceiling($baseline * [double]$BlowRatio))
    )
    Assert-Test 'Breath threshold is above baseline' ($threshold -gt $baseline)

    $recent = @(200, [int][Math]::Round($threshold + 5))
    $hits = @($recent | Where-Object { $_ -ge $threshold }).Count
    Assert-Test 'Single spike is rejected' ($hits -lt $BreathRequiredHits)

    $recent = @([int][Math]::Round($threshold + 5), [int][Math]::Round($threshold + 20), 201)
    $hits = @($recent | Where-Object { $_ -ge $threshold }).Count
    Assert-Test 'Two elevated samples confirm breath' ($hits -ge $BreathRequiredHits)

    $safe = @(340, 330, 345)
    $safeCount = @($safe | Where-Object { $_ -le $AlcoholLimit }).Count
    Assert-Test 'Three safe readings allow unlock' ($safeCount -ge $SafeReadingsRequired)

    $unsafe = @(500, 520, 490, 470)
    $unsafeSafeCount = @($unsafe | Where-Object { $_ -le $AlcoholLimit }).Count
    Assert-Test 'High readings do not allow unlock' ($unsafeSafeCount -lt $SafeReadingsRequired)

    $oscillating = @(260, 360, 340, 370, 330)
    $oscSafeCount = @($oscillating | Where-Object { $_ -le $AlcoholLimit }).Count
    Assert-Test 'Non-consecutive safe values do not unlock by themselves' ($oscSafeCount -lt $SafeReadingsRequired)

    Assert-Test 'Master password is 1989' ($MasterPassword -eq '1989')
    Assert-Test 'Alcohol limit is 350' ($AlcoholLimit -eq 350)
    Assert-Test 'Hourly interval is 3600 seconds' ($HourlyCheckSeconds -eq 3600)

    # State-machine simulation: sober person.
    $simBaseline = 200
    $simThreshold = 245
    $simState = 'WaitingForBreath'
    $simRecent = New-Object System.Collections.Generic.List[int]
    $simSafe = 0
    $simSequence = @(205, 250, 270, 340, 330, 345)

    foreach ($value in $simSequence) {
        $simRecent.Add($value)
        while ($simRecent.Count -gt 3) { $simRecent.RemoveAt(0) }

        if ($simState -eq 'WaitingForBreath') {
            $simHits = @($simRecent | Where-Object { $_ -ge $simThreshold }).Count
            if ($simHits -ge $BreathRequiredHits -or $value -ge ($simBaseline + $StrongBreathDelta)) {
                $simState = 'BreathDetected'
            }
        }
        elseif ($simState -eq 'BreathDetected') {
            if ($value -le $AlcoholLimit) { $simSafe++ } else { $simSafe = 0 }
            if ($simSafe -ge $SafeReadingsRequired) { $simState = 'Unlocked' }
        }
    }

    Assert-Test 'Sober breath sequence reaches Unlocked' ($simState -eq 'Unlocked')

    # State-machine simulation: alcohol above limit.
    $simState = 'WaitingForBreath'
    $simRecent = New-Object System.Collections.Generic.List[int]
    $simSafe = 0
    $simSequence = @(205, 250, 270, 500, 520, 510, 490)

    foreach ($value in $simSequence) {
        $simRecent.Add($value)
        while ($simRecent.Count -gt 3) { $simRecent.RemoveAt(0) }

        if ($simState -eq 'WaitingForBreath') {
            $simHits = @($simRecent | Where-Object { $_ -ge $simThreshold }).Count
            if ($simHits -ge $BreathRequiredHits -or $value -ge ($simBaseline + $StrongBreathDelta)) {
                $simState = 'BreathDetected'
            }
        }
        elseif ($simState -eq 'BreathDetected') {
            if ($value -le $AlcoholLimit) { $simSafe++ } else { $simSafe = 0 }
            if ($simSafe -ge $SafeReadingsRequired) { $simState = 'Unlocked' }
        }
    }

    Assert-Test 'Above-limit sequence stays locked' ($simState -ne 'Unlocked')

    Write-Host ''
    Write-Host "Passed: $script:TestPassed"
    Write-Host "Failed: $script:TestFailed"
    Write-Host ''

    if ($script:TestFailed -gt 0) {
        exit 1
    }

    exit 0
}

# ============================================================
# MAIN RUNTIME
# ============================================================

function Start-GuardRuntime {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $mutexName = "Global\AlcoholGuard-$env:USERNAME"
    $createdNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)

    if (-not $createdNew) {
        Write-Host 'AlcoholGuard is already running.'
        return
    }

    try {
        $screens = @([System.Windows.Forms.Screen]::AllScreens)
        foreach ($screen in $screens) {
            $isPrimary = $screen.Primary
            $null = Build-LockForm -Screen $screen -IsPrimary $isPrimary
        }

        # Do not repeatedly recreate hooks; install once for the lifetime of the process.
        Start-KeyboardHook

        $script:Timer = New-Object System.Windows.Forms.Timer
        $script:Timer.Interval = $UiTickMs

        $script:Timer.Add_Tick({
            try {
                $now = [DateTime]::UtcNow

                # Re-assert topmost state while locked.
                if ($script:State -ne 'Unlocked') {
                    foreach ($form in $script:Forms) {
                        try {
                            if (-not $form.Visible) { $form.Show() }
                            $form.TopMost = $true
                            $form.BringToFront()
                        }
                        catch {
                        }
                    }
                }

                # Hourly cycle.
                if ($script:State -eq 'Unlocked' -and $null -ne $script:NextCheckUtc -and $now -ge $script:NextCheckUtc) {
                    Start-NewCheck
                }

                # Sensor reconnect / discovery while locked.
                if ($script:State -ne 'Unlocked' -and -not $script:SensorConnected) {
                    if ($null -eq $script:LastScanUtc -or ([DateTime]::UtcNow - $script:LastScanUtc).TotalMilliseconds -ge $PortScanIntervalMs) {
                        $script:LastScanUtc = [DateTime]::UtcNow
                        [void](Find-Arduino)
                    }
                }

                # Sensor polling.
                if ($script:State -ne 'Unlocked' -and $script:SensorConnected) {
                    if ($null -eq $script:LastSampleUtc -or ([DateTime]::UtcNow - $script:LastSampleUtc).TotalMilliseconds -ge $SensorReadEveryMs) {
                        $script:LastSampleUtc = [DateTime]::UtcNow
                        $value = Read-SensorValue
                        if ($null -ne $value) {
                            Process-SensorReading -Value $value
                        }
                    }
                }

                # If sensor disappeared, reconnect on the next scan.
                if ($script:SensorConnected -and ($null -eq $script:SerialPort -or -not $script:SerialPort.IsOpen)) {
                    Write-GuardLog 'Sensor disconnected'
                    Close-SerialPort
                }

                Update-Ui
            }
            catch {
                Write-GuardLog "Timer error: $($_.Exception.Message)"
            }
        })

        $script:LastScanUtc = [DateTime]::MinValue
        $script:LastSampleUtc = [DateTime]::MinValue

        # Immediate first check.
        Start-NewCheck

        $script:Timer.Start()
        Write-GuardLog 'Runtime started'

        [System.Windows.Forms.Application]::Run()
    }
    finally {
        Write-GuardLog 'Runtime stopping'

        try {
            if ($null -ne $script:Timer) { $script:Timer.Stop() }
        }
        catch {
        }

        Stop-KeyboardHook
        Close-SerialPort

        foreach ($form in $script:Forms) {
            try {
                $form.Close()
                $form.Dispose()
            }
            catch {
            }
        }

        $script:Forms = @()

        try {
            if ($null -ne $script:Mutex) {
                $script:Mutex.ReleaseMutex()
                $script:Mutex.Dispose()
            }
        }
        catch {
        }
    }
}

# ============================================================
# ENTRY POINT
# ============================================================

if ($SelfTest) {
    Invoke-SelfTest
}

if ($CleanUp) {
    Remove-GuardTask
    exit 0
}

if (-not $Run) {
    Write-Host 'Installing AlcoholGuard...'
    Register-GuardTask

    $powershellExe = Join-Path $PSHome 'powershell.exe'
    if (-not (Test-Path $powershellExe)) {
        $powershellExe = (Get-Command powershell.exe).Source
    }

    # Use ProcessStartInfo.ArgumentList when available is not reliable on every
    # PowerShell 5.1 environment, so build one explicit argument string.
    $escapedScriptPath = $PSCommandPath.Replace('"', '\"')
    $debugArgument = if ($DebugMode) { ' -DebugMode' } else { '' }
    $runArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Run{1}' -f $escapedScriptPath, $debugArgument

    Start-Process -FilePath $powershellExe -ArgumentList $runArguments -WindowStyle Hidden
    exit 0
}

Start-GuardRuntime
