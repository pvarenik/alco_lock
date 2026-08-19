#requires -Version 5.1

<#
    AlcoholGuard.ps1

    Режимы:
      .\AlcoholGuard.ps1
          - установить задачу и запустить защиту

      .\AlcoholGuard.ps1 -Run
          - используется самим Task Scheduler

      .\AlcoholGuard.ps1 -CleanUp
          - удалить задачу

      .\AlcoholGuard.ps1 -SelfTest
          - проверить алгоритм без Arduino/GUI

    Arduino:
      MQ-3 AO -> A0
      Arduino Serial -> 9600 baud
      Ожидаются строки:
        123
        247
        351
        ...

    Логика:
      1. Если Arduino не найден -> "подключите датчик"
      2. Если найден -> калибровка чистого воздуха
      3. После калибровки -> "дыхните в датчик"
      4. Если обнаружен характерный подъём -> считаем выдох обнаруженным
      5. После выдоха ждём 3 последовательных значения <= 350
      6. Только после этого разблокируем
      7. Мастер-пароль "1989" разблокирует сразу
#>

param(
    [switch]$Run,
    [switch]$CleanUp,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CONFIG
# ============================================================

$TaskName = 'AlcoholBreathGuard'
$MasterPassword = '1989'

# Если $null -> автоматический поиск COM-порта.
# Можно жестко указать:
# $PreferredComPort = 'COM5'
$PreferredComPort = $null

$BaudRate = 9600

# MQ-3 / Arduino
$AlcoholLimit = 350

# Интервал Arduino из твоего кода
$SampleIntervalMs = 500

# Калибровка чистого воздуха
$CalibrationSeconds = 10

# Выброс считается выдохом, если:
#   значение >= baseline + BlowDelta
# ИЛИ
#   значение >= baseline * BlowRatio
$BlowDelta = 45
$BlowRatio = 1.15

# Чтобы случайный единичный скачок не считался выдохом:
# минимум 2 измерения из последних 3 должны быть выше порога
$BreathWindowSize = 3
$BreathRequiredHits = 2

# После выдоха нужно несколько последовательных значений <= 350.
$SafeReadingsRequired = 3

# Как часто искать Arduino, если его нет
$PortScanIntervalMs = 2000

# ============================================================
# GLOBAL STATE
# ============================================================

$script:SerialPort = $null
$script:SensorPort = $null

$script:SensorConnected = $false

$script:State = 'NoSensor'
# Возможные состояния:
#   NoSensor
#   Calibrating
#   WaitingForBreath
#   BreathDetected
#   Unlocked

$script:Baseline = $null
$script:BreathThreshold = $null

$script:CalibrationReadings = New-Object System.Collections.Generic.List[int]
$script:RecentReadings = New-Object System.Collections.Generic.List[int]

$script:SafeReadings = 0
$script:LastScanMs = 0
$script:LastSampleMs = 0
$script:CalibrationStarted = $null

$script:Forms = @()
$script:StatusLabels = @()
$script:CurrentValueLabel = $null
$script:BaselineLabel = $null
$script:ThresholdLabel = $null
$script:PasswordBox = $null
$script:PasswordButton = $null

$script:LastUiMessage = ''

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

    $sorted = $Values | Sort-Object
    $count = $sorted.Count

    if (($count % 2) -eq 1) {
        return [double]$sorted[[int]($count / 2)]
    }

    return (
        ([double]$sorted[($count / 2) - 1] +
         [double]$sorted[$count / 2]) / 2
    )
}

function Reset-SensorState {
    $script:Baseline = $null
    $script:BreathThreshold = $null

    $script:CalibrationReadings.Clear()
    $script:RecentReadings.Clear()

    $script:SafeReadings = 0
    $script:CalibrationStarted = $null

    if ($script:SensorConnected) {
        $script:State = 'Calibrating'
        $script:CalibrationStarted = [DateTime]::UtcNow
    }
    else {
        $script:State = 'NoSensor'
    }
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
        # intentionally ignored
    }

    $script:SerialPort = $null
    $script:SensorPort = $null
    $script:SensorConnected = $false

    Reset-SensorState
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

        # Даём Arduino немного времени начать выдавать строки.
        Start-Sleep -Milliseconds 250

        $deadline = [DateTime]::UtcNow.AddMilliseconds(750)

        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $line = $port.ReadLine().Trim()

                if (Test-NumericSensorLine $line) {
                    return $port
                }
            }
            catch [TimeoutException] {
                # Нормально.
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
        catch {}

        return $null
    }
}

function Find-Arduino {
    if ($script:SensorConnected -and
        $null -ne $script:SerialPort -and
        $script:SerialPort.IsOpen) {

        return $true
    }

    $ports = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredComPort)) {
        $ports = @($PreferredComPort)
    }
    else {
        try {
            $ports = [System.IO.Ports.SerialPort]::GetPortNames() |
                Sort-Object
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

            Reset-SensorState

            return $true
        }
    }

    return $false
}

function Read-SensorValue {
    if (-not $script:SensorConnected -or
        $null -eq $script:SerialPort -or
        -not $script:SerialPort.IsOpen) {

        return $null
    }

    $latest = $null

    try {
        # Arduino пишет примерно раз в 500 ms.
        # Забираем все уже накопившиеся строки и используем последнюю.
        while ($true) {
            try {
                $line = $script:SerialPort.ReadLine().Trim()

                if (Test-NumericSensorLine $line) {
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
        Close-SerialPort
        return $null
    }
}

# ============================================================
# BREATH ALGORITHM
# ============================================================

function Start-Calibration {
    $script:CalibrationReadings.Clear()
    $script:RecentReadings.Clear()

    $script:Baseline = $null
    $script:BreathThreshold = $null
    $script:SafeReadings = 0

    $script:CalibrationStarted = [DateTime]::UtcNow
    $script:State = 'Calibrating'
}

function Add-SensorReading {
    param(
        [Parameter(Mandatory)]
        [int]$Value
    )

    # --------------------------------------------------------
    # Calibration
    # --------------------------------------------------------

    if ($script:State -eq 'Calibrating') {

        $script:CalibrationReadings.Add($Value)

        $elapsed = (
            [DateTime]::UtcNow -
            $script:CalibrationStarted
        ).TotalSeconds

        if (
            $elapsed -ge $CalibrationSeconds -and
            $script:CalibrationReadings.Count -ge 10
        ) {

            $baseline = Get-Median -Values @($script:CalibrationReadings)

            if ($baseline -lt 1) {
                $baseline = 1
            }

            $script:Baseline = [int][Math]::Round($baseline)

            $deltaThreshold = $script:Baseline + $BlowDelta

            $ratioThreshold = [int][Math]::Ceiling(
                $script:Baseline * $BlowRatio
            )

            $script:BreathThreshold = [Math]::Max(
                $deltaThreshold,
                $ratioThreshold
            )

            # Чтобы не выйти за диапазон Arduino
            $script:BreathThreshold =
                [Math]::Min(1023, $script:BreathThreshold)

            $script:RecentReadings.Clear()
            $script:SafeReadings = 0

            # ВАЖНО:
            # само по себе нахождение ниже 350 не разблокирует.
            # Сначала нужен обнаруженный выдох.
            $script:State = 'WaitingForBreath'
        }

        return
    }

    # --------------------------------------------------------
    # Store rolling window
    # --------------------------------------------------------

    $script:RecentReadings.Add($Value)

    while ($script:RecentReadings.Count -gt $BreathWindowSize) {
        $script:RecentReadings.RemoveAt(0)
    }

    # --------------------------------------------------------
    # Waiting for breath
    # --------------------------------------------------------

    if ($script:State -eq 'WaitingForBreath') {

        $hits = @(
            $script:RecentReadings |
            Where-Object {
                $_ -ge $script:BreathThreshold
            }
        ).Count

        # Защита от единичного случайного скачка
        if ($hits -ge $BreathRequiredHits) {

            $script:State = 'BreathDetected'
            $script:SafeReadings = 0

            return
        }

        # Очень сильный скачок можно считать выдохом сразу.
        if ($Value -ge ($script:Baseline + 120)) {

            $script:State = 'BreathDetected'
            $script:SafeReadings = 0

            return
        }

        return
    }

    # --------------------------------------------------------
    # Breath detected: wait for <= 350
    # --------------------------------------------------------

    if ($script:State -eq 'BreathDetected') {

        if ($Value -le $AlcoholLimit) {
            $script:SafeReadings++
        }
        else {
            $script:SafeReadings = 0
        }

        if ($script:SafeReadings -ge $SafeReadingsRequired) {
            Unlock-Screen
        }

        return
    }
}

# ============================================================
# UI
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
        catch {}
    }
}

function Update-Ui {
    try {
        switch ($script:State) {

            'NoSensor' {
                Set-UiMessage 'подключите датчик'
            }

            'Calibrating' {
                Set-UiMessage 'калибровка датчика... не дышите в датчик'
            }

            'WaitingForBreath' {
                Set-UiMessage 'дыхните в датчик'
            }

            'BreathDetected' {
                Set-UiMessage 'выдох обнаружен — проверка показаний...'
            }

            'Unlocked' {
                Set-UiMessage 'доступ разрешён'
            }
        }

        if ($null -ne $script:CurrentValueLabel) {

            if (
                $script:SensorConnected -and
                $script:LastUiValue -ne $null
            ) {
                $script:CurrentValueLabel.Text =
                    "Показания: $($script:LastUiValue)"
            }
            else {
                $script:CurrentValueLabel.Text =
                    "Показания: —"
            }
        }

        if ($null -ne $script:BaselineLabel) {
            if ($null -ne $script:Baseline) {
                $script:BaselineLabel.Text =
                    "База: $($script:Baseline)"
            }
            else {
                $script:BaselineLabel.Text =
                    "База: —"
            }
        }

        if ($null -ne $script:ThresholdLabel) {
            if ($null -ne $script:BreathThreshold) {
                $script:ThresholdLabel.Text =
                    "Порог выдоха: $($script:BreathThreshold)"
            }
            else {
                $script:ThresholdLabel.Text =
                    "Порог выдоха: —"
            }
        }
    }
    catch {
        # GUI update must never kill the monitoring process.
    }
}

function Unlock-Screen {
    if ($script:State -eq 'Unlocked') {
        return
    }

    $script:State = 'Unlocked'

    Set-UiMessage 'доступ разрешён'

    Stop-KeyboardHook

    foreach ($form in $script:Forms) {
        try {
            $form.Hide()
        }
        catch {}
    }

    if ($null -ne $script:Timer) {
        try {
            $script:Timer.Stop()
        }
        catch {}
    }
}

function Unlock-WithPassword {
    if ($null -eq $script:PasswordBox) {
        return
    }

    if ($script:PasswordBox.Text -eq $MasterPassword) {
        $script:PasswordBox.Clear()
        Unlock-Screen
        return
    }

    $script:PasswordBox.Clear()
    $script:PasswordBox.Focus()

    Set-UiMessage 'неверный пароль — дыхните в датчик'
}

function New-LockForm {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.Screen]$Screen,

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

    # Нельзя закрыть крестиком / Alt+F4 / программным закрытием формы.
    $form.add_FormClosing({
        param($sender, $event)

        if ($script:State -ne 'Unlocked') {
            $event.Cancel = $true
        }
    })

    # --------------------------------------------------------
    # Main status
    # --------------------------------------------------------

    $status = New-Object System.Windows.Forms.Label

    $status.AutoSize = $false
    $status.TextAlign =
        [System.Drawing.ContentAlignment]::MiddleCenter

    $status.Font = New-Object System.Drawing.Font(
        'Segoe UI',
        32,
        [System.Drawing.FontStyle]::Bold
    )

    $status.ForeColor = [System.Drawing.Color]::White
    $status.BackColor = [System.Drawing.Color]::Black

    $status.Width = [int]($Screen.Bounds.Width * 0.8)
    $status.Height = 100

    $status.Left =
        [int](($Screen.Bounds.Width - $status.Width) / 2)

    $status.Top =
        [int]($Screen.Bounds.Height * 0.38)

    $form.Controls.Add($status)

    $script:StatusLabels += $status

    # --------------------------------------------------------
    # Sensor info
    # --------------------------------------------------------

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.AutoSize = $false
    $valueLabel.TextAlign =
        [System.Drawing.ContentAlignment]::MiddleCenter

    $valueLabel.Font = New-Object System.Drawing.Font(
        'Segoe UI',
        12
    )

    $valueLabel.ForeColor =
        [System.Drawing.Color]::Silver

    $valueLabel.BackColor = [System.Drawing.Color]::Black

    $valueLabel.Width = 300
    $valueLabel.Height = 30

    $valueLabel.Left =
        [int](($Screen.Bounds.Width - 300) / 2)

    $valueLabel.Top =
        [int]($Screen.Bounds.Height * 0.51)

    $valueLabel.Text = 'Показания: —'

    $form.Controls.Add($valueLabel)

    if ($IsPrimary) {
        $script:CurrentValueLabel = $valueLabel
    }

    # --------------------------------------------------------
    # Baseline
    # --------------------------------------------------------

    $baselineLabel = New-Object System.Windows.Forms.Label
    $baselineLabel.AutoSize = $false
    $baselineLabel.TextAlign =
        [System.Drawing.ContentAlignment]::MiddleCenter

    $baselineLabel.Font = New-Object System.Drawing.Font(
        'Segoe UI',
        10
    )

    $baselineLabel.ForeColor =
        [System.Drawing.Color]::Gray

    $baselineLabel.BackColor = [System.Drawing.Color]::Black

    $baselineLabel.Width = 300
    $baselineLabel.Height = 25

    $baselineLabel.Left =
        [int](($Screen.Bounds.Width - 300) / 2)

    $baselineLabel.Top =
        [int]($Screen.Bounds.Height * 0.55)

    $baselineLabel.Text = 'База: —'

    $form.Controls.Add($baselineLabel)

    if ($IsPrimary) {
        $script:BaselineLabel = $baselineLabel
    }

    # --------------------------------------------------------
    # Breath threshold
    # --------------------------------------------------------

    $thresholdLabel = New-Object System.Windows.Forms.Label
    $thresholdLabel.AutoSize = $false
    $thresholdLabel.TextAlign =
        [System.Drawing.ContentAlignment]::MiddleCenter

    $thresholdLabel.Font = New-Object System.Drawing.Font(
        'Segoe UI',
        10
    )

    $thresholdLabel.ForeColor =
        [System.Drawing.Color]::Gray

    $thresholdLabel.BackColor = [System.Drawing.Color]::Black

    $thresholdLabel.Width = 300
    $thresholdLabel.Height = 25

    $thresholdLabel.Left =
        [int](($Screen.Bounds.Width - 300) / 2)

    $thresholdLabel.Top =
        [int]($Screen.Bounds.Height * 0.59)

    $thresholdLabel.Text = 'Порог выдоха: —'

    $form.Controls.Add($thresholdLabel)

    if ($IsPrimary) {
        $script:ThresholdLabel = $thresholdLabel
    }

    # --------------------------------------------------------
    # Password area
    # --------------------------------------------------------

    if ($IsPrimary) {

        $passwordBox = New-Object System.Windows.Forms.TextBox

        $passwordBox.Width = 240
        $passwordBox.Height = 35

        $passwordBox.Left =
            [int](($Screen.Bounds.Width - 240) / 2)

        $passwordBox.Top =
            [int]($Screen.Bounds.Height * 0.66)

        $passwordBox.Font = New-Object System.Drawing.Font(
            'Segoe UI',
            15
        )

        $passwordBox.PasswordChar = '*'
        $passwordBox.TextAlign =
            [System.Windows.Forms.HorizontalAlignment]::Center

        $form.Controls.Add($passwordBox)

        $script:PasswordBox = $passwordBox

        $passwordButton = New-Object System.Windows.Forms.Button

        $passwordButton.Width = 180
        $passwordButton.Height = 36

        $passwordButton.Left =
            [int](($Screen.Bounds.Width - 180) / 2)

        $passwordButton.Top =
            [int]($Screen.Bounds.Height * 0.73)

        $passwordButton.Text = 'Разблокировать'
        $passwordButton.Font = New-Object System.Drawing.Font(
            'Segoe UI',
            11
        )

        $passwordButton.Add_Click({
            Unlock-WithPassword
        })

        $form.Controls.Add($passwordButton)

        $script:PasswordButton = $passwordButton

        $passwordBox.Add_KeyDown({
            param($sender, $event)

            if ($event.KeyCode -eq
                [System.Windows.Forms.Keys]::Enter) {

                Unlock-WithPassword
                $event.SuppressKeyPress = $true
                $event.Handled = $true
            }
        })

        $passwordBox.Focus()
    }

    $script:Forms += $form

    return $form
}

# ============================================================
# GLOBAL KEYBOARD HOOK
# ============================================================

function Initialize-KeyboardHookType {

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
        private const int VK_DELETE = 0x2E;

        private static IntPtr _hook = IntPtr.Zero;
        private static LowLevelKeyboardProc _proc = HookCallback;

        public static bool Enabled { get; private set; }

        public static void Install()
        {
            if (_hook != IntPtr.Zero)
                return;

            using (Process process = Process.GetCurrentProcess())
            using (ProcessModule module = process.MainModule)
            {
                _hook = SetWindowsHookEx(
                    WH_KEYBOARD_LL,
                    _proc,
                    GetModuleHandle(module.ModuleName),
                    0
                );
            }

            Enabled = (_hook != IntPtr.Zero);
        }

        public static void Uninstall()
        {
            if (_hook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hook);
                _hook = IntPtr.Zero;
            }

            Enabled = false;
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

            // Windows key всегда блокируем.
            if (vk == VK_LWIN || vk == VK_RWIN)
                return true;

            // Alt+Tab
            if (vk == VK_TAB && alt)
                return true;

            // Alt+F4
            if (vk == VK_F4 && alt)
                return true;

            // Alt+Esc
            if (vk == VK_ESCAPE && alt)
                return true;

            // Ctrl+Esc
            if (vk == VK_ESCAPE && ctrl)
                return true;

            // Ctrl+Shift+Esc => Task Manager
            if (vk == VK_ESCAPE && ctrl && shift)
                return true;

            // Win+...
            if ((vk != VK_LWIN && vk != VK_RWIN) &&
                (IsDown(VK_LWIN) || IsDown(VK_RWIN)))
                return true;

            return false;
        }

        private static IntPtr HookCallback(
            int nCode,
            IntPtr wParam,
            IntPtr lParam)
        {
            if (nCode >= 0 &&
                (wParam == (IntPtr)WM_KEYDOWN ||
                 wParam == (IntPtr)WM_SYSKEYDOWN))
            {
                int vkCode = Marshal.ReadInt32(lParam);

                if (ShouldBlock(vkCode))
                    return (IntPtr)1;
            }

            return CallNextHookEx(
                _hook,
                nCode,
                wParam,
                lParam
            );
        }

        private delegate IntPtr LowLevelKeyboardProc(
            int nCode,
            IntPtr wParam,
            IntPtr lParam
        );

        [DllImport("user32.dll", CharSet = CharSet.Auto,
                   SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(
            int idHook,
            LowLevelKeyboardProc lpfn,
            IntPtr hMod,
            uint dwThreadId
        );

        [DllImport("user32.dll",
                   CharSet = CharSet.Auto,
                   SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(
            IntPtr hhk
        );

        [DllImport("user32.dll",
                   CharSet = CharSet.Auto,
                   SetLastError = true)]
        private static extern IntPtr CallNextHookEx(
            IntPtr hhk,
            int nCode,
            IntPtr wParam,
            IntPtr lParam
        );

        [DllImport("kernel32.dll",
                   CharSet = CharSet.Auto,
                   SetLastError = true)]
        private static extern IntPtr GetModuleHandle(
            string lpModuleName
        );

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(
            int vKey
        );
    }
}
'@
}

function Start-KeyboardHook {
    Initialize-KeyboardHookType
    [AlcoholGuard.KeyboardBlocker]::Install()
}

function Stop-KeyboardHook {
    try {
        if ($null -ne ('AlcoholGuard.KeyboardBlocker' -as [type])) {
            [AlcoholGuard.KeyboardBlocker]::Uninstall()
        }
    }
    catch {}
}

# ============================================================
# TASK SCHEDULER
# ============================================================

function Register-GuardTask {

    $scriptPath = $PSCommandPath

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'Не удалось определить путь к .ps1 файлу.'
    }

    $powershellExe = Join-Path $PSHome 'powershell.exe'

    if (-not (Test-Path $powershellExe)) {
        $powershellExe = (Get-Command powershell.exe).Source
    }

    try {
        Unregister-ScheduledTask `
            -TaskName $TaskName `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
    catch {}

    $arguments =
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
        "-File `"$scriptPath`" -Run"

    $action = New-ScheduledTaskAction `
        -Execute $powershellExe `
        -Argument $arguments

    $trigger = New-ScheduledTaskTrigger -AtLogOn

    $userId = "$env:USERDOMAIN\$env:USERNAME"

    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -LogonType Interactive `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Alcohol sensor screen guard' `
        -Force | Out-Null

    Write-Host "Задача '$TaskName' установлена."
}

function Remove-GuardTask {

    try {
        $task = Get-ScheduledTask `
            -TaskName $TaskName `
            -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            Stop-ScheduledTask `
                -TaskName $TaskName `
                -ErrorAction SilentlyContinue

            Unregister-ScheduledTask `
                -TaskName $TaskName `
                -Confirm:$false

            Write-Host "Задача '$TaskName' удалена."
        }
        else {
            Write-Host "Задача '$TaskName' не найдена."
        }
    }
    catch {
        Write-Warning "Не удалось удалить задачу: $($_.Exception.Message)"
    }
}

# ============================================================
# SELF TEST
# ============================================================

function Invoke-SelfTest {

    Write-Host ''
    Write-Host '=== AlcoholGuard SelfTest ===' -ForegroundColor Cyan
    Write-Host ''

    $passed = 0
    $failed = 0

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

    $script:TestPassed = 0
    $script:TestFailed = 0

    # --------------------------------------------------------
    # Test 1: baseline
    # --------------------------------------------------------

    $baselineData = @(198,201,200,199,202,201,200,198,201,200)

    $baseline = Get-Median -Values $baselineData

    Assert-Test `
        'Baseline вычисляется корректно' `
        ($baseline -eq 200)

    # --------------------------------------------------------
    # Test 2: breath threshold
    # --------------------------------------------------------

    $testThreshold = [Math]::Max(
        ($baseline + $BlowDelta),
        [int][Math]::Ceiling($baseline * $BlowRatio)
    )

    Assert-Test `
        'Порог выдоха выше baseline' `
        ($testThreshold -gt $baseline)

    # --------------------------------------------------------
    # Test 3: false single spike
    # --------------------------------------------------------

    $recent = @(200, $testThreshold + 5)

    $hits = @(
        $recent |
        Where-Object { $_ -ge $testThreshold }
    ).Count

    Assert-Test `
        'Одиночный скачок НЕ считается выдохом' `
        ($hits -lt $BreathRequiredHits)

    # --------------------------------------------------------
    # Test 4: real breath
    # --------------------------------------------------------

    $recent = @(
        $testThreshold + 10,
        $testThreshold + 20,
        260
    )

    $hits = @(
        $recent |
        Where-Object { $_ -ge $testThreshold }
    ).Count

    Assert-Test `
        'Два повышенных значения считаются выдохом' `
        ($hits -ge $BreathRequiredHits)

    # --------------------------------------------------------
    # Test 5: sober breath -> unlock
    # --------------------------------------------------------

    $safeSequence = @(300, 280, 310)

    Assert-Test `
        'После выдоха значения <=350 считаются безопасными' `
        (
            (
                $safeSequence |
                Where-Object { $_ -le $AlcoholLimit }
            ).Count -eq 3
        )

    # --------------------------------------------------------
    # Test 6: alcoholic sequence -> stays locked
    # --------------------------------------------------------

    $unsafeSequence = @(500, 520, 490)

    Assert-Test `
        'Значения >350 не дают разблокировку' `
        (
            (
                $unsafeSequence |
                Where-Object { $_ -le $AlcoholLimit }
            ).Count -lt $SafeReadingsRequired
        )

    # --------------------------------------------------------
    # Test 7: password
    # --------------------------------------------------------

    Assert-Test `
        'Мастер-пароль равен ожидаемому' `
        ($MasterPassword -eq '1989')

    # --------------------------------------------------------
    # Test 8: limit
    # --------------------------------------------------------

    Assert-Test `
        'Лимит алкоголя установлен в 350' `
        ($AlcoholLimit -eq 350)

    Write-Host ''
    Write-Host "ИТОГО: $script:TestPassed passed, $script:TestFailed failed."
    Write-Host ''

    if ($script:TestFailed -gt 0) {
        exit 1
    }

    exit 0
}

# ============================================================
# MAIN GUI / MONITOR
# ============================================================

function Start-Guard {

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Один процесс
    $mutexName =
        "AlcoholGuard-$($env:USERNAME)-$([Environment]::UserName)"

    $createdNew = $false

    $mutex = New-Object System.Threading.Mutex(
        $false,
        $mutexName,
        [ref]$createdNew
    )

    if (-not $createdNew) {
        Write-Host 'AlcoholGuard уже запущен.'
        return
    }

    try {

        # ----------------------------------------------------
        # Create lock forms for every monitor
        # ----------------------------------------------------

        $screens = [System.Windows.Forms.Screen]::AllScreens

        foreach ($screen in $screens) {

            $isPrimary = $screen.Primary

            $form = New-LockForm `
                -Screen $screen `
                -IsPrimary $isPrimary

            $form.Show()
        }

        # ----------------------------------------------------
        # Lock keyboard shortcuts
        # ----------------------------------------------------

        Start-KeyboardHook

        # ----------------------------------------------------
        # Timer
        # ----------------------------------------------------

        $script:Timer =
            New-Object System.Windows.Forms.Timer

        # GUI loop ticks every 100 ms,
        # sensor reading only every 500 ms.
        $script:Timer.Interval = 100

        $script:LastSampleMs = 0
        $script:LastScanMs = 0

        $script:Timer.Add_Tick({

            try {

                $now = [Environment]::TickCount64

                # --------------------------------------------
                # Keep window in foreground while locked
                # --------------------------------------------

                if ($script:State -ne 'Unlocked') {

                    foreach ($form in $script:Forms) {

                        try {
                            if (-not $form.Visible) {
                                $form.Show()
                            }

                            $form.TopMost = $true
                            $form.BringToFront()
                            $form.Activate()
                        }
                        catch {}
                    }
                }

                # --------------------------------------------
                # Sensor discovery
                # --------------------------------------------

                if (-not $script:SensorConnected) {

                    if (
                        ($now - $script:LastScanMs)
                        -ge $PortScanIntervalMs
                    ) {

                        $script:LastScanMs = $now

                        $found = Find-Arduino

                        if ($found) {
                            Start-Calibration
                        }

                        Update-Ui
                    }

                    return
                }

                # --------------------------------------------
                # Sensor read
                # --------------------------------------------

                if (
                    ($now - $script:LastSampleMs)
                    -ge $SampleIntervalMs
                ) {

                    $script:LastSampleMs = $now

                    $value = Read-SensorValue

                    if ($null -ne $value) {

                        $script:LastUiValue = $value

                        Add-SensorReading -Value $value

                        Update-Ui
                    }
                }

            }
            catch {
                # Нельзя допустить смерть главного GUI loop
                Write-Debug $_
            }
        })

        # Initial state
        Reset-SensorState

        # First sensor check immediately
        $found = Find-Arduino

        if ($found) {
            Start-Calibration
        }

        Update-Ui

        $script:Timer.Start()

        # ----------------------------------------------------
        # Start Windows message loop
        # ----------------------------------------------------

        [System.Windows.Forms.Application]::Run()

    }
    finally {

        try {
            $script:Timer.Stop()
        }
        catch {}

        Stop-KeyboardHook

        Close-SerialPort

        foreach ($form in $script:Forms) {
            try {
                $form.Close()
                $form.Dispose()
            }
            catch {}
        }

        $script:Forms = @()

        try {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
        catch {}
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

    Write-Host ''
    Write-Host 'Installing AlcoholGuard...' -ForegroundColor Cyan

    Register-GuardTask

    Write-Host 'Запускаю защиту...'
    Write-Host ''

    # Перезапускаем себя именно как -Run.
    $ps = Join-Path $PSHome 'powershell.exe'

    if (-not (Test-Path $ps)) {
        $ps = (Get-Command powershell.exe).Source
    }

    Start-Process `
        -FilePath $ps `
        -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            "`"$PSCommandPath`""
            '-Run'
        ) `
        -WindowStyle Hidden

    exit 0
}

Start-Guard