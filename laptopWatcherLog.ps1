# ============================================================
# DEBUG VERSION - LaptopModeTest_Debug.ps1
# Adds a log file, timestamped entries, and verbose output
# at every major step so failures are easy to pinpoint.
# ============================================================

$DebugLogPath = "C:\Users\brend\Documents\PowerShell\Scripts\SelfMade\ScriptData\LaptopModeDebug.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [string]$Color)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $DebugLogPath -Value $entry
    # Also echo to the console so you see it live if the window is open
    if (-not $Color) {
        if ($Level -eq "ERROR") {
            $Color = "DarkRed" 
        } elseif ($Level -eq "WARN") {
            $Color = "DarkYellow"
        } else {
            $Color = "White" 
        }
    }

    Write-Host $entry -ForegroundColor $Color
}

# ------------------------------------------------------------------
# Startup
# ------------------------------------------------------------------
Write-Log "===== Script started ====="
Write-Log "Log file: $DebugLogPath"
Write-Log "Running as user: $env:USERNAME  |  Host: $env:COMPUTERNAME"
Write-Log "PowerShell version: $($PSVersionTable.PSVersion)"

# ------------------------------------------------------------------
# Verify backup folder exists
# ------------------------------------------------------------------
$backupDir = "C:\Users\brend\Documents\PowerShell\Scripts\SelfMade\ScriptData"
if (-not (Test-Path $backupDir)) {
    Write-Log "Backup directory does not exist - creating: $backupDir" "WARN"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Write-Log "Backup directory created." -Color "Green"
} else {
    Write-Log "Backup directory exists: $backupDir" -Color "Green"
}

# ------------------------------------------------------------------
# Check the registry key we are about to watch actually exists
# ------------------------------------------------------------------
$watchedKey = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"
if (Test-Path $watchedKey) {
    $slateRaw = Get-ItemProperty -Path $watchedKey -Name "ConvertibleSlateMode" -ErrorAction SilentlyContinue
    if ($null -eq $slateRaw) {
        Write-Log "ConvertibleSlateMode value NOT found under $watchedKey - this device may not report slate/laptop mode via this key." "WARN"
    } else {
        Write-Log "ConvertibleSlateMode current raw value: $($slateRaw.ConvertibleSlateMode)  (0=tablet, 1=laptop)"
    }
} else {
    Write-Log "Registry key not found: $watchedKey" "ERROR"
}

# ------------------------------------------------------------------
# Check Windhawk mod keys exist before we try to touch them
# ------------------------------------------------------------------
$modsRoot = "HKLM:\SOFTWARE\Windhawk\Engine\Mods\"
if (Test-Path $modsRoot) {
    $modCount = (Get-ChildItem $modsRoot -ErrorAction SilentlyContinue).Count
    Write-Log "Windhawk mods root found. Child keys: $modCount"
} else {
    Write-Log "Windhawk mods root NOT found: $modsRoot  - GetReg/SetReg will fail." "WARN"
}

# ------------------------------------------------------------------
# Clean up any stale event subscription
# ------------------------------------------------------------------
Write-Log "Checking for existing 'TabletModeWatch' event subscriber..."
$existing = Get-EventSubscriber -SourceIdentifier "TabletModeWatch" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Log "Found existing subscriber (Id $($existing.SubscriptionId)) - unregistering."
    $existing | Unregister-Event
    Write-Log "Old subscriber removed." -Color "Green"
} else {
    Write-Log "No existing subscriber found - nothing to clean up."
}

# ------------------------------------------------------------------
# WMI query
# ------------------------------------------------------------------
$regQuery = "Select * from RegistryKeyChangeEvent WHERE Hive='HKEY_LOCAL_MACHINE' AND KeyPath='SYSTEM\\CurrentControlSet\\Control\\PriorityControl'"
Write-Log "WMI query: $regQuery"

# ------------------------------------------------------------------
# Register the event (with the required namespace)
# ------------------------------------------------------------------
Write-Log "Registering WMI event listener (Namespace: root\default)..."
try {
    Register-WmiEvent -Namespace "root\default" -Query $regQuery -SourceIdentifier "TabletModeWatch" -Action {

        # ---- helpers inside the action block need their own log writer ----
        $DebugLogPath = "C:\Users\brend\Documents\PowerShell\Scripts\SelfMade\ScriptData\LaptopModeDebug.log"
        function Write-Log {
            param([string]$Message, [string]$Level = "INFO", [string]$Color)
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
            $entry = "[$timestamp] [$Level] $Message"
            Add-Content -Path $DebugLogPath -Value $entry
            # Also echo to the console so you see it live if the window is open
            if (-not $Color) {
                if ($Level -eq "ERROR") {
                    $Color = "DarkRed" 
                } elseif ($Level -eq "WARN") {
                    $Color = "DarkYellow"
                } else {
                    $Color = "White" 
                }
            }

            Write-Host $entry -ForegroundColor $Color
        }

        Write-Log "----- Registry change event fired -----" -Color "Magenta"

        # ---- GetReg: snapshot current Windhawk Disabled values to JSON ----
        function GetReg {
            Write-Log "[GetReg] Reading Windhawk mod keys..."
            $modsRoot = "HKLM:\SOFTWARE\Windhawk\Engine\Mods\"

            if (-not (Test-Path $modsRoot)) {
                Write-Log "[GetReg] ERROR: Mods root key not found: $modsRoot" "ERROR"
                return
            }

            $children = Get-ChildItem $modsRoot -ErrorAction SilentlyContinue
            Write-Log "[GetReg] Found $($children.Count) mod key(s)." -Color "Green"

            $regValues = $children | ForEach-Object {
                $keyName = $_.PSChildName
                try {
                    $regValue = (Get-ItemProperty -Path $_.PSPath -Name "Disabled" -ErrorAction Stop).Disabled
                    Write-Log "[GetReg]   Mod: '$keyName'  Disabled=$regValue"
                    [PSCustomObject]@{ ModKey = $keyName; Disabled = $regValue }
                } catch {
                    Write-Log "[GetReg]   Mod: '$keyName'  WARNING - 'Disabled' value missing, defaulting to 0. Error: $_" "WARN"
                    [PSCustomObject]@{ ModKey = $keyName; Disabled = 0 }
                }
            }

            $backupPath = "C:\Users\brend\Documents\PowerShell\Scripts\SelfMade\ScriptData\windhawk-registry-keys.json"
            try {
                $json = $regValues | ConvertTo-Json
                $json | Out-File -FilePath $backupPath -Encoding utf8
                Write-Log "[GetReg] Snapshot written to: $backupPath" -Color "Green"
                Write-Log "[GetReg] JSON content:`n$json"
            } catch {
                Write-Log "[GetReg] ERROR writing snapshot: $_" "ERROR"
            }
        }

        # ---- SetReg: restore or disable all mods ----
        function SetReg {
            param([bool]$restore = $false)
            Write-Log "[SetReg] Called with restore=$restore" -Color "Magenta"

            $backupPath = "C:\Users\brend\Documents\PowerShell\Scripts\SelfMade\ScriptData\windhawk-registry-keys.json"

            if (-not (Test-Path $backupPath)) {
                Write-Log "[SetReg] ERROR: Backup JSON not found at: $backupPath" "ERROR"
                return
            }

            try {
                # BUG FIX: must parse JSON - raw Get-Content returns strings, not objects
                $regValues = Get-Content -Path $backupPath -Raw -ErrorAction Stop | ConvertFrom-Json
                Write-Log "[SetReg] Loaded $($regValues.Count) mod(s) from backup." -Color "Green"
            } catch {
                Write-Log "[SetReg] ERROR reading/parsing backup JSON: $_" "ERROR"
                return
            }

            foreach ($mod in $regValues) {
                $modRegPath = Join-Path "HKLM:\SOFTWARE\Windhawk\Engine\Mods\" $mod.ModKey
                $value = if ($restore) { $mod.Disabled } else { 1 }
                Write-Log "[SetReg]   Setting '$($mod.ModKey)' Disabled=$value  (path: $modRegPath)"

                if (-not (Test-Path $modRegPath)) {
                    Write-Log "[SetReg]   WARN: Key does not exist, skipping: $modRegPath" "WARN"
                    continue
                }

                try {
                    Set-ItemProperty -Path $modRegPath -Name "Disabled" -Value $value -ErrorAction Stop
                    Write-Log "[SetReg]   OK"
                } catch {
                    Write-Log "[SetReg]   ERROR setting value: $_" "ERROR"
                }
            }
        }

        # ---- Wait for the registry write to settle ----
        Write-Log "Sleeping 300ms for registry value to settle..."
        Start-Sleep -Milliseconds 300

        # ---- Read current mode ----
        try {
            $rawSlate = Get-ItemPropertyValue `
                -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" `
                -Name "ConvertibleSlateMode" `
                -ErrorAction Stop
            Write-Log "ConvertibleSlateMode raw value after event: $rawSlate  (0=tablet, 1=laptop)"
        } catch {
            Write-Log "ERROR reading ConvertibleSlateMode: $_" "ERROR"
            return
        }

        # BUG NOTE: [bool]0 = $false (tablet), [bool]1 = $true (laptop)
        # Variable name says "isTabletMode" but is actually $true when in LAPTOP mode
        $isLaptopMode = [bool]$rawSlate
        Write-Log "isLaptopMode (bool): $isLaptopMode"

        # ---- Check Windhawk process ----
        $process = Get-Process windhawk -ErrorAction SilentlyContinue
        if ($process) {
            Write-Log "Windhawk process found - PID: $($process.Id)" -Color "Green"
        } else {
            Write-Log "Windhawk process NOT running - mod enable/disable will still apply to registry." "WARN"
        }

        # ---- Branch ----
        if ($isLaptopMode -and $process) {
            Write-Log "Branch: ENTERING LAPTOP MODE - restoring (re-enabling) mods."
            SetReg -restore $true
        } else {
            Write-Log "Branch: ENTERING TABLET MODE - snapshotting then disabling mods.  (isLaptopMode=$isLaptopMode, processFound=$([bool]$process))"
            GetReg
            SetReg -restore $false
        }

        Write-Log "----- Event handler complete -----"
    }

    Write-Log "WMI event listener registered successfully. Waiting for registry changes..." -Color "Green"
} catch {
    Write-Log "FATAL: Failed to register WMI event: $_" "ERROR"
    Write-Log "Common cause: missing -Namespace 'root\default', or insufficient permissions." "ERROR"
}

Write-Log "Script setup complete. The action block will fire on next ConvertibleSlateMode change." -Color "Green"