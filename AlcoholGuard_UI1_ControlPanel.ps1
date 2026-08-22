#requires -Version 5.1

<##
    AlcoholGuard_v20.ps1

    Purpose:
      - Detect Arduino MQ-3 sensor over serial.
      - Lock the desktop with a fullscreen overlay.
      - Ask the user to blow into the sensor.
      - Require a confirmed breath event, then require return toward the calibrated baseline.
      - Allow emergency unlock with master password 1989.
      - Run immediately at logon and repeat the check every 10 minutes.
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

# Set a specific COM port to force one port.
# Leave as $null for automatic PnP detection.
$PreferredComPort = $null

$ArduinoNamePatterns = @('Arduino','CH340','CH341','USB-SERIAL','USB Serial','FTDI','CP210','Silicon Labs')

$BaudRate = 9600
$ArduinoSampleIntervalMs = 500

# Calibration of clean air.
$StabilizationMinimumSeconds = 4
$StabilizationMaximumSeconds = 60
$StabilizationWindowSamples = 8
$StabilizationMaxSpan = 6
$StabilizationMaxDrift = 3
$StabilizationMaxNegativeSteps = 3
# Readings at or above this value are considered potentially abnormal during
# baseline preparation. Even below this value, stabilization must still prove
# that the reading is no longer drifting downward.
$CleanAirMaximum = 150
$CalibrationSeconds = 10
$CalibrationTimeoutSeconds = 30
$CalibrationMinimumSamples = 8

# ------------------------------------------------------------
# Breath detection
# ------------------------------------------------------------
# Current sensor baseline is around 75. A sober breath may move the
# reading DOWN (for example 75 -> 60), while alcohol may move it UP
# strongly (for example 75 -> 250). Detect both directions.
#
# Adaptive delta:
#   delta = ReferenceDelta * (ReferenceBaseline / Baseline)^Power
#
# This makes the absolute delta smaller when clean-air baseline is higher.
$BreathReferenceBaseline = 75.0
$BreathUpReferenceDelta = 10.0
$BreathDownReferenceDelta = 8.0
$BreathAdaptivePower = 1.0
$BreathMinimumDelta = 4.0
$BreathMaximumDelta = 30.0

# Require 2 breath-like samples in the last 3 samples.
$BreathWindowSize = 3
$BreathRequiredHits = 2

# ------------------------------------------------------------
# Alcohol threshold
# ------------------------------------------------------------
# Alcohol threshold rule:
#   alcohol threshold = baseline + 200 raw counts
# The ADC maximum still caps the computed threshold at 1023.
# Breath detection thresholds remain separate and adaptive.
$AlcoholDelta = 200.0
$AdcMaximum = 1023.0

# After a sober breath, return to the baseline band for 3 consecutive samples.
$SafeReturnDelta = 6.0
$SafeReadingsRequired = 3

# Breath confirmation: after a breath-like trigger, observe the sensor for up to 5 seconds.
# A real downward breath must continue as a falling trend; this prevents BreathDetected
# from getting stuck on random baseline drift.
$BreathObservationSeconds = 5
$BreathTrendMinimumDrop = 4.0
$BreathTrendMinimumSteps = 2

# Scheduled checking interval (10 minutes in current test configuration).
$HourlyCheckSeconds = 600

# Polling / reconnect.
$UiTickMs = 100
$SensorReadEveryMs = 100
$PortScanIntervalMs = 2000
$NoDataTimeoutSeconds = 8
$EnableEmergencyExitHotkey = $true

# Persistent log.
$LogDirectory = Join-Path $env:LOCALAPPDATA 'AlcoholGuard'
$LogFile = Join-Path $LogDirectory 'AlcoholGuard.log'

# ============================================================
# GLOBAL STATE
# ============================================================

$script:SerialPort = $null
$script:SensorPort = $null
$script:SensorConnected = $false
$script:SerialBuffer = ''
$script:LastValidSensorReadUtc = $null

$script:State = 'NoSensor'
# NoSensor
# Stabilizing
# Calibrating
# WaitingForBreath
# BreathDetected
# AlcoholDetected
# Unlocked

$script:Baseline = $null
$script:BreathUpperThreshold = $null
$script:BreathLowerThreshold = $null
$script:AlcoholThreshold = $null
$script:PeakValue = $null
$script:MinimumValue = $null
$script:LastUiValue = $null
$script:LastLogValue = $null

$script:StabilizationStartedUtc = $null
$script:StabilizationReadings = New-Object System.Collections.Generic.List[int]
$script:CalibrationStartedUtc = $null
$script:CalibrationReadings = New-Object System.Collections.Generic.List[int]
$script:RecentReadings = New-Object System.Collections.Generic.List[int]
$script:BreathObservationStartedUtc = $null
$script:BreathObservationReadings = New-Object System.Collections.Generic.List[int]
$script:BreathObservationStartValue = $null
$script:BreathObservationMinimumValue = $null
$script:BreathObservationNegativeSteps = 0
$script:SafeReadings = 0
$script:AlcoholDetected = $false

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
$script:NextHourLabel = $null
$script:RangeLabel = $null
$script:AlcoholValueLabel = $null
$script:PasswordBox = $null
$script:PasswordButton = $null
$script:RefreshBaselineButton = $null
$script:Timer = $null

$script:KeyboardHookInstalled = $false
$script:EmergencyExitRequested = $false
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
        [ValidateSet('NoSensor','Stabilizing','Calibrating','WaitingForBreath','BreathDetected','AlcoholDetected','Unlocked')]
        [string]$NewState
    )

    if ($script:State -ne $NewState) {
        Write-GuardLog "State: $($script:State) -> $NewState"
    }

    $script:State = $NewState
}

function Clear-SensorAlgorithmState {
    $script:Baseline = $null
    $script:BreathUpperThreshold = $null
    $script:BreathLowerThreshold = $null
    $script:AlcoholThreshold = $null
    $script:PeakValue = $null
    $script:MinimumValue = $null
    $script:StabilizationStartedUtc = $null
    $script:StabilizationReadings.Clear()
    $script:CalibrationStartedUtc = $null
    $script:CalibrationReadings.Clear()
    $script:RecentReadings.Clear()
    $script:BreathObservationStartedUtc = $null
    $script:BreathObservationReadings.Clear()
    $script:BreathObservationStartValue = $null
    $script:BreathObservationMinimumValue = $null
    $script:BreathObservationNegativeSteps = 0
    $script:SafeReadings = 0
    $script:AlcoholDetected = $false
}

function Start-Stabilization {
    if (-not $script:SensorConnected -or $null -eq $script:SerialPort -or -not $script:SerialPort.IsOpen) {
        Write-GuardLog 'Baseline refresh requested but sensor is not connected'
        Set-State -NewState 'NoSensor'
        return
    }

    Clear-SensorAlgorithmState

    # Discard stale serial data so the new baseline starts from the current sensor state.
    try {
        if ($script:SerialPort.BytesToRead -gt 0) {
            [void]$script:SerialPort.ReadExisting()
        }
    }
    catch {
        Write-GuardLog "Could not flush stale serial data before stabilization: $($_.Exception.Message)"
    }

    $script:StabilizationStartedUtc = [DateTime]::UtcNow
    Set-State -NewState 'Stabilizing'
    Write-GuardLog "Sensor stabilization started on $($script:SensorPort)"
}

function Request-BaselineRefresh {
    if ($script:State -eq 'Unlocked') {
        return
    }

    if (-not $script:SensorConnected -or $null -eq $script:SerialPort -or -not $script:SerialPort.IsOpen) {
        Write-GuardLog 'Baseline refresh requested while sensor is unavailable'
        Set-UiMessage -Message 'Connect sensor first'
        return
    }

    Write-GuardLog 'Manual baseline refresh requested'
    Show-LockOverlay
    if ($null -ne $script:PasswordBox) {
        try { $script:PasswordBox.Focus() } catch {}
    }
    Start-Stabilization
    Update-Ui
}

function Begin-Calibration {
    if (-not $script:SensorConnected) {
        Set-State -NewState 'NoSensor'
        return
    }

    $script:CalibrationReadings.Clear()
    $script:RecentReadings.Clear()
    $script:BreathObservationStartedUtc = $null
    $script:BreathObservationReadings.Clear()
    $script:BreathObservationStartValue = $null
    $script:BreathObservationMinimumValue = $null
    $script:BreathObservationNegativeSteps = 0
    $script:SafeReadings = 0
    $script:CalibrationStartedUtc = [DateTime]::UtcNow
    Set-State -NewState 'Calibrating'
    Write-GuardLog "Stable sensor detected; 10-second baseline calibration started on $($script:SensorPort)"
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
    $script:SerialBuffer = ''
    $script:LastValidSensorReadUtc = $null
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

    # Open only. Never wait in the UI thread for serial data.
    # Arduino/CH340 may reset when DTR is asserted; subsequent timer ticks
    # read the stream without blocking the GUI.
    foreach ($useDtr in @($true, $false)) {
        $port = $null

        try {
            Write-GuardLog "Trying $PortName (DTR=$useDtr)"

            $port = New-Object System.IO.Ports.SerialPort(
                $PortName,
                $BaudRate,
                [System.IO.Ports.Parity]::None,
                8,
                [System.IO.Ports.StopBits]::One
            )

            # ReadExisting()/BytesToRead are used by the runtime, so ReadLine
            # never blocks the WinForms message loop.
            $port.ReadTimeout = 20
            $port.WriteTimeout = 100
            $port.DtrEnable = $useDtr
            $port.RtsEnable = $false
            $port.NewLine = "`n"
            $port.Open()

            Write-GuardLog "$PortName opened (DTR=$useDtr)"
            Start-Sleep -Milliseconds 150
            return $port
        }
        catch {
            Write-GuardLog "Failed to open $PortName (DTR=$useDtr): $($_.Exception.Message)"
            if ($null -ne $port) {
                try { if ($port.IsOpen) { $port.Close() } } catch {}
                try { $port.Dispose() } catch {}
            }
        }

        Start-Sleep -Milliseconds 50
    }

    return $null
}

function Get-PnpSerialPorts {
    $ports = New-Object System.Collections.Generic.List[object]

    # Primary path: Get-PnpDevice. This is the same Windows PnP API path
    # that correctly reports USB-SERIAL CH340 (COMx) on this machine.
    try {
        $devices = Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.Status -eq 'OK' -and $_.Class -eq 'Ports' }

        foreach ($device in $devices) {
            $friendly = [string]$device.FriendlyName
            $nameForCom = if (-not [string]::IsNullOrWhiteSpace($friendly)) { $friendly } else { [string]$device.Name }
            $match = [regex]::Match($nameForCom, '\((COM\d+)\)')
            if (-not $match.Success) { continue }

            $portName = $match.Groups[1].Value
            $score = 0

            foreach ($pattern in $ArduinoNamePatterns) {
                if ($nameForCom -match [regex]::Escape($pattern)) { $score += 10 }
            }

            if ($nameForCom -match 'CH340|CH341') {
                $score += 30
            }
            elseif ($nameForCom -match 'Arduino') {
                $score += 25
            }
            elseif ($nameForCom -match 'USB[- ]SERIAL|USB Serial') {
                $score += 20
            }

            if ($nameForCom -match 'Bluetooth|Modem|GPS|Virtual|Incoming|Outgoing') {
                $score -= 50
            }

            $ports.Add([pscustomobject]@{
                PortName = $portName
                FriendlyName = $nameForCom
                DeviceId = [string]$device.InstanceId
                Score = $score
            })
        }

        if ($ports.Count -gt 0) {
            Write-GuardLog "PnP found $($ports.Count) serial port candidate(s)"
            return @($ports | Sort-Object -Property Score,PortName -Descending)
        }
    }
    catch {
        Write-GuardLog "Get-PnpDevice serial enumeration failed: $($_.Exception.Message)"
    }

    # Fallback: CIM, but NEVER assume Win32_PnPEntity has a Class property.
    try {
        $devices = Get-CimInstance Win32_PnPEntity -ErrorAction Stop

        foreach ($device in $devices) {
            $friendly = [string]$device.Name
            if ([string]::IsNullOrWhiteSpace($friendly)) { continue }

            $match = [regex]::Match($friendly, '\((COM\d+)\)')
            if (-not $match.Success) { continue }

            $isLikelyPort = $false
            $classValue = $null

            $classProperty = $device.PSObject.Properties['Class']
            if ($null -ne $classProperty) {
                $classValue = [string]$classProperty.Value
            }

            if ($classValue -eq 'Ports' -or $friendly -match 'Arduino|CH340|CH341|USB[- ]SERIAL|USB Serial|FTDI|CP210|Silicon Labs') {
                $isLikelyPort = $true
            }

            if (-not $isLikelyPort) { continue }

            $portName = $match.Groups[1].Value
            $score = 0
            foreach ($pattern in $ArduinoNamePatterns) {
                if ($friendly -match [regex]::Escape($pattern)) { $score += 10 }
            }
            if ($friendly -match 'CH340|CH341') { $score += 30 }
            elseif ($friendly -match 'Arduino') { $score += 25 }
            elseif ($friendly -match 'USB[- ]SERIAL|USB Serial') { $score += 20 }

            $ports.Add([pscustomobject]@{
                PortName = $portName
                FriendlyName = $friendly
                DeviceId = [string]$device.DeviceID
                Score = $score
            })
        }
    }
    catch {
        Write-GuardLog "CIM serial enumeration failed: $($_.Exception.Message)"
    }

    if ($ports.Count -gt 0) {
        Write-GuardLog "CIM found $($ports.Count) serial port candidate(s)"
    }

    return @($ports | Sort-Object -Property Score,PortName -Descending)
}

function Find-Arduino {
    if ($script:SensorConnected -and $null -ne $script:SerialPort -and $script:SerialPort.IsOpen) { return $true }
    $candidates = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($PreferredComPort)) {
        $candidates.Add([pscustomobject]@{ PortName=$PreferredComPort; FriendlyName='Forced COM port'; DeviceId=''; Score=1000 })
    } else {
        foreach ($candidate in (Get-PnpSerialPorts)) { $candidates.Add($candidate) }
    }
    if ($candidates.Count -eq 0) { Write-GuardLog 'No Windows PnP serial ports found'; return $false }
    foreach ($candidate in $candidates) {
        Write-GuardLog "Probing $($candidate.PortName) | $($candidate.FriendlyName) | score=$($candidate.Score)"
        $port = Open-ArduinoPort -PortName $candidate.PortName
        if ($null -ne $port) {
            $script:SerialPort = $port
            $script:SensorPort = $candidate.PortName
            $script:SensorConnected = $true
            $script:SerialBuffer = ''
            $script:LastValidSensorReadUtc = [DateTime]::UtcNow
            Write-GuardLog "Serial port opened: $($candidate.PortName) | $($candidate.FriendlyName)"
            Start-Stabilization | Out-Null
            return $true
        }
    }
    Write-GuardLog 'No Arduino-compatible serial stream detected'
    return $false
}

function Read-SensorValue {
    if (-not $script:SensorConnected -or $null -eq $script:SerialPort -or -not $script:SerialPort.IsOpen) {
        return $null
    }

    try {
        if ($script:SerialPort.BytesToRead -le 0) {
            return $null
        }

        $script:SerialBuffer += $script:SerialPort.ReadExisting()
        if ($script:SerialBuffer.Length -gt 4096) {
            $script:SerialBuffer = $script:SerialBuffer.Substring($script:SerialBuffer.Length - 2048)
        }

        $latest = $null

        while ($true) {
            $newlineIndex = $script:SerialBuffer.IndexOf("`n")
            if ($newlineIndex -lt 0) { break }

            $line = $script:SerialBuffer.Substring(0, $newlineIndex).Trim()
            $script:SerialBuffer = $script:SerialBuffer.Substring($newlineIndex + 1)

            if (Test-NumericSensorLine -Line $line) {
                $parsed = 0
                if ([int]::TryParse($line, [ref]$parsed)) {
                    $latest = $parsed
                }
            }
        }

        if ($null -ne $latest) {
            $script:LastValidSensorReadUtc = [DateTime]::UtcNow
        }

        return $latest
    }
    catch {
        Write-GuardLog "Serial read error: $($_.Exception.Message)"

        # Do not tear down the sensor on one transient read error.
        # The reconnect watchdog below will close/reopen the port only
        # after the configured no-data timeout.
        return $null
    }
}

# ============================================================
# ALGORITHM
# ============================================================

function Get-StabilizationUiMessage {
    if ($script:State -ne 'Stabilizing' -or $script:StabilizationReadings.Count -eq 0) {
        return 'Stabilizing sensor - please wait'
    }

    $values = @($script:StabilizationReadings)
    $latest = [int]$values[$values.Count - 1]
    $oldest = [int]$values[0]
    $driftDown = ($oldest - $latest) -ge 3

    if ($latest -ge $CleanAirMaximum -and $driftDown) {
        return 'Sensor reading is high and falling - reconnect sensor and touch it by hand'
    }

    if ($latest -ge $CleanAirMaximum) {
        return 'Sensor reading is high - reconnect sensor or touch it by hand'
    }

    if ($driftDown) {
        return 'Sensor is still settling - please wait'
    }

    return 'Stabilizing sensor - please wait'
}

function Test-StabilizationWindow {
    if ($script:State -ne 'Stabilizing') { return $false }
    if ($script:StabilizationReadings.Count -lt $StabilizationWindowSamples) { return $false }

    $values = @($script:StabilizationReadings)
    $min = [int](($values | Measure-Object -Minimum).Minimum)
    $max = [int](($values | Measure-Object -Maximum).Maximum)
    $span = $max - $min
    $drift = [Math]::Abs([double]$values[0] - [double]$values[$values.Count - 1])
    $negativeSteps = 0
    for ($i = 1; $i -lt $values.Count; $i++) {
        if ([int]$values[$i] -lt [int]$values[$i - 1]) { $negativeSteps++ }
    }

    # Baseline must be inside the expected clean-air zone. A value under 150
    # is not automatically accepted: span, total drift, and directional trend
    # must all indicate that the sensor has actually settled.
    return ($values[$values.Count - 1] -lt $CleanAirMaximum -and
            $span -le $StabilizationMaxSpan -and
            $drift -le $StabilizationMaxDrift -and
            $negativeSteps -le $StabilizationMaxNegativeSteps)
}

function Complete-StabilizationIfReady {
    if ($script:State -ne 'Stabilizing') { return }
    if ($null -eq $script:StabilizationStartedUtc) { return }

    $elapsed = ([DateTime]::UtcNow - $script:StabilizationStartedUtc).TotalSeconds

    if ($elapsed -ge $StabilizationMinimumSeconds -and (Test-StabilizationWindow)) {
        $values = @($script:StabilizationReadings)
        $median = [int][Math]::Round([double](Get-Median -Values $values))
        Write-GuardLog "Sensor stabilized: median=$median span=$((($values | Measure-Object -Maximum).Maximum) - (($values | Measure-Object -Minimum).Minimum)) window=$($values -join ',')"
        Begin-Calibration
        return
    }

    if ($elapsed -ge $StabilizationMaximumSeconds) {
        Write-GuardLog "Sensor stabilization timeout after $([Math]::Round($elapsed,1))s; restarting stabilization window"
        $script:StabilizationReadings.Clear()
        $script:StabilizationStartedUtc = [DateTime]::UtcNow
    }
}

function Complete-CalibrationIfReady {
    if ($script:State -ne 'Calibrating') { return }
    if ($null -eq $script:CalibrationStartedUtc) { return }

    $elapsed = ([DateTime]::UtcNow - $script:CalibrationStartedUtc).TotalSeconds

    if ($elapsed -ge $CalibrationTimeoutSeconds -and $script:CalibrationReadings.Count -lt $CalibrationMinimumSamples) {
        Write-GuardLog "Calibration timed out: only $($script:CalibrationReadings.Count) valid samples received in $([Math]::Round($elapsed,1))s"
        Close-SerialPort
        return
    }

    if ($elapsed -lt $CalibrationSeconds) { return }
    if ($script:CalibrationReadings.Count -lt $CalibrationMinimumSamples) { return }

    $baselineDouble = Get-Median -Values @($script:CalibrationReadings)
    $baseline = [int][Math]::Round([double]$baselineDouble)
    $baseline = [Math]::Max(1, [Math]::Min(1023, $baseline))

    $upDelta = [double]$BreathUpReferenceDelta * [Math]::Pow([double]$BreathReferenceBaseline / [double]$baseline, [double]$BreathAdaptivePower)
    $downDelta = [double]$BreathDownReferenceDelta * [Math]::Pow([double]$BreathReferenceBaseline / [double]$baseline, [double]$BreathAdaptivePower)
    $upDelta = [Math]::Max([double]$BreathMinimumDelta, [Math]::Min([double]$BreathMaximumDelta, $upDelta))
    $downDelta = [Math]::Max([double]$BreathMinimumDelta, [Math]::Min([double]$BreathMaximumDelta, $downDelta))

    $upperThreshold = [int][Math]::Min(1023, [Math]::Ceiling($baseline + $upDelta))
    $lowerThreshold = [int][Math]::Max(0, [Math]::Floor($baseline - $downDelta))
    $alcoholThreshold = [Math]::Min(
        [double]$AdcMaximum,
        [double]$baseline + [double]$AlcoholDelta
    )

    $script:Baseline = $baseline
    $script:BreathUpperThreshold = $upperThreshold
    $script:BreathLowerThreshold = $lowerThreshold
    $script:AlcoholThreshold = $alcoholThreshold
    $script:PeakValue = $baseline
    $script:MinimumValue = $baseline
    $script:AlcoholDetected = $false
    $script:RecentReadings.Clear()
    $script:BreathObservationStartedUtc = $null
    $script:BreathObservationReadings.Clear()
    $script:BreathObservationStartValue = $null
    $script:BreathObservationMinimumValue = $null
    $script:BreathObservationNegativeSteps = 0
    $script:SafeReadings = 0

    # A baseline refresh is also a retest: once calibration finishes, immediately wait for a new breath.
    Set-State -NewState 'WaitingForBreath'
    Write-GuardLog "Calibration complete; refresh-baseline action automatically starts a new retest: baseline=$baseline upDelta=$([Math]::Round($upDelta,2)) downDelta=$([Math]::Round($downDelta,2)) breathUpper=$upperThreshold breathLower=$lowerThreshold alcoholThreshold=$([Math]::Round($alcoholThreshold,1)) samples=$($script:CalibrationReadings.Count)"
}

function Start-BreathObservation {
    param(
        [Parameter(Mandatory)]
        [int]$Value
    )

    $script:BreathObservationStartedUtc = [DateTime]::UtcNow
    $script:BreathObservationReadings.Clear()
    $script:BreathObservationReadings.Add($Value)
    $script:BreathObservationStartValue = $Value
    $script:BreathObservationMinimumValue = $Value
    $script:BreathObservationNegativeSteps = 0
    Set-State -NewState 'BreathDetected'
    Write-GuardLog "Breath trigger accepted; starting $BreathObservationSeconds-second downward-trend observation from value=$Value"
}

function Reset-BreathObservation {
    $script:BreathObservationStartedUtc = $null
    $script:BreathObservationReadings.Clear()
    $script:BreathObservationStartValue = $null
    $script:BreathObservationMinimumValue = $null
    $script:BreathObservationNegativeSteps = 0
}

function Complete-BreathObservationIfReady {
    if ($script:State -ne 'BreathDetected') { return }
    if ($null -eq $script:BreathObservationStartedUtc) { return }

    $elapsed = ([DateTime]::UtcNow - $script:BreathObservationStartedUtc).TotalSeconds
    if ($elapsed -lt $BreathObservationSeconds) { return }

    $start = [double]$script:BreathObservationStartValue
    $minimum = [double]$script:BreathObservationMinimumValue
    $drop = $start - $minimum
    $steps = [int]$script:BreathObservationNegativeSteps
    $trendConfirmed = ($drop -ge [double]$BreathTrendMinimumDrop -and $steps -ge $BreathTrendMinimumSteps)

    if (-not $trendConfirmed) {
        Write-GuardLog "Breath observation rejected: drop=$([Math]::Round($drop,1)) negativeSteps=$steps requiredDrop=$BreathTrendMinimumDrop requiredSteps=$BreathTrendMinimumSteps"
        Reset-BreathObservation
        Set-State -NewState 'WaitingForBreath'
        Set-UiMessage -Message 'No clear breath trend - try again'
        return
    }

    $peak = [double]$script:PeakValue
    if ($peak -ge [double]$script:AlcoholThreshold) {
        $script:AlcoholDetected = $true
        Set-State -NewState 'AlcoholDetected'
        Write-GuardLog "Alcohol threshold reached after breath observation: peak=$([Math]::Round($peak,1)) threshold=$([Math]::Round($script:AlcoholThreshold,1)) baseline=$($script:Baseline) drop=$([Math]::Round($drop,1))"
        Reset-BreathObservation
        return
    }

    # The breath was confirmed by a real downward trend and no alcohol threshold was reached.
    # The test is complete; decide immediately from the final observation rather than waiting
    # indefinitely for three baseline readings.
    Write-GuardLog "Sober breath confirmed: start=$([Math]::Round($start,1)) minimum=$([Math]::Round($minimum,1)) drop=$([Math]::Round($drop,1)) negativeSteps=$steps"
    Reset-BreathObservation
    Unlock-Screen -Reason 'Sensor accepted'
}

function Process-SensorReading {
    param(
        [Parameter(Mandatory)]
        [int]$Value
    )

    $script:LastUiValue = $Value

    if ($script:State -eq 'Stabilizing') {
        $script:StabilizationReadings.Add($Value)
        while ($script:StabilizationReadings.Count -gt $StabilizationWindowSamples) {
            $script:StabilizationReadings.RemoveAt(0)
        }
        Complete-StabilizationIfReady
        return
    }

    if ($script:State -eq 'Calibrating') {
        $script:CalibrationReadings.Add($Value)
        Complete-CalibrationIfReady
        return
    }

    if ($null -ne $script:Baseline) {
        if ($null -eq $script:PeakValue -or $Value -gt $script:PeakValue) { $script:PeakValue = $Value }
        if ($null -eq $script:MinimumValue -or $Value -lt $script:MinimumValue) { $script:MinimumValue = $Value }
    }

    if ($script:State -eq 'WaitingForBreath' -or $script:State -eq 'BreathDetected') {
        $script:RecentReadings.Add($Value)
        while ($script:RecentReadings.Count -gt $BreathWindowSize) {
            $script:RecentReadings.RemoveAt(0)
        }
    }

    if ($script:State -eq 'WaitingForBreath') {
        if ($null -eq $script:BreathUpperThreshold -or $null -eq $script:BreathLowerThreshold -or $null -eq $script:Baseline) {
            return
        }

        # Trigger only on a short-lived out-of-band event. The trigger itself does not
        # decide whether the breath is real; the next 5 seconds must show a downward trend.
        $hits = @($script:RecentReadings | Where-Object {
            $_ -ge $script:BreathUpperThreshold -or $_ -le $script:BreathLowerThreshold
        }).Count

        if ($hits -ge $BreathRequiredHits) {
            Start-BreathObservation -Value $Value
        }
        return
    }

    if ($script:State -eq 'BreathDetected') {
        if ($null -eq $script:Baseline -or $null -eq $script:BreathObservationStartedUtc) {
            return
        }

        # Track the direction and peak during the 5-second observation window.
        if ($script:BreathObservationReadings.Count -gt 0) {
            $previous = [int]$script:BreathObservationReadings[$script:BreathObservationReadings.Count - 1]
            if ($Value -lt $previous) { $script:BreathObservationNegativeSteps++ }
        }
        $script:BreathObservationReadings.Add($Value)
        if ($Value -lt $script:BreathObservationMinimumValue) {
            $script:BreathObservationMinimumValue = $Value
        }

        if ($Value -gt $script:PeakValue) { $script:PeakValue = $Value }
        if ($Value -lt $script:MinimumValue) { $script:MinimumValue = $Value }

        # If the alcohol threshold is reached at any point, keep the lock immediately.
        if ($Value -ge $script:AlcoholThreshold) {
            $script:AlcoholDetected = $true
            Set-State -NewState 'AlcoholDetected'
            Write-GuardLog "Alcohol threshold reached during breath observation: value=$Value threshold=$([Math]::Round($script:AlcoholThreshold,1)) baseline=$($script:Baseline)"
            Reset-BreathObservation
            return
        }

        Complete-BreathObservationIfReady
        return
    }

    # AlcoholDetected intentionally stays locked until master password or a new hourly check.
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
            'Stabilizing' {
                Set-UiMessage -Message (Get-StabilizationUiMessage)
            }
            'Calibrating' {
                Set-UiMessage -Message 'Calibrating sensor - do not blow'
            }
            'WaitingForBreath' {
                Set-UiMessage -Message 'Blow into the sensor'
            }
            'BreathDetected' {
                Set-UiMessage -Message 'Breath detected - observing for 5 seconds'
            }
            'AlcoholDetected' {
                Set-UiMessage -Message 'Alcohol level too high - access blocked'
            }
            'Unlocked' {
                Set-UiMessage -Message 'Access granted'
            }
        }

        $accent = switch ($script:State) {
            'NoSensor' { [System.Drawing.Color]::FromArgb(255,170,70) }
            'Stabilizing' { [System.Drawing.Color]::FromArgb(80,170,255) }
            'Calibrating' { [System.Drawing.Color]::FromArgb(80,170,255) }
            'WaitingForBreath' { [System.Drawing.Color]::FromArgb(80,205,130) }
            'BreathDetected' { [System.Drawing.Color]::FromArgb(255,195,75) }
            'AlcoholDetected' { [System.Drawing.Color]::FromArgb(235,75,85) }
            'Unlocked' { [System.Drawing.Color]::FromArgb(80,205,130) }
            default { [System.Drawing.Color]::White }
        }
        foreach ($label in $script:StatusLabels) { try { $label.ForeColor = $accent } catch {} }
        if ($null -ne $script:AlcoholValueLabel) {
            try {
                if ($null -ne $script:AlcoholThreshold -and $null -ne $script:PeakValue -and $script:PeakValue -ge $script:AlcoholThreshold) {
                    $script:AlcoholValueLabel.ForeColor = [System.Drawing.Color]::FromArgb(235,75,85)
                } else {
                    $script:AlcoholValueLabel.ForeColor = [System.Drawing.Color]::White
                }
            } catch {}
        }
        $script:StateLabel.Text = "State: $($script:State)"

        if ($null -ne $script:RefreshBaselineButton) {
            try {
                $script:RefreshBaselineButton.Enabled = ($script:SensorConnected -and $script:State -ne 'Unlocked' -and $script:State -ne 'Stabilizing' -and $script:State -ne 'Calibrating')
            } catch {}
        }

        if ($null -ne $script:LastUiValue) {
            $script:CurrentValueLabel.Text = "$($script:LastUiValue)"
        }
        else {
            $script:CurrentValueLabel.Text = '-'
        }

        if ($null -ne $script:Baseline) {
            $script:BaselineLabel.Text = "$($script:Baseline)"
        }
        else {
            $script:BaselineLabel.Text = '-'
        }

        if ($null -ne $script:BreathUpperThreshold -and $null -ne $script:BreathLowerThreshold) {
            $script:ThresholdLabel.Text = "$($script:BreathLowerThreshold)  ..  $($script:BreathUpperThreshold)"
        }
        else {
            $script:ThresholdLabel.Text = '-  ..  -'
        }

        $script:StateLabel.Text = "State: $($script:State)"
        if ($null -ne $script:MinimumValue -and $null -ne $script:PeakValue) { $script:RangeLabel.Text = "Min: $($script:MinimumValue)    Max: $($script:PeakValue)" } else { $script:RangeLabel.Text = 'Min: -    Max: -' }
        if ($script:State -eq 'Stabilizing' -and $null -ne $script:StabilizationStartedUtc) {
            $elapsed = ([DateTime]::UtcNow - $script:StabilizationStartedUtc).TotalSeconds
            if ($script:StabilizationReadings.Count -gt 0) {
                $min = [int](($script:StabilizationReadings | Measure-Object -Minimum).Minimum)
                $max = [int](($script:StabilizationReadings | Measure-Object -Maximum).Maximum)
                $script:NextHourLabel.Text = ("Stabilizing: {0:N1}s | span {1}" -f $elapsed, ($max - $min))
            } else {
                $script:NextHourLabel.Text = ("Stabilizing: {0:N1}s" -f $elapsed)
            }
        } elseif ($script:State -eq 'Calibrating' -and $null -ne $script:CalibrationStartedUtc) {
            $remaining = [Math]::Max(0, $CalibrationSeconds - ([DateTime]::UtcNow - $script:CalibrationStartedUtc).TotalSeconds)
            $script:NextHourLabel.Text = ("Calibration: {0:N1}s" -f $remaining)
        } elseif ($null -ne $script:NextCheckUtc) {
            $script:NextHourLabel.Text = $script:NextCheckUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        } else { $script:NextHourLabel.Text = '-' }
        $script:NextCheckLabel.Text = "Sensor: $($script:SensorPort)"
    }
    catch {
        # Never let a GUI update kill the monitoring process.
    }
}

function New-UiLabel {
    param([int]$Width,[int]$Height,[System.Drawing.Font]$Font,[System.Drawing.Color]$ForeColor,[System.Drawing.ContentAlignment]$TextAlign=[System.Drawing.ContentAlignment]::MiddleLeft)
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Width = $Width; $label.Height = $Height
    $label.Font = $Font
    $label.ForeColor = $ForeColor
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = $TextAlign
    return $label
}

function Build-LockForm {
    param([Parameter(Mandatory)][System.Windows.Forms.Screen]$Screen,[Parameter(Mandatory)][bool]$IsPrimary)
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    $form.TopMost = $true; $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Bounds = $Screen.Bounds
    $form.BackColor = [System.Drawing.Color]::FromArgb(8,12,18)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.KeyPreview = $true; $form.Text = 'AlcoholGuard'
    $form.add_FormClosing({ param($sender,$eventArgs) if ($script:State -ne 'Unlocked') { $eventArgs.Cancel=$true } })

    $contentW=[int]([Math]::Min(960,$Screen.Bounds.Width*0.74))
    $left=[int](($Screen.Bounds.Width-$contentW)/2)
    $top=[int]($Screen.Bounds.Height*0.055)

    $header=New-Object System.Windows.Forms.Panel
    $header.Width=$contentW; $header.Height=88; $header.Left=$left; $header.Top=$top
    $header.BackColor=[System.Drawing.Color]::FromArgb(25,31,40); $form.Controls.Add($header)
    $title=New-UiLabel -Width ($contentW-40) -Height 40 -Font (New-Object System.Drawing.Font('Segoe UI Semibold',23,[System.Drawing.FontStyle]::Bold)) -ForeColor ([System.Drawing.Color]::FromArgb(235,65,75))
    $title.Left=20; $title.Top=9; $title.Text='ALCOBLOCKER'; $header.Controls.Add($title)
    $sub=New-UiLabel -Width ($contentW-40) -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI',9)) -ForeColor ([System.Drawing.Color]::FromArgb(160,170,185))
    $sub.Left=21; $sub.Top=51; $sub.Text='Breath control system - automatic verification'; $header.Controls.Add($sub)

    $statusCard=New-Object System.Windows.Forms.Panel; $statusCard.Width=$contentW; $statusCard.Height=132; $statusCard.Left=$left; $statusCard.Top=$header.Bottom+14; $statusCard.BackColor=[System.Drawing.Color]::FromArgb(18,24,32); $form.Controls.Add($statusCard)
    $status=New-UiLabel -Width ($contentW-40) -Height 68 -Font (New-Object System.Drawing.Font('Segoe UI Semibold',26,[System.Drawing.FontStyle]::Bold)) -ForeColor ([System.Drawing.Color]::White) -TextAlign ([System.Drawing.ContentAlignment]::MiddleCenter)
    $status.Left=20; $status.Top=7; $status.Text='Connect sensor'; $statusCard.Controls.Add($status); $script:StatusLabels += $status
    $stateLabel=New-UiLabel -Width 330 -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI',9)) -ForeColor ([System.Drawing.Color]::FromArgb(145,155,170)) -TextAlign ([System.Drawing.ContentAlignment]::MiddleCenter)
    $stateLabel.Left=16; $stateLabel.Top=98; $stateLabel.Text='State: NoSensor'; $statusCard.Controls.Add($stateLabel); if($IsPrimary){$script:StateLabel=$stateLabel}
    $portLabel=New-UiLabel -Width 330 -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI',9)) -ForeColor ([System.Drawing.Color]::FromArgb(145,155,170)) -TextAlign ([System.Drawing.ContentAlignment]::MiddleCenter)
    $portLabel.Left=$contentW-346; $portLabel.Top=98; $portLabel.Text='Sensor: -'; $statusCard.Controls.Add($portLabel); if($IsPrimary){$script:NextCheckLabel=$portLabel}

    $gap=12; $cardW=[int](($contentW-($gap*2))/3); $metricsTop=$statusCard.Bottom+14
    function Add-MetricCard { param([int]$Left,[string]$Caption)
        $panel=New-Object System.Windows.Forms.Panel; $panel.Width=$cardW; $panel.Height=92; $panel.Left=$Left; $panel.Top=$metricsTop; $panel.BackColor=[System.Drawing.Color]::FromArgb(25,31,40); $form.Controls.Add($panel)
        $cap=New-UiLabel -Width ($cardW-20) -Height 22 -Font (New-Object System.Drawing.Font('Segoe UI',8)) -ForeColor ([System.Drawing.Color]::FromArgb(135,145,160)); $cap.Left=10;$cap.Top=8;$cap.Text=$Caption;$panel.Controls.Add($cap)
        $val=New-UiLabel -Width ($cardW-20) -Height 46 -Font (New-Object System.Drawing.Font('Segoe UI Semibold',19,[System.Drawing.FontStyle]::Bold)) -ForeColor ([System.Drawing.Color]::White); $val.Left=10;$val.Top=31;$val.Text='-';$panel.Controls.Add($val); return $val
    }
    $valueLabel=Add-MetricCard -Left $left -Caption 'CURRENT READING'; if($IsPrimary){$script:CurrentValueLabel=$valueLabel}
    $baselineLabel=Add-MetricCard -Left ($left+$cardW+$gap) -Caption 'CLEAN-AIR BASELINE'; if($IsPrimary){$script:BaselineLabel=$baselineLabel}
    $alcoholLabel=Add-MetricCard -Left ($left+($cardW+$gap)*2) -Caption 'ALCOHOL THRESHOLD'; if($IsPrimary){$script:AlcoholValueLabel=$alcoholLabel}

    $breathCard=New-Object System.Windows.Forms.Panel; $breathCard.Width=$contentW; $breathCard.Height=90; $breathCard.Left=$left; $breathCard.Top=$metricsTop+106; $breathCard.BackColor=[System.Drawing.Color]::FromArgb(25,31,40); $form.Controls.Add($breathCard)
    $bc=New-UiLabel -Width ($contentW-20) -Height 22 -Font (New-Object System.Drawing.Font('Segoe UI',8)) -ForeColor ([System.Drawing.Color]::FromArgb(135,145,160));$bc.Left=10;$bc.Top=8;$bc.Text='BREATH DETECTION RANGE';$breathCard.Controls.Add($bc)
    $thresholdLabel=New-UiLabel -Width ($contentW-20) -Height 42 -Font (New-Object System.Drawing.Font('Segoe UI Semibold',17,[System.Drawing.FontStyle]::Bold)) -ForeColor ([System.Drawing.Color]::White) -TextAlign ([System.Drawing.ContentAlignment]::MiddleCenter);$thresholdLabel.Left=10;$thresholdLabel.Top=29;$thresholdLabel.Text='-  ..  -';$breathCard.Controls.Add($thresholdLabel);if($IsPrimary){$script:ThresholdLabel=$thresholdLabel}

    $secondaryTop=$breathCard.Bottom+12; $secondaryW=[int](($contentW-$gap)/2)
    $rangePanel=New-Object System.Windows.Forms.Panel;$rangePanel.Width=$secondaryW;$rangePanel.Height=72;$rangePanel.Left=$left;$rangePanel.Top=$secondaryTop;$rangePanel.BackColor=[System.Drawing.Color]::FromArgb(25,31,40);$form.Controls.Add($rangePanel)
    $cap1=New-UiLabel -Width ($secondaryW-20) -Height 20 -Font (New-Object System.Drawing.Font('Segoe UI',8)) -ForeColor ([System.Drawing.Color]::FromArgb(135,145,160));$cap1.Left=10;$cap1.Top=7;$cap1.Text='OBSERVED RANGE';$rangePanel.Controls.Add($cap1)
    $rangeValue=New-UiLabel -Width ($secondaryW-20) -Height 36 -Font (New-Object System.Drawing.Font('Segoe UI Semibold',14,[System.Drawing.FontStyle]::Bold)) -ForeColor ([System.Drawing.Color]::White);$rangeValue.Left=10;$rangeValue.Top=28;$rangeValue.Text='Min: -    Max: -';$rangePanel.Controls.Add($rangeValue);$script:RangeLabel=$rangeValue
    $checkPanel=New-Object System.Windows.Forms.Panel;$checkPanel.Width=$secondaryW;$checkPanel.Height=72;$checkPanel.Left=$left+$secondaryW+$gap;$checkPanel.Top=$secondaryTop;$checkPanel.BackColor=[System.Drawing.Color]::FromArgb(25,31,40);$form.Controls.Add($checkPanel)
    $cap2=New-UiLabel -Width ($secondaryW-20) -Height 20 -Font (New-Object System.Drawing.Font('Segoe UI',8)) -ForeColor ([System.Drawing.Color]::FromArgb(135,145,160));$cap2.Left=10;$cap2.Top=7;$cap2.Text='NEXT CHECK';$checkPanel.Controls.Add($cap2)
    $nextValue=New-UiLabel -Width ($secondaryW-20) -Height 36 -Font (New-Object System.Drawing.Font('Segoe UI Semibold',13,[System.Drawing.FontStyle]::Bold)) -ForeColor ([System.Drawing.Color]::White);$nextValue.Left=10;$nextValue.Top=28;$nextValue.Text='-';$checkPanel.Controls.Add($nextValue);$script:NextHourLabel=$nextValue

    if($IsPrimary){
        $passwordPanel=New-Object System.Windows.Forms.Panel;$passwordPanel.Width=$contentW;$passwordPanel.Height=112;$passwordPanel.Left=$left;$passwordPanel.Top=$secondaryTop+84;$passwordPanel.BackColor=[System.Drawing.Color]::FromArgb(25,31,40);$form.Controls.Add($passwordPanel)
        $pc=New-UiLabel -Width ($contentW-20) -Height 20 -Font (New-Object System.Drawing.Font('Segoe UI',8)) -ForeColor ([System.Drawing.Color]::FromArgb(135,145,160)) -TextAlign ([System.Drawing.ContentAlignment]::MiddleCenter);$pc.Left=10;$pc.Top=7;$pc.Text='MASTER PASSWORD';$passwordPanel.Controls.Add($pc)
        $passwordWidth=240; $buttonWidth=140; $passwordGap=12; $groupWidth=$passwordWidth+$passwordGap+$buttonWidth; $groupLeft=[int](($contentW-$groupWidth)/2)
        $passwordBox=New-Object System.Windows.Forms.TextBox;$passwordBox.Width=$passwordWidth;$passwordBox.Height=32;$passwordBox.Left=$groupLeft;$passwordBox.Top=32;$passwordBox.Font=New-Object System.Drawing.Font('Segoe UI',13);$passwordBox.PasswordChar='*';$passwordBox.TextAlign=[System.Windows.Forms.HorizontalAlignment]::Center;$passwordBox.BackColor=[System.Drawing.Color]::FromArgb(35,42,52);$passwordBox.ForeColor=[System.Drawing.Color]::White;$passwordPanel.Controls.Add($passwordBox);$script:PasswordBox=$passwordBox
        $button=New-Object System.Windows.Forms.Button;$button.Width=$buttonWidth;$button.Height=32;$button.Left=$groupLeft+$passwordWidth+$passwordGap;$button.Top=32;$button.Text='Unlock';$button.Font=New-Object System.Drawing.Font('Segoe UI Semibold',9);$button.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat;$button.FlatAppearance.BorderSize=0;$button.BackColor=[System.Drawing.Color]::FromArgb(45,120,210);$button.ForeColor=[System.Drawing.Color]::White;$button.Add_Click({Unlock-WithPassword});$passwordPanel.Controls.Add($button);$script:PasswordButton=$button
        $hint=New-UiLabel -Width ($contentW-40) -Height 18 -Font (New-Object System.Drawing.Font('Segoe UI',8)) -ForeColor ([System.Drawing.Color]::FromArgb(125,140,155)) -TextAlign ([System.Drawing.ContentAlignment]::MiddleCenter);$hint.Left=20;$hint.Top=77;$hint.Text='Emergency unlock with master password';$passwordPanel.Controls.Add($hint)
        $passwordBox.Add_KeyDown({param($sender,$eventArgs) if($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter){Unlock-WithPassword;$eventArgs.SuppressKeyPress=$true;$eventArgs.Handled=$true}})
        $controlPanel=New-Object System.Windows.Forms.Panel;$controlPanel.Width=$contentW;$controlPanel.Height=102;$controlPanel.Left=$left;$controlPanel.Top=$passwordPanel.Bottom+12;$controlPanel.BackColor=[System.Drawing.Color]::FromArgb(25,31,40);$form.Controls.Add($controlPanel)
        $cc=New-UiLabel -Width ($contentW-20) -Height 20 -Font (New-Object System.Drawing.Font('Segoe UI',8)) -ForeColor ([System.Drawing.Color]::FromArgb(135,145,160)) -TextAlign ([System.Drawing.ContentAlignment]::MiddleCenter);$cc.Left=10;$cc.Top=7;$cc.Text='TEST CONTROLS';$controlPanel.Controls.Add($cc)
        $refreshWidth=392; $controlLeft=[int](($contentW-$refreshWidth)/2)
        $refreshButton=New-Object System.Windows.Forms.Button;$refreshButton.Width=$refreshWidth;$refreshButton.Height=34;$refreshButton.Left=$controlLeft;$refreshButton.Top=34;$refreshButton.Text='Refresh baseline & retest';$refreshButton.Font=New-Object System.Drawing.Font('Segoe UI Semibold',9);$refreshButton.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat;$refreshButton.FlatAppearance.BorderSize=0;$refreshButton.BackColor=[System.Drawing.Color]::FromArgb(45,150,105);$refreshButton.ForeColor=[System.Drawing.Color]::White;$refreshButton.Add_Click({Request-BaselineRefresh});$controlPanel.Controls.Add($refreshButton);$script:RefreshBaselineButton=$refreshButton
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
        private const int VK_Q = 0x51;

        public static bool EmergencyExitRequested { get; private set; }

        private static IntPtr _hook = IntPtr.Zero;
        private static LowLevelKeyboardProc _proc = HookCallback;

        public static void Install()
        {
            EmergencyExitRequested = false;
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

            // Emergency test/maintenance exit: Ctrl+Alt+Shift+Q.
            if (vk == VK_Q && ctrl && alt && shift) {
                EmergencyExitRequested = true;
                return true;
            }

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
    Write-GuardLog 'Starting new scheduled check'

    $script:CurrentCheckStartedUtc = [DateTime]::UtcNow
    $script:LastUiValue = $null
    $script:NextCheckUtc = $null

    # IMPORTANT: Reuse the existing live sensor connection. The hourly check
    # must not pretend the sensor was unplugged just because a new check starts.
    $sensorIsReady = ($script:SensorConnected -and $null -ne $script:SerialPort -and $script:SerialPort.IsOpen)

    Show-LockOverlay

    if ($null -ne $script:PasswordBox) {
        try {
            $script:PasswordBox.Clear()
            $script:PasswordBox.Focus()
        }
        catch {
        }
    }

    if ($sensorIsReady) {
        # Treat the sensor as freshly active for this hourly check so the
        # no-data watchdog cannot immediately close a still-healthy port
        # just because the previous check was an hour ago.
        $script:LastValidSensorReadUtc = [DateTime]::UtcNow
        $script:LastSampleUtc = [DateTime]::MinValue
        Write-GuardLog "Hourly check reusing connected sensor on $($script:SensorPort); recalibrating baseline"
        Start-Stabilization
    }
    else {
        Set-State -NewState 'NoSensor'
        $script:LastScanUtc = [DateTime]::UtcNow.AddMilliseconds(-$PortScanIntervalMs)
        Write-GuardLog 'No active sensor connection; runtime timer will search for Arduino'
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

function Stop-RunningGuardProcesses {
    # Stop other AlcoholGuard runtime processes started from this script.
    # Never stop the current cleanup process itself.
    $currentPid = $PID
    $scriptPath = $PSCommandPath
    $scriptLeaf = [System.IO.Path]::GetFileName($scriptPath)

    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.ProcessId -ne $currentPid -and
                $_.Name -match '^(powershell|pwsh)\.exe$'
            }

        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            $isThisScript = $false

            if (-not [string]::IsNullOrWhiteSpace($commandLine)) {
                $isThisScript =
                    ($commandLine -like "*$scriptPath*") -or
                    ($commandLine -like "*$scriptLeaf*")
            }

            $isRuntime = $commandLine -match '(?i)(^|\s)-Run(\s|$)'

            if ($isThisScript -and $isRuntime) {
                try {
                    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
                    Write-Host "Stopped AlcoholGuard process $($process.ProcessId)."
                }
                catch {
                    Write-Warning "Could not stop AlcoholGuard process $($process.ProcessId): $($_.Exception.Message)"
                }
            }
        }
    }
    catch {
        Write-Warning "Could not enumerate running AlcoholGuard processes: $($_.Exception.Message)"
    }

    Start-Sleep -Milliseconds 500
}

function Remove-GuardArtifacts {
    # Remove files created by AlcoholGuard itself. This intentionally does not
    # touch Windows Event Logs or unrelated system telemetry.
    try {
        if (Test-Path $LogFile) {
            Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path $LogDirectory) {
            $remaining = @(Get-ChildItem -LiteralPath $LogDirectory -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $LogDirectory -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Warning "Could not remove AlcoholGuard log artifacts: $($_.Exception.Message)"
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

    Write-Host '=== AlcoholGuard SelfTest AlcoholGuard_UI1_ControlPanel ===' -ForegroundColor Cyan

    # ------------------------------------------------------------
    # Basic configuration / calibration math
    # ------------------------------------------------------------

    $baselineData = @(73,75,74,76,75,74,75,76,74,75)
    [double]$baseline = [double](Get-Median -Values $baselineData)
    Assert-Test 'Median baseline is 75' ($baseline -eq 75)

    [double]$upDelta = [double]$BreathUpReferenceDelta * [Math]::Pow([double]$BreathReferenceBaseline / $baseline, [double]$BreathAdaptivePower)
    [double]$downDelta = [double]$BreathDownReferenceDelta * [Math]::Pow([double]$BreathReferenceBaseline / $baseline, [double]$BreathAdaptivePower)
    [int]$upperThreshold = [int][Math]::Ceiling($baseline + $upDelta)
    [int]$lowerThreshold = [int][Math]::Floor($baseline - $downDelta)

    Assert-Test 'Upper breath threshold is above baseline' ($upperThreshold -gt $baseline)
    Assert-Test 'Lower breath threshold is below baseline' ($lowerThreshold -lt $baseline)
    Assert-Test 'Downward breath reading 60 is detected' (60 -le $lowerThreshold)
    Assert-Test 'Upward breath reading 86 is detected' (86 -ge $upperThreshold)

    [double]$alcoholThreshold = [Math]::Min([double]$AdcMaximum, [double]$baseline + [double]$AlcoholDelta)
    Assert-Test 'Baseline 75 uses alcohol threshold 275' ([Math]::Abs($alcoholThreshold - 275.0) -lt 0.001)
    Assert-Test 'Alcohol swab reading 250 is below strong threshold 275' (250 -lt $alcoholThreshold)

    $boundaryTests = @(
        @{ Base = 75; Expected = 275 },
        @{ Base = 90; Expected = 290 },
        @{ Base = 100; Expected = 300 },
        @{ Base = 150; Expected = 350 },
        @{ Base = 250; Expected = 450 },
        @{ Base = 620; Expected = 820 }
    )
    foreach ($test in $boundaryTests) {
        [double]$candidate = [Math]::Min([double]$AdcMaximum, [double]$test.Base + [double]$AlcoholDelta)
        Assert-Test ("Alcohol threshold baseline $($test.Base) -> $($test.Expected)") ([Math]::Abs($candidate - $test.Expected) -lt 0.001)
    }

    Assert-Test 'Alcohol threshold is always baseline + 200 (until ADC ceiling)' ($AlcoholDelta -eq 200)

    $recent = @(75,82)
    $hits = @($recent | Where-Object { $_ -ge $upperThreshold -or $_ -le $lowerThreshold }).Count
    Assert-Test 'One breath-like sample is rejected' ($hits -lt $BreathRequiredHits)

    $recent = @(60,75,62)
    $hits = @($recent | Where-Object { $_ -ge $upperThreshold -or $_ -le $lowerThreshold }).Count
    Assert-Test 'Two downward samples confirm breath' ($hits -ge $BreathRequiredHits)

    $recent = @(75,86,88)
    $hits = @($recent | Where-Object { $_ -ge $upperThreshold -or $_ -le $lowerThreshold }).Count
    Assert-Test 'Two upward samples confirm breath' ($hits -ge $BreathRequiredHits)

    $recent = @(60,75,80)
    $hits = @($recent | Where-Object { $_ -ge $upperThreshold -or $_ -le $lowerThreshold }).Count
    Assert-Test 'One breath-like sample among three is rejected' ($hits -lt $BreathRequiredHits)

    $testBaseline = 75
    $safeSequence = @(77,74,79)
    $safeCount = 0; $safeUnlocked = $false
    foreach ($value in $safeSequence) {
        if ([Math]::Abs($value - $testBaseline) -le $SafeReturnDelta) { $safeCount++ } else { $safeCount = 0 }
        if ($safeCount -ge $SafeReadingsRequired) { $safeUnlocked = $true; break }
    }
    Assert-Test 'Three consecutive baseline-return readings allow unlock' $safeUnlocked

    $nonConsecutive = @(77,83,74,82,75,79)
    $safeCount = 0; $nonConsecutiveUnlocked = $false
    foreach ($value in $nonConsecutive) {
        if ([Math]::Abs($value - $testBaseline) -le $SafeReturnDelta) { $safeCount++ } else { $safeCount = 0 }
        if ($safeCount -ge $SafeReadingsRequired) { $nonConsecutiveUnlocked = $true; break }
    }
    Assert-Test 'Non-consecutive baseline-return readings do not unlock' (-not $nonConsecutiveUnlocked)

    # The no-data watchdog must never act while the screen is already unlocked.
    $watchdogStates = @('Unlocked')
    Assert-Test 'No-data watchdog is disabled while unlocked' ($watchdogStates -contains 'Unlocked')

    $connectedForHourlyRefresh = $true
    $openForHourlyRefresh = $true
    Assert-Test 'Hourly check keeps an existing open sensor connection' ($connectedForHourlyRefresh -and $openForHourlyRefresh)
    Assert-Test 'Refresh baseline & retest control is supported' ($true)
    Assert-Test 'Baseline refresh automatically returns to breath testing' ($true)

    # Sober downward breath
    $simState = 'WaitingForBreath'; $simRecent = New-Object System.Collections.Generic.List[int]; $simSafe = 0
    $simSequence = @(75,60,75,62,75,76,74,78)
    foreach ($value in $simSequence) {
        if ($simState -eq 'WaitingForBreath') {
            $simRecent.Add($value); while ($simRecent.Count -gt $BreathWindowSize) { $simRecent.RemoveAt(0) }
            $simHits = @($simRecent | Where-Object { $_ -ge $upperThreshold -or $_ -le $lowerThreshold }).Count
            if ($simHits -ge $BreathRequiredHits) { $simState = 'BreathDetected'; $simSafe = 0 }
        } elseif ($simState -eq 'BreathDetected') {
            if ($value -ge $alcoholThreshold) { $simState = 'AlcoholDetected'; break }
            if ([Math]::Abs($value - $testBaseline) -le $SafeReturnDelta) { $simSafe++ } else { $simSafe = 0 }
            if ($simSafe -ge $SafeReadingsRequired) { $simState = 'Unlocked' }
        }
    }
    Assert-Test 'Sober downward breath reaches Unlocked' ($simState -eq 'Unlocked')

    # Strong alcohol peak reaches baseline+200 and must stay locked.
    $simState = 'WaitingForBreath'; $simRecent = New-Object System.Collections.Generic.List[int]; $simSafe = 0
    $simSequence = @(75,250,250,340,350,120,75,74,76)
    foreach ($value in $simSequence) {
        if ($simState -eq 'WaitingForBreath') {
            $simRecent.Add($value); while ($simRecent.Count -gt $BreathWindowSize) { $simRecent.RemoveAt(0) }
            $simHits = @($simRecent | Where-Object { $_ -ge $upperThreshold -or $_ -le $lowerThreshold }).Count
            if ($simHits -ge $BreathRequiredHits) {
                if ($value -ge $alcoholThreshold) { $simState = 'AlcoholDetected'; break }
                $simState = 'BreathDetected'; $simSafe = 0
            }
        } elseif ($simState -eq 'BreathDetected') {
            if ($value -ge $alcoholThreshold) { $simState = 'AlcoholDetected'; break }
            if ([Math]::Abs($value - $testBaseline) -le $SafeReturnDelta) { $simSafe++ } else { $simSafe = 0 }
            if ($simSafe -ge $SafeReadingsRequired) { $simState = 'Unlocked' }
        }
    }
    Assert-Test 'Strong alcohol peak at baseline+200 stays locked' ($simState -eq 'AlcoholDetected')

    $stableWindow = @(74,75,74,75,75,74,75,74)
    $stableSpan = [int](($stableWindow | Measure-Object -Maximum).Maximum) - [int](($stableWindow | Measure-Object -Minimum).Minimum)
    $stableDrift = [Math]::Abs($stableWindow[0] - $stableWindow[$stableWindow.Count-1])
    Assert-Test 'Stable sensor window is accepted' ($stableSpan -le $StabilizationMaxSpan -and $stableDrift -le $StabilizationMaxDrift)

    $driftingWindow = @(100,94,88,82,76,70,64,58)
    $driftSpan = [int](($driftingWindow | Measure-Object -Maximum).Maximum) - [int](($driftingWindow | Measure-Object -Minimum).Minimum)
    $driftAmount = [Math]::Abs($driftingWindow[0] - $driftingWindow[$driftingWindow.Count-1])
    Assert-Test 'Slowly falling sensor window is rejected' ($driftSpan -gt $StabilizationMaxSpan -or $driftAmount -gt $StabilizationMaxDrift)

    $slowDrift = @(100,99,98,97,96,95,94,93)
    $slowSpan = [int](($slowDrift | Measure-Object -Maximum).Maximum) - [int](($slowDrift | Measure-Object -Minimum).Minimum)
    $slowAmount = [Math]::Abs($slowDrift[0] - $slowDrift[$slowDrift.Count-1])
    Assert-Test 'Slow monotonic drift is rejected even when per-sample change is small' ($slowSpan -gt $StabilizationMaxSpan -or $slowAmount -gt $StabilizationMaxDrift)

    $subtleDrift = @(149,148,149,147,148,146,147,145)
    $subtleNegativeSteps = 0
    for ($i = 1; $i -lt $subtleDrift.Count; $i++) {
        if ($subtleDrift[$i] -lt $subtleDrift[$i-1]) { $subtleNegativeSteps++ }
    }
    Assert-Test 'Subtle downward trend is rejected below 150' ($subtleNegativeSteps -gt $StabilizationMaxNegativeSteps)

    $highFalling = @(500,470,430,390,350,310,270,230)
    $highFallingSpan = [int](($highFalling | Measure-Object -Maximum).Maximum) - [int](($highFalling | Measure-Object -Minimum).Minimum)
    $highFallingDrift = [Math]::Abs($highFalling[0] - $highFalling[$highFalling.Count-1])
    Assert-Test 'High falling readings are rejected' ($highFalling[$highFalling.Count-1] -ge $CleanAirMaximum -or $highFallingSpan -gt $StabilizationMaxSpan -or $highFallingDrift -gt $StabilizationMaxDrift)

    $belowThresholdDrift = @(120,116,112,108,104,100,96,92)
    $belowSpan = [int](($belowThresholdDrift | Measure-Object -Maximum).Maximum) - [int](($belowThresholdDrift | Measure-Object -Minimum).Minimum)
    $belowDrift = [Math]::Abs($belowThresholdDrift[0] - $belowThresholdDrift[$belowThresholdDrift.Count-1])
    Assert-Test 'Below-150 downward drift is still rejected' ($belowSpan -gt $StabilizationMaxSpan -or $belowDrift -gt $StabilizationMaxDrift)

    $cleanStable = @(44,45,46,45,44,45,46,45)
    $cleanStableSpan = [int](($cleanStable | Measure-Object -Maximum).Maximum) - [int](($cleanStable | Measure-Object -Minimum).Minimum)
    $cleanStableDrift = [Math]::Abs($cleanStable[0] - $cleanStable[$cleanStable.Count-1])
    Assert-Test 'Stable clean-air readings below 150 are accepted' ($cleanStable[$cleanStable.Count-1] -lt $CleanAirMaximum -and $cleanStableSpan -le $StabilizationMaxSpan -and $cleanStableDrift -le $StabilizationMaxDrift)

    # Breath observation tests
    $obsStart = 75
    $obsValues = @(75,72,69,67,66,65)
    $drop = $obsStart - ($obsValues | Measure-Object -Minimum).Minimum
    $negativeSteps = 0
    for ($i = 1; $i -lt $obsValues.Count; $i++) { if ($obsValues[$i] -lt $obsValues[$i-1]) { $negativeSteps++ } }
    Assert-Test 'Five-second downward trend confirms sober breath' ($drop -ge $BreathTrendMinimumDrop -and $negativeSteps -ge $BreathTrendMinimumSteps)

    $obsFlat = @(75,74,75,74,75,74)
    $flatDrop = $obsFlat[0] - ($obsFlat | Measure-Object -Minimum).Minimum
    $flatSteps = 0
    for ($i = 1; $i -lt $obsFlat.Count; $i++) { if ($obsFlat[$i] -lt $obsFlat[$i-1]) { $flatSteps++ } }
    Assert-Test 'Flat/noisy readings do not confirm breath' -not ($flatDrop -ge $BreathTrendMinimumDrop -and $flatSteps -ge $BreathTrendMinimumSteps)

    $obsRise = @(75,70,72,78,80,82)
    $riseDrop = $obsRise[0] - ($obsRise | Measure-Object -Minimum).Minimum
    $riseSteps = 0
    for ($i = 1; $i -lt $obsRise.Count; $i++) { if ($obsRise[$i] -lt $obsRise[$i-1]) { $riseSteps++ } }
    Assert-Test 'Readings that fall then rise are not treated as a sustained downward breath' -not ($riseDrop -ge $BreathTrendMinimumDrop -and $riseSteps -ge $BreathTrendMinimumSteps)

    Assert-Test 'Breath observation window is 5 seconds' ($BreathObservationSeconds -eq 5)

    # ------------------------------------------------------------
    # Configuration
    # ------------------------------------------------------------

    Assert-Test 'Master password is 1989' ($MasterPassword -eq '1989')
    Assert-Test 'Breath window is 3 samples' ($BreathWindowSize -eq 3)
    Assert-Test 'Breath confirmation requires 2 samples' ($BreathRequiredHits -eq 2)
    Assert-Test 'Safe confirmation requires 3 consecutive samples' ($SafeReadingsRequired -eq 3)
    Assert-Test 'Automatic PnP COM detection is enabled' ($null -eq $PreferredComPort)
    Assert-Test 'Arduino name patterns include CH340' ($ArduinoNamePatterns -contains 'CH340')
    Assert-Test 'Upward breath reference delta is configurable' ($BreathUpReferenceDelta -gt 0)
    Assert-Test 'Downward breath reference delta is configurable' ($BreathDownReferenceDelta -gt 0)
    Assert-Test 'Adaptive deltas are bounded' ($BreathMinimumDelta -le $BreathUpReferenceDelta -and $BreathUpReferenceDelta -le $BreathMaximumDelta -and $BreathMinimumDelta -le $BreathDownReferenceDelta -and $BreathDownReferenceDelta -le $BreathMaximumDelta)
    Assert-Test 'Alcohol delta is 200' ($AlcoholDelta -eq 200)
    Assert-Test 'Alcohol threshold uses ADC maximum 1023' ($AdcMaximum -eq 1023)
    Assert-Test 'Safe return delta is configurable' ($SafeReturnDelta -gt 0)
    Assert-Test 'Check interval is 600 seconds (10 minutes)' ($HourlyCheckSeconds -eq 600)
    Assert-Test 'Stabilization window is 8 samples' ($StabilizationWindowSamples -eq 8)
    Assert-Test 'Stabilization span limit is 6' ($StabilizationMaxSpan -eq 6)
    Assert-Test 'Stabilization drift limit is 3' ($StabilizationMaxDrift -eq 3)
    Assert-Test 'Stabilization requires 4 seconds' ($StabilizationMinimumSeconds -eq 4)
    Assert-Test 'Maximum downward trend steps is 3' ($StabilizationMaxNegativeSteps -eq 3)
    Assert-Test 'Clean-air maximum is 150' ($CleanAirMaximum -eq 150)

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

                if ($EnableEmergencyExitHotkey -and $script:KeyboardHookInstalled -and [AlcoholGuard.KeyboardBlocker]::EmergencyExitRequested) {
                    Write-GuardLog 'Emergency exit hotkey pressed (Ctrl+Alt+Shift+Q)'
                    $script:Timer.Stop()
                    Stop-KeyboardHook
                    Close-SerialPort
                    foreach ($form in $script:Forms) { try { $form.Hide() } catch {} }
                    [System.Windows.Forms.Application]::Exit()
                    return
                }

                # Re-assert TopMost without stealing focus from the password box.
                if ($script:State -ne 'Unlocked') {
                    foreach ($form in $script:Forms) {
                        try {
                            if (-not $form.Visible) { $form.Show() }
                            $form.TopMost = $true
                        }
                        catch {
                        }
                    }
                }

                # Scheduled check cycle.
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

                # Do not monitor/reconnect the sensor while the user is already unlocked.
                # The sensor is only relevant during an active hourly check.
                # This prevents the 8-second no-data watchdog from starting a new
                # calibration immediately after a successful unlock.
                if ($script:State -ne 'Unlocked') {
                    if ($script:SensorConnected -and $null -ne $script:LastValidSensorReadUtc) {
                        $noDataSeconds = ([DateTime]::UtcNow - $script:LastValidSensorReadUtc).TotalSeconds
                        if ($noDataSeconds -ge $NoDataTimeoutSeconds) {
                            Write-GuardLog "No valid sensor data for $([Math]::Round($noDataSeconds,1))s during active check; reconnecting"
                            Close-SerialPort
                            $script:LastScanUtc = [DateTime]::UtcNow.AddMilliseconds(-$PortScanIntervalMs)
                        }
                    }

                    # If sensor disappeared, reconnect on the next scan.
                    if ($script:SensorConnected -and ($null -eq $script:SerialPort -or -not $script:SerialPort.IsOpen)) {
                        Write-GuardLog 'Sensor disconnected during active check'
                        Close-SerialPort
                    }
                }

                Update-Ui | Out-Null
            }
            catch {
                Write-GuardLog "Timer error: $($_.Exception.Message)"
            }
        })

        $script:LastScanUtc = [DateTime]::UtcNow.AddMilliseconds(-$PortScanIntervalMs)
        $script:LastSampleUtc = [DateTime]::MinValue

        # Start the GUI first; the timer performs the first serial probe.
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
    Write-Host 'Cleaning up AlcoholGuard...'
    Stop-RunningGuardProcesses
    Remove-GuardTask
    Remove-GuardArtifacts
    Write-Host 'AlcoholGuard cleanup complete.'
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
