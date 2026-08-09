<#
    Laptop Repair Toolkit - ONE-FILE INSTALLER
    ------------------------------------------
    Everything (both scripts, both launchers, the README) is embedded below.

    To use it at work:
      1. Save this page as  Install-RepairToolkit.ps1  in the folder you want
         the toolkit in (e.g. your USB tools folder).
      2. Right-click it > Run with PowerShell.
         If that is blocked, open a terminal in that folder and run:
             powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RepairToolkit.ps1
      3. It writes out 5 files next to itself. Delete this installer afterwards.

    From then on it is just: double-click Start-Repair.cmd / Finish-Repair.cmd.
    No admin rights needed to install - only to run the toolkit itself.
#>

$ErrorActionPreference = 'Stop'
$dest = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$files = [ordered]@{}

$files['Start-Repair.ps1'] = @'
<#
.SYNOPSIS
    Laptop Repair Toolkit - run at the START of a repair.
.DESCRIPTION
    Saves the active power plan's display / sleep / hibernate timeouts and
    the lid-close action to C:\ProgramData\LaptopRepairToolkit\PowerState.json,
    then sets them all to "Never" / "Do nothing" so the machine stays awake
    on AC and battery for the whole job.

    Run Finish-Repair.cmd when the job is done to restore the exact values.

    Normally launched via Start-Repair.cmd, which handles execution policy
    and elevation automatically.
.NOTES
    - Reads every value BEFORE changing anything; aborts untouched on failure.
    - Refuses to run twice in a row so saved values can't be overwritten.
    - Parses English powercfg output.
#>

# ---- relaunch elevated if needed --------------------------------------------
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$ErrorActionPreference = 'Stop'
$StateDir  = Join-Path $env:ProgramData 'LaptopRepairToolkit'
$StateFile = Join-Path $StateDir 'PowerState.json'

function Wait-Close([int]$Code = 0) {
    Read-Host 'Press Enter to close' | Out-Null
    exit $Code
}

# Runs powercfg and throws if it reports failure (native exes don't throw).
function Invoke-PowerCfg {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PcArgs)
    $null = & powercfg.exe @PcArgs
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($PcArgs -join ' ') failed (exit code $LASTEXITCODE)" }
}

# Reads the current AC + DC index of one power setting on the active scheme.
function Get-PowerValue([string]$SubGroup, [string]$Setting) {
    $text = (powercfg.exe /query SCHEME_CURRENT $SubGroup $Setting) -join "`n"
    $ac = [regex]::Match($text, 'Current AC Power Setting Index:\s*0x([0-9A-Fa-f]+)')
    $dc = [regex]::Match($text, 'Current DC Power Setting Index:\s*0x([0-9A-Fa-f]+)')
    if (-not ($ac.Success -and $dc.Success)) {
        throw "Could not read $SubGroup/$Setting (missing setting, or non-English Windows UI)."
    }
    [pscustomobject]@{
        SubGroup = $SubGroup
        Setting  = $Setting
        AC       = [Convert]::ToInt64($ac.Groups[1].Value, 16)
        DC       = [Convert]::ToInt64($dc.Groups[1].Value, 16)
    }
}

try {
    if (Test-Path $StateFile) {
        Write-Host 'Repair mode is ALREADY active on this machine.' -ForegroundColor Yellow
        Write-Host "Run Finish-Repair when the job is done, or delete:`n  $StateFile"
        Wait-Close
    }

    # ---- read everything first ----------------------------------------------
    $schemeLine = (powercfg.exe /getactivescheme) -join ' '
    $m = [regex]::Match($schemeLine, '([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})\s*\((.*)\)')
    if (-not $m.Success) { throw 'Could not read the active power scheme.' }
    $schemeGuid = $m.Groups[1].Value
    $schemeName = $m.Groups[2].Value

    $saved = @(
        Get-PowerValue SUB_VIDEO   VIDEOIDLE       # display-off timeout (seconds)
        Get-PowerValue SUB_SLEEP   STANDBYIDLE     # sleep timeout (seconds)
        Get-PowerValue SUB_SLEEP   HIBERNATEIDLE   # hibernate timeout (seconds)
    )
    $lid = $null
    try { $lid = Get-PowerValue SUB_BUTTONS LIDACTION } catch { }   # absent on some machines

    # ---- save state (before touching anything) ------------------------------
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    [ordered]@{
        SchemeGuid = $schemeGuid
        SchemeName = $schemeName
        Values     = @($saved) + @($lid | Where-Object { $_ })
        SavedAt    = (Get-Date).ToString('s')
        Computer   = $env:COMPUTERNAME
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8

    # ---- set everything to Never / Do nothing -------------------------------
    foreach ($v in $saved) {
        Invoke-PowerCfg /setacvalueindex $schemeGuid $v.SubGroup $v.Setting 0
        Invoke-PowerCfg /setdcvalueindex $schemeGuid $v.SubGroup $v.Setting 0
    }
    if ($lid) {
        Invoke-PowerCfg /setacvalueindex $schemeGuid SUB_BUTTONS LIDACTION 0   # 0 = do nothing
        Invoke-PowerCfg /setdcvalueindex $schemeGuid SUB_BUTTONS LIDACTION 0
    }
    Invoke-PowerCfg /setactive $schemeGuid

    Write-Host ''
    Write-Host 'REPAIR MODE ON' -ForegroundColor Green
    Write-Host "  Power plan: $schemeName"
    Write-Host '  - Display: never turns off (AC + battery)'
    Write-Host '  - Sleep / hibernate: never (AC + battery)'
    if ($lid) { Write-Host '  - Lid close: does nothing' }
    Write-Host "  - Previous values saved to: $StateFile"
    Write-Host ''
    Write-Host 'Run Finish-Repair.cmd at the end of the job to restore and test.'
    Wait-Close
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    Wait-Close 1
}
'@

$files['Finish-Repair.ps1'] = @'
<#
.SYNOPSIS
    Laptop Repair Toolkit - run at the END of a repair.
.DESCRIPTION
    1. Restores the power settings saved by Start-Repair.ps1. The state file
       is deleted only after a successful restore.
    2. Inventories the hardware.
    3. Automatic checks: storage health, battery (+ battery-report.html),
       WiFi, Bluetooth, camera / audio / mic device presence.
    4. DISM /CheckHealth and SFC /verifyonly (skippable).
    5. Interactive checks: Camera app, test sound, mic input meter, plus
       quick keyboard / touchpad / display / USB prompts (skippable).
    6. Writes everything to Desktop\Laptop Repair Reports\<COMPUTER>_<TIME>\

    Normally launched via Finish-Repair.cmd, which passes switches through:
        Finish-Repair.cmd -SkipSystemFileChecks -SkipInteractiveTests
.PARAMETER SkipSystemFileChecks
    Skip DISM /CheckHealth and SFC /verifyonly (saves several minutes).
.PARAMETER SkipInteractiveTests
    Automatic checks only; opens no apps, asks no questions.
#>
param(
    [switch]$SkipSystemFileChecks,
    [switch]$SkipInteractiveTests
)

# ---- relaunch elevated if needed --------------------------------------------
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($SkipSystemFileChecks) { $argList += ' -SkipSystemFileChecks' }
    if ($SkipInteractiveTests) { $argList += ' -SkipInteractiveTests' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$ErrorActionPreference = 'Stop'
$StateDir  = Join-Path $env:ProgramData 'LaptopRepairToolkit'
$StateFile = Join-Path $StateDir 'PowerState.json'

function Wait-Close([int]$Code = 0) {
    Read-Host 'Press Enter to close' | Out-Null
    exit $Code
}

function Invoke-PowerCfg {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PcArgs)
    $null = & powercfg.exe @PcArgs
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($PcArgs -join ' ') failed (exit code $LASTEXITCODE)" }
}

function Ask([string]$Question) {
    do { $r = (Read-Host "  $Question [y/n]").Trim().ToLower() } until ($r -eq 'y' -or $r -eq 'n')
    $r -eq 'y'
}

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Check, [string]$Status, [string]$Detail = '') {
    $Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    $colour = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'SKIP' { 'DarkGray' } default { 'Yellow' } }
    Write-Host ('  [{0}] {1}{2}' -f $Status.PadRight(4), $Check, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor $colour
}

try {
    # =========================================================================
    # 1. RESTORE POWER SETTINGS
    # =========================================================================
    Write-Host '=== Restoring power settings ===' -ForegroundColor Cyan
    if (Test-Path $StateFile) {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        $restored = $true
        try {
            foreach ($v in $state.Values) {
                Invoke-PowerCfg /setacvalueindex $state.SchemeGuid $v.SubGroup $v.Setting $v.AC
                Invoke-PowerCfg /setdcvalueindex $state.SchemeGuid $v.SubGroup $v.Setting $v.DC
            }
            Invoke-PowerCfg /setactive $state.SchemeGuid
        } catch {
            $restored = $false
            Write-Host "  Restore FAILED: $_" -ForegroundColor Red
            Write-Host "  State file kept so you can retry: $StateFile"
        }
        if ($restored) {
            Remove-Item $StateFile -Force
            Remove-Item $StateDir -Force -ErrorAction SilentlyContinue
            Write-Host "  Power plan '$($state.SchemeName)' restored to pre-repair values." -ForegroundColor Green
        }
    } else {
        Write-Host '  No saved state found (Start-Repair not run, or already restored). Power settings left as-is.' -ForegroundColor Yellow
    }

    # =========================================================================
    # 2. REPORT FOLDER + HARDWARE INVENTORY
    # =========================================================================
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $desktop   = [Environment]::GetFolderPath('Desktop')
    $reportDir = Join-Path $desktop ('Laptop Repair Reports\{0}_{1}' -f $env:COMPUTERNAME, $stamp)
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

    Write-Host ''
    Write-Host '=== Hardware inventory ===' -ForegroundColor Cyan
    $cs    = Get-CimInstance Win32_ComputerSystem
    $bios  = Get-CimInstance Win32_BIOS
    $cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpus  = @(Get-CimInstance Win32_VideoController)
    $os    = Get-CimInstance Win32_OperatingSystem
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

    $inventory = [ordered]@{
        'Machine' = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        'Serial'  = "$($bios.SerialNumber)".Trim()
        'BIOS'    = "$($bios.SMBIOSBIOSVersion)".Trim()
        'CPU'     = "$($cpu.Name)".Trim()
        'RAM'     = "$ramGB GB"
        'GPU'     = ($gpus.Name -join '; ')
        'OS'      = ('{0} (build {1})' -f $os.Caption, $os.BuildNumber)
    }
    foreach ($k in $inventory.Keys) { Write-Host ('  {0,-9} {1}' -f ($k + ':'), $inventory[$k]) }

    # =========================================================================
    # 3. AUTOMATIC CHECKS
    # =========================================================================
    Write-Host ''
    Write-Host '=== Automatic checks ===' -ForegroundColor Cyan

    # Storage health
    try {
        $disks = @(Get-PhysicalDisk)
        $bad   = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        if ($bad.Count) {
            Add-Result 'Storage health' 'FAIL' (($bad | ForEach-Object { "$($_.FriendlyName): $($_.HealthStatus)" }) -join '; ')
        } else {
            Add-Result 'Storage health' 'PASS' (($disks | ForEach-Object { '{0} [{1} GB]' -f $_.FriendlyName, [math]::Round($_.Size / 1GB) }) -join '; ')
        }
    } catch { Add-Result 'Storage health' 'INFO' 'Could not query - use the drive maker''s diagnostic tool' }

    # Battery
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) {
        $acState = if ($bat.BatteryStatus -eq 2) { 'on AC' } else { 'on battery' }
        Add-Result 'Battery' 'INFO' "$($bat.EstimatedChargeRemaining)% charge, $acState"
        try {
            $null = powercfg.exe /batteryreport /output (Join-Path $reportDir 'battery-report.html') 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host '         battery-report.html saved (check design vs full-charge capacity)' -ForegroundColor DarkGray
            }
        } catch { }
    } else {
        Add-Result 'Battery' 'INFO' 'No battery reported (removed, dead, or a desktop)'
    }

    # WiFi
    $wifiAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' })
    if (-not $wifiAdapters.Count) {
        Add-Result 'WiFi' 'FAIL' 'No wireless adapter detected'
    } else {
        $up = $wifiAdapters | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($up) {
            $ssid = ''
            $ssidLine = (netsh.exe wlan show interfaces 2>$null) | Select-String '^\s+SSID\s+:\s+(.+)$' | Select-Object -First 1
            if ($ssidLine) { $ssid = $ssidLine.Matches[0].Groups[1].Value.Trim() }
            $net = Test-Connection -ComputerName 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue
            Add-Result 'WiFi' 'PASS' ('Connected{0}; internet: {1}' -f $(if ($ssid) { " to '$ssid'" } else { '' }), $(if ($net) { 'yes' } else { 'NO' }))
        } else {
            $visible = @((netsh.exe wlan show networks 2>$null) | Select-String '^\s*SSID \d+')
            if ($visible.Count) {
                Add-Result 'WiFi' 'PASS' "Radio works - not connected, but sees $($visible.Count) network(s)"
            } else {
                Add-Result 'WiFi' 'FAIL' "Adapter '$($wifiAdapters[0].InterfaceDescription)' present but sees no networks"
            }
        }
    }

    # Bluetooth
    $bt = @(Get-PnpDevice -Class Bluetooth -Status OK -ErrorAction SilentlyContinue)
    if ($bt.Count) { Add-Result 'Bluetooth' 'PASS' $bt[0].FriendlyName }
    else           { Add-Result 'Bluetooth' 'INFO' 'No Bluetooth device detected' }

    # Device presence - proves Windows sees them; interactive tests prove they work
    $cams = @(Get-PnpDevice -Class Camera, Image -Status OK -ErrorAction SilentlyContinue)
    if ($cams.Count) { Add-Result 'Camera device' 'PASS' $cams[0].FriendlyName }
    else             { Add-Result 'Camera device' 'FAIL' 'No working camera detected' }

    $audio = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })
    if ($audio.Count) { Add-Result 'Audio device' 'PASS' ($audio.Name -join '; ') }
    else              { Add-Result 'Audio device' 'FAIL' 'No working audio device detected' }

    $mics = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue |
              Where-Object { $_.FriendlyName -match 'mic' })
    if ($mics.Count) { Add-Result 'Mic endpoint' 'PASS' $mics[0].FriendlyName }
    else             { Add-Result 'Mic endpoint' 'FAIL' 'No microphone endpoint (also check Settings > Privacy > Microphone)' }

    # =========================================================================
    # 4. SYSTEM FILE CHECKS (DISM + SFC)
    # =========================================================================
    Write-Host ''
    Write-Host '=== System file checks ===' -ForegroundColor Cyan
    if ($SkipSystemFileChecks) {
        Add-Result 'DISM CheckHealth' 'SKIP' '-SkipSystemFileChecks'
        Add-Result 'SFC verify'       'SKIP' '-SkipSystemFileChecks'
    } else {
        $dismLog = Join-Path $reportDir 'dism-checkhealth.txt'
        cmd.exe /c "dism /Online /Cleanup-Image /CheckHealth > `"$dismLog`" 2>&1" | Out-Null
        $dismText = (Get-Content $dismLog -Raw -ErrorAction SilentlyContinue) -replace "`0", ''
        if     ($dismText -match 'No component store corruption detected') { Add-Result 'DISM CheckHealth' 'PASS' }
        elseif ($dismText -match 'repairable|corrupt')                     { Add-Result 'DISM CheckHealth' 'FAIL' 'Corruption flagged - see dism-checkhealth.txt' }
        else                                                               { Add-Result 'DISM CheckHealth' 'INFO' 'See dism-checkhealth.txt' }

        Write-Host '  Running SFC /verifyonly - this takes a few minutes...' -ForegroundColor DarkGray
        $sfcLog = Join-Path $reportDir 'sfc-verifyonly.txt'
        cmd.exe /c "sfc /verifyonly > `"$sfcLog`" 2>&1" | Out-Null
        $sfcText = (Get-Content $sfcLog -Raw -Encoding Unicode -ErrorAction SilentlyContinue) -replace "`0", ''
        if (-not $sfcText -or $sfcText.Length -lt 20) {
            $sfcText = (Get-Content $sfcLog -Raw -ErrorAction SilentlyContinue) -replace "`0", ''
        }
        if     ($sfcText -match 'did not find any integrity violations')    { Add-Result 'SFC verify' 'PASS' }
        elseif ($sfcText -match 'found integrity violations|found corrupt') { Add-Result 'SFC verify' 'FAIL' 'Violations found - see sfc-verifyonly.txt' }
        else                                                                { Add-Result 'SFC verify' 'INFO' 'See sfc-verifyonly.txt' }
    }

    # =========================================================================
    # 5. INTERACTIVE CHECKS
    # =========================================================================
    Write-Host ''
    Write-Host '=== Interactive checks ===' -ForegroundColor Cyan
    if ($SkipInteractiveTests) {
        foreach ($t in 'Webcam picture', 'Speakers', 'Microphone', 'Keyboard', 'Touchpad', 'Display', 'USB ports') {
            Add-Result $t 'SKIP' '-SkipInteractiveTests'
        }
    } else {
        # Webcam
        if ($cams.Count) {
            Write-Host '  Opening the Camera app...' -ForegroundColor DarkGray
            Start-Process 'microsoft.windows.camera:'
            Start-Sleep -Seconds 2
            if (Ask 'Webcam: live picture visible?') { Add-Result 'Webcam picture' 'PASS' } else { Add-Result 'Webcam picture' 'FAIL' }
        } else {
            Add-Result 'Webcam picture' 'FAIL' 'No camera device to test'
        }

        # Speakers
        Write-Host '  Playing a test sound 3 times (check volume is up / not muted)...' -ForegroundColor DarkGray
        try {
            $player = New-Object System.Media.SoundPlayer "$env:windir\Media\tada.wav"
            1..3 | ForEach-Object { $player.PlaySync(); Start-Sleep -Milliseconds 300 }
            if (Ask 'Speakers: heard it clearly?') { Add-Result 'Speakers' 'PASS' } else { Add-Result 'Speakers' 'FAIL' }
        } catch {
            Add-Result 'Speakers' 'FAIL' "Could not play test sound: $_"
        }

        # Microphone
        Write-Host '  Opening Sound settings - talk and watch the Input level meter...' -ForegroundColor DarkGray
        Start-Process 'ms-settings:sound'
        Start-Sleep -Seconds 2
        if (Ask 'Microphone: input meter moves when you speak?') { Add-Result 'Microphone' 'PASS' } else { Add-Result 'Microphone' 'FAIL' }

        # Quick physical checks - edit this list to suit your bench
        $manual = [ordered]@{
            'Keyboard'  = 'Keyboard: all keys respond?'
            'Touchpad'  = 'Touchpad: pointer moves + buttons click?'
            'Display'   = 'Display: no lines, flicker or dead pixels?'
            'USB ports' = 'USB ports: device detected in every port?'
        }
        foreach ($name in $manual.Keys) {
            if (Ask $manual[$name]) { Add-Result $name 'PASS' } else { Add-Result $name 'FAIL' }
        }
    }

    # =========================================================================
    # 6. SUMMARY + REPORT
    # =========================================================================
    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor Cyan
    $fails = @($Results | Where-Object { $_.Status -eq 'FAIL' })
    if ($fails.Count) {
        Write-Host "  $($fails.Count) check(s) FAILED: $(($fails.Check) -join ', ')" -ForegroundColor Red
    } else {
        Write-Host '  All checks passed.' -ForegroundColor Green
    }

    $lines = @(
        'LAPTOP REPAIR TOOLKIT - FINISH REPORT'
        ('Generated: {0}' -f (Get-Date))
        ''
        '--- Hardware ---'
    )
    $lines += foreach ($k in $inventory.Keys) { '{0,-9} {1}' -f ($k + ':'), $inventory[$k] }
    $lines += ''
    $lines += '--- Checks ---'
    $lines += ($Results | Format-Table Check, Status, Detail -AutoSize | Out-String).TrimEnd()
    $lines | Set-Content -Path (Join-Path $reportDir 'Report.txt') -Encoding UTF8

    Write-Host ''
    Write-Host "Report folder: $reportDir"
    Start-Process explorer.exe "`"$reportDir`""
    Wait-Close $(if ($fails.Count) { 1 } else { 0 })
}
catch {
    Write-Host ''
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Wait-Close 1
}
'@

$files['Start-Repair.cmd'] = @'
@echo off
rem Double-click me to start repair mode.
rem The -ExecutionPolicy Bypass below applies to this one PowerShell process
rem only: no Set-ExecutionPolicy step, nothing changed on the machine.
rem The script requests elevation itself, so just approve the UAC prompt.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Repair.ps1" %*
'@

$files['Finish-Repair.cmd'] = @'
@echo off
rem Double-click me to end repair mode and run the checks.
rem Switches pass straight through, e.g.:
rem   Finish-Repair.cmd -SkipSystemFileChecks -SkipInteractiveTests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Finish-Repair.ps1" %*
'@

$files['README.txt'] = @'
Laptop Repair Toolkit
=====================

Files
-----
1. Start-Repair.cmd / Start-Repair.ps1
   Run at the beginning of a repair. Saves the current active power-plan
   display, sleep and hibernate timeout values (AC and battery) plus the
   lid-close action, then sets them all to "Never" / "Do nothing" so the
   machine stays awake for the whole job.

2. Finish-Repair.cmd / Finish-Repair.ps1
   Run at the end. Restores the exact values saved by Start-Repair,
   inventories hardware, performs automatic checks (storage health, battery,
   WiFi, Bluetooth, camera/audio/mic device presence, DISM, SFC), opens
   Windows interfaces for manual camera/speaker/mic checks, asks the
   technician for pass/fail results, and creates a report folder on the
   desktop.

Recommended use
---------------
1. Extract this folder to a trusted technician USB drive or local tools folder.
2. At intake/start:  double-click  Start-Repair.cmd
3. At completion:    double-click  Finish-Repair.cmd

That is the whole workflow. The .cmd launchers start PowerShell with
-ExecutionPolicy Bypass for that one process only, so there is no
Set-ExecutionPolicy step and no policy change is left on the customer's
machine. The scripts request elevation themselves - just approve the UAC
prompt.

Running the .ps1 files from an already-open admin PowerShell window still
works; if they are blocked there, either use the .cmd launchers or run
Unblock-File .\*.ps1 once.

Optional finish modes
---------------------
Skip DISM and SFC checks:

   Finish-Repair.cmd -SkipSystemFileChecks

Skip all manual prompts:

   Finish-Repair.cmd -SkipInteractiveTests

Skip both:

   Finish-Repair.cmd -SkipSystemFileChecks -SkipInteractiveTests

State and reports
-----------------
Saved temporary state:
  C:\ProgramData\LaptopRepairToolkit\PowerState.json

Default report location:
  Desktop\Laptop Repair Reports\<COMPUTERNAME>_<TIMESTAMP>\
  (Report.txt, battery-report.html, DISM and SFC logs)

The saved state is deleted only after the power settings restore
successfully. Start-Repair reads and saves every value before changing
anything, and refuses to run twice in a row, so the original values can
never be overwritten by the "Never" values.

Important limitations
---------------------
- Device detection proves that Windows sees a device; it does not prove that
  the camera image, microphone quality, speaker sound, ports or controls
  function correctly. The finish script therefore includes interactive
  confirmation.
- Get-PhysicalDisk health is useful but is not a substitute for the SSD/HDD
  manufacturer's diagnostic utility or a full SMART analysis.
- SFC /verifyonly checks protected Windows files but does not repair them.
- DISM /CheckHealth is a quick corruption-state check, not a full repair.
- Run the start and finish scripts under the same Windows installation.
- Start-Repair parses English powercfg output; on a non-English Windows UI
  it stops with an error before changing anything.
'@

foreach ($name in $files.Keys) {
    $path = Join-Path $dest $name
    # Force CRLF and plain ASCII: no BOM (cmd.exe dislikes it), correct Windows line endings.
    # Here-strings drop the final newline; add it back so files end cleanly.
    $text = ($files[$name] -replace "`r?`n", "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::ASCII)
    Write-Host ('  wrote {0} ({1:N0} bytes)' -f $name, $text.Length) -ForegroundColor Green
}

Write-Host ''
Write-Host "Laptop Repair Toolkit installed to:`n  $dest" -ForegroundColor Cyan
Write-Host 'Start a job:  double-click Start-Repair.cmd'
Write-Host 'End a job:    double-click Finish-Repair.cmd'
Write-Host ''
Read-Host 'Press Enter to close' | Out-Null
