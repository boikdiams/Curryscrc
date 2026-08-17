<#
    Laptop Repair Toolkit - ONE-FILE INSTALLER
    ------------------------------------------
    All eight toolkit files are embedded below. This single file is the whole
    toolkit - safe to drop in a GitHub repo on its own.

    To use it:
      1. Save this file as  Install-RepairToolkit.ps1  in the folder you want
         the toolkit in (your USB tools folder).
      2. Right-click it > Run with PowerShell.
         If that is blocked, open a terminal in that folder and run:
             powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RepairToolkit.ps1
      3. Open Repair-Config.ps1 and put in your shop WiFi SSIDs and password.

    Re-running this installer is safe: it will NOT overwrite an existing
    Repair-Config.ps1, so your credentials survive an update.

    Committing this installer to GitHub is safe - it carries the CHANGE-ME
    template, not your edited config. It also drops a .gitignore that keeps
    Repair-Config.ps1, State\ and Reports\ out of any repo.

    No admin rights needed to install - only to run the toolkit itself.
#>

$ErrorActionPreference = 'Stop'
$dest = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$files = [ordered]@{}

# Files that must never clobber a customised copy.
$protected = @('Repair-Config.ps1', '.gitignore')

$files['Repair-Config.ps1'] = @'
# =============================================================================
#  Laptop Repair Toolkit - CONFIGURATION
#  This is the only file you normally need to edit.
#  The installer will NOT overwrite this file once it exists.
# =============================================================================

# --- Shop WiFi ---------------------------------------------------------------
# Tried in this order: 5 GHz first, then 2.4 GHz if that fails.
# Both must use the same password. Leave one blank ('') if you only have one.
$ShopSsid5GHz  = 'CHANGE-ME-5G'
$ShopSsid24GHz = 'CHANGE-ME'
$ShopWifiPassword = 'CHANGE-ME'

# Security type of the shop WiFi. Almost always WPA2PSK / AES.
# For WPA3 transition mode leave this as WPA2PSK - it still associates.
$ShopWifiAuth       = 'WPA2PSK'
$ShopWifiEncryption = 'AES'

# Delete the shop WiFi profile from the customer's laptop when Finish-Repair
# ends. Left off, so the profile stays and the machine reconnects on its own
# after a reboot or if it comes back for rework.
# Be aware a kept profile stores the password where any user of that laptop can
# read it back with:  netsh wlan show profile name="..." key=clear
$RemoveWifiProfileOnFinish = $false

# --- Licence / DPK check -----------------------------------------------------
# Write the FULL Windows product key into the report instead of masking all but
# the last 5 characters. Off by default: a tech USB accumulating customers'
# full keys is a liability if the stick goes missing. Turn on if you need the
# old board's key for a rebuild.
$RecordFullProductKey = $false

# --- Windows Update ----------------------------------------------------------
# Finish-Repair only CHECKS for updates and lists them in the report. Nothing
# is downloaded or installed unless you pass -InstallUpdates.
# Set this to $true if you would rather installing be the default.
$InstallUpdatesByDefault = $false

# Include driver updates from Windows Update. Off by default - WU drivers are
# a common cause of "it worked when it left the bench" callbacks.
$UpdateIncludeDrivers = $false

# Give up on the update run after this many minutes.
$UpdateTimeoutMinutes = 90

# --- Battery wear ------------------------------------------------------------
# Wear % = how much of the battery's original design capacity is gone.
# At or above the warn figure the check reports a warning; at or above the fail
# figure it is marked FAIL. Roughly: 20% is a tired battery, 40% is one the
# customer will notice.
$BatteryWearWarnPercent = 20
$BatteryWearFailPercent = 40

# --- Network gate ------------------------------------------------------------
# How many times Finish-Repair retries the WiFi connection on its own before
# it stops and asks you to intervene.
$NetworkRetryCount = 3
'@

$files['Repair-Common.ps1'] = @'
# =============================================================================
#  Laptop Repair Toolkit - SHARED FUNCTIONS
#  Dot-sourced by Start-Repair.ps1 and Finish-Repair.ps1. Do not edit unless
#  you mean to; put your settings in Repair-Config.ps1 instead.
# =============================================================================

function Wait-Close([int]$Code = 0) {
    Read-Host 'Press Enter to close' | Out-Null
    exit $Code
}

# --- USB paths ---------------------------------------------------------------
# Everything lives next to the scripts, on the stick they were run from.

function Get-ToolkitRoot([string]$ScriptRoot) {
    if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
    $probe = Join-Path $ScriptRoot ('.write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item $probe -Force
    } catch {
        throw "Cannot write to the toolkit folder:`n  $ScriptRoot`nThe USB stick is read-only, full, or write-protected. Fix that and re-run."
    }
    $ScriptRoot
}

# One state file per machine, so several laptops can be in flight on one stick.
function Get-MachineKey {
    $serial = ''
    try { $serial = "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch { }
    if (-not $serial -or $serial -match '^(To be filled|Default string|System Serial)') { $serial = 'NOSERIAL' }
    ('{0}_{1}' -f $env:COMPUTERNAME, $serial) -replace '[^A-Za-z0-9._-]', '_'
}

function Get-StateFile([string]$Root) {
    Join-Path $Root ('State\{0}.json' -f (Get-MachineKey))
}

# --- powercfg ----------------------------------------------------------------

function Invoke-PowerCfg {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PcArgs)
    $null = & powercfg.exe @PcArgs
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($PcArgs -join ' ') failed (exit code $LASTEXITCODE)" }
}

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

# --- WiFi --------------------------------------------------------------------

function Get-WlanAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN' } |
        Select-Object -First 1
}

# Parses "netsh wlan show interfaces" into a usable object.
function Get-WlanStatus {
    $text = (netsh.exe wlan show interfaces 2>$null) -join "`n"
    function _f([string]$Label) {
        $m = [regex]::Match($text, ('(?m)^\s*{0}\s*:\s*(.+?)\s*$' -f [regex]::Escape($Label)))
        if ($m.Success) { $m.Groups[1].Value } else { '' }
    }
    [pscustomobject]@{
        State  = _f 'State'
        Ssid   = _f 'SSID'
        Band   = _f 'Band'          # blank on older Windows 10 builds
        Radio  = _f 'Radio type'
        Signal = _f 'Signal'
    }
}

# Returns 'Internet', 'CaptivePortal' or 'None'.
function Test-InternetAccess {
    try {
        $req = [System.Net.WebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $req.Timeout = 8000
        $req.Proxy   = $null
        $resp = $req.GetResponse()
        $sr   = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd().Trim()
        $sr.Close(); $resp.Close()
        if ($body -eq 'Microsoft Connect Test') { return 'Internet' }
        return 'CaptivePortal'
    } catch { }
    try {
        $c   = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('1.1.1.1', 443, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(4000, $false) -and $c.Connected
        $c.Close()
        if ($ok) { return 'Internet' }
    } catch { }
    'None'
}

function New-WlanProfileXml {
    param([string]$Ssid, [string]$Password, [string]$Auth, [string]$Encryption)
    $hex     = -join ([System.Text.Encoding]::UTF8.GetBytes($Ssid) | ForEach-Object { '{0:X2}' -f $_ })
    $ssidEsc = [System.Security.SecurityElement]::Escape($Ssid)
    $pwEsc   = [System.Security.SecurityElement]::Escape($Password)
    @"
<?xml version="1.0" encoding="US-ASCII"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssidEsc</name>
  <SSIDConfig>
    <SSID>
      <hex>$hex</hex>
      <name>$ssidEsc</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>$Auth</authentication>
        <encryption>$Encryption</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$pwEsc</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
}

# Adds the profile and connects. Returns $true once associated to $Ssid.
function Connect-WlanSsid {
    param([string]$Ssid, [string]$Password, [string]$Auth, [string]$Encryption,
          [string]$InterfaceName, [int]$TimeoutSeconds = 25)

    $xml  = New-WlanProfileXml -Ssid $Ssid -Password $Password -Auth $Auth -Encryption $Encryption
    $temp = Join-Path $env:TEMP ('wlan-{0}.xml' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temp, $xml, [System.Text.Encoding]::ASCII)
        $addOut = & netsh.exe wlan add profile filename="$temp" user=all 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "    profile import failed: $($addOut -join ' ')" -ForegroundColor DarkGray; return $false }
    } finally {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }

    if ($InterfaceName) { $null = & netsh.exe wlan connect name="$Ssid" ssid="$Ssid" interface="$InterfaceName" 2>&1 }
    else                { $null = & netsh.exe wlan connect name="$Ssid" ssid="$Ssid" 2>&1 }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $s = Get-WlanStatus
        if ($s.State -eq 'connected' -and $s.Ssid -eq $Ssid) { return $true }
    }
    $false
}

<#
  Connects to the shop WiFi: 5 GHz first, 2.4 GHz second.
  Returns an object: Connected, Ssid, Band, Internet, Message.
#>
function Connect-ShopWifi {
    param([string]$Ssid5, [string]$Ssid24, [string]$Password,
          [string]$Auth = 'WPA2PSK', [string]$Encryption = 'AES')

    $result = [pscustomobject]@{ Connected = $false; Ssid = ''; Band = ''; Internet = 'None'; Message = '' }

    if (-not $Password -or $Password -eq 'CHANGE-ME') {
        $result.Message = 'WiFi credentials not set - edit Repair-Config.ps1'
        return $result
    }

    # WLAN AutoConfig service must be running or every netsh wlan call fails.
    $svc = Get-Service WlanSvc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Host '    starting WLAN AutoConfig service...' -ForegroundColor DarkGray
        try { Start-Service WlanSvc -ErrorAction Stop; Start-Sleep -Seconds 3 } catch { }
    }

    $adapter = Get-WlanAdapter
    if (-not $adapter) {
        $result.Message = 'No wireless adapter detected (card dead, disabled in BIOS, or driver missing)'
        return $result
    }
    if ($adapter.Status -eq 'Disabled') {
        Write-Host '    wireless adapter disabled - enabling...' -ForegroundColor DarkGray
        try { Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 4 } catch { }
    }

    $targets = @($Ssid5, $Ssid24) | Where-Object { $_ -and $_ -notmatch '^CHANGE-ME' }
    if (-not $targets.Count) {
        $result.Message = 'No SSIDs configured - edit Repair-Config.ps1'
        return $result
    }

    # Already on one of ours with working internet? Leave it alone.
    $now = Get-WlanStatus
    if ($now.State -eq 'connected' -and $targets -contains $now.Ssid) {
        $net = Test-InternetAccess
        if ($net -eq 'Internet') {
            $result.Connected = $true; $result.Ssid = $now.Ssid; $result.Band = $now.Band
            $result.Internet = $net; $result.Message = 'Already connected'
            return $result
        }
    }

    foreach ($ssid in $targets) {
        $label = if ($ssid -eq $Ssid5) { '5 GHz' } else { '2.4 GHz' }
        Write-Host "    trying $label SSID '$ssid'..." -ForegroundColor DarkGray
        if (Connect-WlanSsid -Ssid $ssid -Password $Password -Auth $Auth -Encryption $Encryption -InterfaceName $adapter.Name) {
            $s   = Get-WlanStatus
            $net = Test-InternetAccess
            $result.Connected = $true
            $result.Ssid      = $ssid
            $result.Band      = if ($s.Band) { $s.Band } else { $label + ' (expected)' }
            $result.Internet  = $net
            if     ($net -eq 'Internet')      { $result.Message = "Connected to '$ssid'" }
            elseif ($net -eq 'CaptivePortal') { $result.Message = "Associated to '$ssid' but a captive portal is intercepting traffic" }
            else                              { $result.Message = "Associated to '$ssid' but no internet (check the AP/uplink)" }
            return $result
        }
        Write-Host "    $label failed" -ForegroundColor DarkGray
    }

    $result.Message = 'Could not associate to either SSID (wrong password, out of range, or radio off / airplane mode)'
    $result
}

function Remove-ShopWifiProfile {
    param([string[]]$Ssids)
    foreach ($s in $Ssids) {
        if ($s -and $s -notmatch '^CHANGE-ME') { $null = & netsh.exe wlan delete profile name="$s" i=* 2>&1 }
    }
}

# --- Windows licence / DPK ---------------------------------------------------

function Format-ProductKey {
    param([string]$Key, [bool]$Full = $false)
    if (-not $Key) { return '' }
    if ($Full)     { return $Key }
    if ($Key.Length -ge 5) { return '*****-*****-*****-*****-' + $Key.Substring($Key.Length - 5) }
    $Key
}

<#
  Reads the OEM Digital Product Key held in firmware (the ACPI MSDM table),
  the key Windows is actually running on, and the activation state.
  On a board swap the firmware key changes - the Matches flag catches that.
#>
function Get-WindowsLicenceInfo {
    param([bool]$FullKey = $false)

    $out = [pscustomobject]@{
        Status = 'INFO'; Detail = ''; Edition = ''; Channel = ''
        Activation = ''; FirmwareKey = ''; InstalledPartial = ''
        Matches = $null; GraceDays = $null
    }

    try {
        $sls = Get-CimInstance SoftwareLicensingService -ErrorAction Stop
        $fw  = "$($sls.OA3xOriginalProductKey)".Trim()

        $prod = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop -Filter `
            "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
            Select-Object -First 1

        if (-not $prod) {
            $out.Status = 'FAIL'
            $out.Detail = 'No licensed Windows product found - not activated'
            return $out
        }

        $out.Edition          = "$($prod.Name)".Trim()
        $out.InstalledPartial = "$($prod.PartialProductKey)".Trim()
        $ch = [regex]::Match("$($prod.Description)", '([A-Za-z0-9_]+)\s+channel')
        if ($ch.Success) { $out.Channel = $ch.Groups[1].Value }

        $out.Activation = switch ([int]$prod.LicenseStatus) {
            0 { 'Unlicensed' }
            1 { 'Licensed' }
            2 { 'Out-of-box grace' }
            3 { 'Out-of-tolerance grace' }
            4 { 'Non-genuine grace' }
            5 { 'Notification mode - NOT activated' }
            6 { 'Extended grace' }
            default { "Unknown status $($prod.LicenseStatus)" }
        }
        if ($prod.GracePeriodRemaining -gt 0) {
            $out.GraceDays = [math]::Round($prod.GracePeriodRemaining / 1440, 1)
        }

        if ($fw) {
            $out.FirmwareKey = Format-ProductKey -Key $fw -Full $FullKey
            if ($out.InstalledPartial) {
                $out.Matches = ($fw.Substring($fw.Length - 5) -eq $out.InstalledPartial)
            }
        }

        $bits = @()
        $bits += $out.Edition
        if ($out.Channel) { $bits += "$($out.Channel) channel" }
        $bits += $out.Activation
        if ($out.GraceDays) { $bits += "$($out.GraceDays) days grace left" }
        $out.Detail = $bits -join ' / '

        switch ([int]$prod.LicenseStatus) {
            1 { $out.Status = 'PASS' }
            0 { $out.Status = 'FAIL' }
            5 { $out.Status = 'FAIL' }
            default { $out.Status = 'INFO' }
        }
    }
    catch {
        $out.Status = 'INFO'
        $out.Detail = "Could not read licence info: $($_.Exception.Message)"
    }
    $out
}

# --- Battery health ----------------------------------------------------------

<#
  Real wear figures come from the battery report, not WMI: Win32_Battery
  reports DesignCapacity as null on most laptops.
  Writes battery-report.html (for the customer/job file) and a machine-readable
  XML alongside it, then parses the XML for design vs full-charge capacity.
#>
function Get-BatteryHealth {
    param([string]$ReportDir, [double]$WarnPercent = 20, [double]$FailPercent = 40)

    $out = [pscustomobject]@{
        Present = $false; Charge = $null; PowerSource = ''
        Batteries = @(); Status = 'INFO'; Detail = ''
    }

    $wmi = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($wmi.Count) {
        $out.Present     = $true
        $out.Charge      = $wmi[0].EstimatedChargeRemaining
        $out.PowerSource = if ($wmi[0].BatteryStatus -eq 2) { 'on AC' } else { 'on battery' }
    }

    $xmlPath = Join-Path $ReportDir 'battery-report.xml'
    try {
        $null = powercfg.exe /batteryreport /output (Join-Path $ReportDir 'battery-report.html') 2>$null
        $null = powercfg.exe /batteryreport /output $xmlPath /xml 2>$null
    } catch { }

    if (-not (Test-Path $xmlPath)) {
        if (-not $out.Present) { $out.Detail = 'No battery reported (removed, dead, or a desktop)' }
        else { $out.Detail = "$($out.Charge)% charge, $($out.PowerSource); wear unavailable (no battery report)" }
        return $out
    }

    try {
        [xml]$xml = Get-Content $xmlPath -Raw
        # local-name() so the report's XML namespace does not matter.
        $nodes = $xml.SelectNodes("//*[local-name()='Batteries']/*[local-name()='Battery']")

        foreach ($n in $nodes) {
            function _num($name) {
                $e = $n.SelectSingleNode("*[local-name()='$name']")
                if ($e -and $e.InnerText -match '^\d+$') { [double]$e.InnerText } else { $null }
            }
            function _txt($name) {
                $e = $n.SelectSingleNode("*[local-name()='$name']")
                if ($e) { "$($e.InnerText)".Trim() } else { '' }
            }

            $design = _num 'DesignCapacity'
            $full   = _num 'FullChargeCapacity'
            $cycles = _num 'CycleCount'

            $wear = $null; $health = $null
            if ($design -and $design -gt 0 -and $full -ne $null) {
                $health = [math]::Round(($full / $design) * 100, 1)
                $wear   = [math]::Round(100 - $health, 1)
            }

            $out.Batteries += [pscustomobject]@{
                Name       = (_txt 'Id')
                Maker      = (_txt 'Manufacturer')
                Chemistry  = (_txt 'Chemistry')
                DesignmWh  = $design
                FullmWh    = $full
                Cycles     = $cycles
                HealthPct  = $health
                WearPct    = $wear
            }
        }
    } catch {
        $out.Detail = "Could not parse battery report: $($_.Exception.Message)"
        return $out
    }

    if (-not $out.Batteries.Count) {
        if (-not $out.Present) { $out.Detail = 'No battery reported (removed, dead, or a desktop)' }
        else { $out.Detail = "$($out.Charge)% charge, $($out.PowerSource); no battery data in report" }
        return $out
    }

    $out.Present = $true
    $measured = @($out.Batteries | Where-Object { $_.WearPct -ne $null })
    if (-not $measured.Count) {
        $out.Detail = 'Battery detected but it does not report a design capacity - wear cannot be calculated'
        return $out
    }

    $worst = ($measured | Sort-Object WearPct -Descending)[0]
    if     ($worst.WearPct -ge $FailPercent) { $out.Status = 'FAIL' }
    elseif ($worst.WearPct -ge $WarnPercent) { $out.Status = 'WARN' }
    else                                     { $out.Status = 'PASS' }

    $bits = @('{0}% wear ({1}% of original capacity)' -f $worst.WearPct, $worst.HealthPct)
    if ($worst.DesignmWh) { $bits += '{0:N0} of {1:N0} mWh' -f $worst.FullmWh, $worst.DesignmWh }
    if ($worst.Cycles)    { $bits += '{0:N0} cycles' -f $worst.Cycles }
    if ($measured.Count -gt 1) { $bits += "worst of $($measured.Count) batteries" }
    $out.Detail = $bits -join ', '
    $out
}

# --- Windows Update ----------------------------------------------------------
# Uses the built-in Microsoft.Update COM API - no module install, no internet
# download of tooling, works on a stock Windows box.

function Invoke-WindowsUpdate {
    param([bool]$IncludeDrivers = $false, [int]$TimeoutMinutes = 90, [bool]$Install = $false)

    $out = [pscustomobject]@{
        Status = 'INFO'; Detail = ''; Installed = 0; Failed = 0
        RebootRequired = $false; Titles = @()
    }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $criteria = "IsInstalled=0 AND IsHidden=0"
        if (-not $IncludeDrivers) { $criteria += " AND Type='Software'" }

        Write-Host '  Searching Windows Update...' -ForegroundColor DarkGray
        $found = $searcher.Search($criteria)

        if ($found.Updates.Count -eq 0) {
            $out.Status = 'PASS'; $out.Detail = 'No updates available'
            return $out
        }
        Write-Host "  $($found.Updates.Count) update(s) available" -ForegroundColor DarkGray
        foreach ($u in $found.Updates) {
            $out.Titles += $u.Title
            Write-Host "    - $($u.Title)" -ForegroundColor DarkGray
        }

        # Check-only: nothing is downloaded, no EULA accepted, nothing changed.
        if (-not $Install) {
            $out.Status = 'INFO'
            $out.Detail = "$($found.Updates.Count) update(s) available, NOT installed (add -InstallUpdates)"
            return $out
        }

        $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $found.Updates) {
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
            $null = $toDownload.Add($u)
        }

        if ((Get-Date) -gt $deadline) { $out.Status = 'INFO'; $out.Detail = 'Timed out before download'; return $out }

        Write-Host '  Downloading...' -ForegroundColor DarkGray
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toDownload
        $null = $downloader.Download()

        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $found.Updates) { if ($u.IsDownloaded) { $null = $toInstall.Add($u) } }

        if ($toInstall.Count -eq 0) {
            $out.Status = 'FAIL'; $out.Detail = 'Updates found but none downloaded'
            return $out
        }

        Write-Host "  Installing $($toInstall.Count) update(s) - this can take a while..." -ForegroundColor DarkGray
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $res = $installer.Install()

        $out.RebootRequired = [bool]$res.RebootRequired
        for ($i = 0; $i -lt $toInstall.Count; $i++) {
            if ($res.GetUpdateResult($i).ResultCode -eq 2) { $out.Installed++ } else { $out.Failed++ }
        }
        # 2 = succeeded, 3 = succeeded with errors, 4 = failed, 5 = aborted
        switch ($res.ResultCode) {
            2 { $out.Status = 'PASS' }
            3 { $out.Status = 'INFO' }
            default { $out.Status = 'FAIL' }
        }
        $out.Detail = "$($out.Installed) installed, $($out.Failed) failed"
        if ($out.RebootRequired) { $out.Detail += ', REBOOT REQUIRED' }
    }
    catch {
        $out.Status = 'FAIL'
        $out.Detail = "Windows Update error: $($_.Exception.Message)"
    }
    $out
}
'@

$files['Start-Repair.ps1'] = @'
<#
.SYNOPSIS
    Laptop Repair Toolkit - run at the START of a repair.
.DESCRIPTION
    1. Saves the active power plan's display / sleep / hibernate timeouts and
       the lid-close action, then sets them all to "Never" / "Do nothing".
    2. Connects to the shop WiFi: 5 GHz SSID first, 2.4 GHz as fallback.

    State is written to  <toolkit folder>\State\<COMPUTER>_<SERIAL>.json  on the
    stick this script was run from, so several machines can be in flight at once.

    WiFi failure here is a warning, not a stop - a dead card may be the fault
    you are about to fix. Finish-Repair is the one that refuses to continue.
.NOTES
    Launch via Start-Repair.cmd. Requires admin (it elevates itself).
#>

# ---- relaunch elevated if needed --------------------------------------------
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Repair-Common.ps1')
. (Join-Path $PSScriptRoot 'Repair-Config.ps1')

try {
    $Root      = Get-ToolkitRoot $PSScriptRoot
    $StateFile = Get-StateFile $Root

    if (Test-Path $StateFile) {
        Write-Host 'Repair mode is ALREADY active on this machine.' -ForegroundColor Yellow
        Write-Host "Run Finish-Repair when the job is done, or delete:`n  $StateFile"
        Wait-Close
    }

    # =========================================================================
    # 1. POWER SETTINGS
    # =========================================================================
    Write-Host '=== Power settings ===' -ForegroundColor Cyan

    $schemeLine = (powercfg.exe /getactivescheme) -join ' '
    $m = [regex]::Match($schemeLine, '([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})\s*\((.*)\)')
    if (-not $m.Success) { throw 'Could not read the active power scheme.' }
    $schemeGuid = $m.Groups[1].Value
    $schemeName = $m.Groups[2].Value

    # Read everything BEFORE changing anything, so a failure leaves no mess.
    $saved = @(
        Get-PowerValue SUB_VIDEO VIDEOIDLE       # display-off timeout (seconds)
        Get-PowerValue SUB_SLEEP STANDBYIDLE     # sleep timeout (seconds)
        Get-PowerValue SUB_SLEEP HIBERNATEIDLE   # hibernate timeout (seconds)
    )
    $lid = $null
    try { $lid = Get-PowerValue SUB_BUTTONS LIDACTION } catch { }   # absent on some machines

    New-Item -ItemType Directory -Path (Split-Path $StateFile -Parent) -Force | Out-Null
    [ordered]@{
        SchemeGuid = $schemeGuid
        SchemeName = $schemeName
        Values     = @($saved) + @($lid | Where-Object { $_ })
        SavedAt    = (Get-Date).ToString('s')
        Computer   = $env:COMPUTERNAME
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8

    foreach ($v in $saved) {
        Invoke-PowerCfg /setacvalueindex $schemeGuid $v.SubGroup $v.Setting 0
        Invoke-PowerCfg /setdcvalueindex $schemeGuid $v.SubGroup $v.Setting 0
    }
    if ($lid) {
        Invoke-PowerCfg /setacvalueindex $schemeGuid SUB_BUTTONS LIDACTION 0   # 0 = do nothing
        Invoke-PowerCfg /setdcvalueindex $schemeGuid SUB_BUTTONS LIDACTION 0
    }
    Invoke-PowerCfg /setactive $schemeGuid

    Write-Host "  Plan '$schemeName': display / sleep / hibernate set to Never (AC + battery)" -ForegroundColor Green
    if ($lid) { Write-Host '  Lid close: does nothing' -ForegroundColor Green }
    Write-Host "  Previous values saved to: $StateFile" -ForegroundColor DarkGray

    # =========================================================================
    # 2. SHOP WIFI
    # =========================================================================
    Write-Host ''
    Write-Host '=== Shop WiFi ===' -ForegroundColor Cyan
    $wifi = Connect-ShopWifi -Ssid5 $ShopSsid5GHz -Ssid24 $ShopSsid24GHz `
                             -Password $ShopWifiPassword -Auth $ShopWifiAuth -Encryption $ShopWifiEncryption

    if ($wifi.Connected -and $wifi.Internet -eq 'Internet') {
        Write-Host "  $($wifi.Message) [$($wifi.Band)]" -ForegroundColor Green
    } elseif ($wifi.Connected) {
        Write-Host "  $($wifi.Message)" -ForegroundColor Yellow
    } else {
        Write-Host "  WiFi NOT connected: $($wifi.Message)" -ForegroundColor Yellow
        Write-Host '  Carrying on - if the WiFi card is the fault, that is what you are here to fix.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'REPAIR MODE ON' -ForegroundColor Green
    Write-Host 'Run Finish-Repair.cmd at the end of the job to restore, update and QA.'
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
    Order matters here:
      1. NETWORK GATE - confirms shop WiFi + internet, retrying the 5 GHz then
         2.4 GHz connection. QA does not start without it.
      2. Hardware inventory.
      3. Automatic checks (storage, battery, WiFi, Bluetooth, camera/audio/mic,
         Windows licence / DPK).
      4. Windows Update - CHECK ONLY unless you pass -InstallUpdates.
      5. DISM /CheckHealth, and SFC /verifyonly if you ask for it.
      6. Interactive checks (camera picture, sound, mic, keyboard, etc).
      7. Power settings restored to the values Start-Repair saved.
      8. Shop WiFi profile handling (kept by default - see Repair-Config.ps1).
      9. Report written to <toolkit folder>\Reports\ on the USB stick.

    Power settings are restored LAST on purpose: restoring them first would let
    the machine sleep halfway through Windows Update.
.PARAMETER SkipWindowsUpdate
    Skip the Windows Update check entirely.
.PARAMETER InstallUpdates
    Actually download and install the updates found. Without this, Finish-Repair
    only lists what is available and changes nothing.
.PARAMETER SkipDism
    Skip DISM /CheckHealth (it runs by default - it only takes seconds).
.PARAMETER RunSfc
    Run SFC /verifyonly. OFF by default because it costs several minutes.
.PARAMETER SkipInteractiveTests
    Automatic checks only; opens no apps, asks no questions.
#>
param(
    [switch]$SkipWindowsUpdate,
    [switch]$InstallUpdates,
    [switch]$SkipDism,
    [switch]$RunSfc,
    [switch]$SkipInteractiveTests
)

# ---- relaunch elevated if needed --------------------------------------------
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($SkipWindowsUpdate)    { $argList += ' -SkipWindowsUpdate' }
    if ($InstallUpdates)       { $argList += ' -InstallUpdates' }
    if ($SkipDism)             { $argList += ' -SkipDism' }
    if ($RunSfc)               { $argList += ' -RunSfc' }
    if ($SkipInteractiveTests) { $argList += ' -SkipInteractiveTests' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Repair-Common.ps1')
. (Join-Path $PSScriptRoot 'Repair-Config.ps1')

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
    $Root      = Get-ToolkitRoot $PSScriptRoot
    $StateFile = Get-StateFile $Root

    # =========================================================================
    # 1. NETWORK GATE - no connection, no QA
    # =========================================================================
    Write-Host '=== Network gate ===' -ForegroundColor Cyan
    $wifi = $null
    $attempt = 0
    while ($true) {
        $attempt++
        if ($attempt -gt 1) { Write-Host "  Retry $($attempt - 1) of $NetworkRetryCount..." -ForegroundColor DarkGray }
        $wifi = Connect-ShopWifi -Ssid5 $ShopSsid5GHz -Ssid24 $ShopSsid24GHz `
                                 -Password $ShopWifiPassword -Auth $ShopWifiAuth -Encryption $ShopWifiEncryption

        if ($wifi.Connected -and $wifi.Internet -eq 'Internet') {
            Write-Host "  $($wifi.Message) [$($wifi.Band)]" -ForegroundColor Green
            break
        }

        Write-Host "  $($wifi.Message)" -ForegroundColor Red
        if ($attempt -le $NetworkRetryCount) { Start-Sleep -Seconds 5; continue }

        # Out of automatic retries - hand it to the tech.
        Write-Host ''
        Write-Host '  QA CANNOT START WITHOUT A WORKING WIFI CONNECTION.' -ForegroundColor Red
        Write-Host '  Check: card seated, antenna leads attached, radio not disabled by the' -ForegroundColor Yellow
        Write-Host '  Fn key or airplane mode, driver installed, and the AP is actually up.' -ForegroundColor Yellow
        Write-Host '  Ethernet does not count - proving the WiFi card works IS part of QA.' -ForegroundColor DarkGray
        Write-Host ''
        $choice = ''
        while ($choice -notin @('r', 'q')) { $choice = (Read-Host '  [R]etry or [Q]uit').Trim().ToLower() }
        if ($choice -eq 'q') {
            Write-Host '  Aborted. Power settings left in repair mode - re-run this script when the WiFi works.' -ForegroundColor Yellow
            Wait-Close 1
        }
        $attempt = 0
    }

    # =========================================================================
    # 2. REPORT FOLDER + HARDWARE INVENTORY  (all on the USB stick)
    # =========================================================================
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportDir = Join-Path $Root ('Reports\{0}_{1}' -f (Get-MachineKey), $stamp)
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

    Add-Result 'WiFi' 'PASS' ("SSID '{0}' [{1}], internet OK" -f $wifi.Ssid, $wifi.Band)

    try {
        $disks = @(Get-PhysicalDisk)
        $bad   = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        if ($bad.Count) {
            Add-Result 'Storage health' 'FAIL' (($bad | ForEach-Object { "$($_.FriendlyName): $($_.HealthStatus)" }) -join '; ')
        } else {
            Add-Result 'Storage health' 'PASS' (($disks | ForEach-Object { '{0} [{1} GB]' -f $_.FriendlyName, [math]::Round($_.Size / 1GB) }) -join '; ')
        }
    } catch { Add-Result 'Storage health' 'INFO' 'Could not query - use the drive maker''s diagnostic tool' }

    $batt = Get-BatteryHealth -ReportDir $reportDir `
                              -WarnPercent $BatteryWearWarnPercent -FailPercent $BatteryWearFailPercent
    if ($batt.Present -and $batt.Charge -ne $null) {
        Add-Result 'Battery charge' 'INFO' "$($batt.Charge)%, $($batt.PowerSource)"
    }
    Add-Result 'Battery wear' $batt.Status $batt.Detail
    if ($batt.Status -eq 'FAIL') {
        Write-Host '         Battery is worn past the fail threshold - quote a replacement.' -ForegroundColor Yellow
    }
    foreach ($b in $batt.Batteries) {
        if ($b.WearPct -ne $null -and $batt.Batteries.Count -gt 1) {
            Write-Host ('         {0}: {1}% wear, {2:N0}/{3:N0} mWh' -f $b.Name, $b.WearPct, $b.FullmWh, $b.DesignmWh) -ForegroundColor DarkGray
        }
    }

    $bt = @(Get-PnpDevice -Class Bluetooth -Status OK -ErrorAction SilentlyContinue)
    if ($bt.Count) { Add-Result 'Bluetooth' 'PASS' $bt[0].FriendlyName }
    else           { Add-Result 'Bluetooth' 'INFO' 'No Bluetooth device detected' }

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

    # Windows licence / Digital Product Key
    $lic = Get-WindowsLicenceInfo -FullKey $RecordFullProductKey
    Add-Result 'Windows activation' $lic.Status $lic.Detail
    if ($lic.FirmwareKey) {
        if ($lic.Matches -eq $false) {
            Add-Result 'Firmware DPK' 'FAIL' ("{0} - does NOT match the installed key (...{1}). Board swapped, or running on a different licence." -f $lic.FirmwareKey, $lic.InstalledPartial)
        } else {
            Add-Result 'Firmware DPK' 'PASS' ("{0} - matches installed key" -f $lic.FirmwareKey)
        }
    } else {
        Add-Result 'Firmware DPK' 'INFO' 'No OEM key in firmware (retail/upgrade install, or replaced board)'
    }

    # =========================================================================
    # 4. WINDOWS UPDATE
    # =========================================================================
    Write-Host ''
    Write-Host '=== Windows Update ===' -ForegroundColor Cyan
    $rebootNeeded = $false
    $doInstall = $InstallUpdates.IsPresent -or $InstallUpdatesByDefault
    if ($SkipWindowsUpdate) {
        Add-Result 'Windows Update' 'SKIP' '-SkipWindowsUpdate'
    } else {
        if (-not $doInstall) { Write-Host '  Check only - nothing will be installed.' -ForegroundColor DarkGray }
        $wu = Invoke-WindowsUpdate -IncludeDrivers $UpdateIncludeDrivers -TimeoutMinutes $UpdateTimeoutMinutes -Install $doInstall
        $rebootNeeded = $wu.RebootRequired
        Add-Result 'Windows Update' $wu.Status $wu.Detail
        if ($wu.Titles.Count) {
            $wu.Titles | Set-Content -Path (Join-Path $reportDir 'windows-updates.txt') -Encoding UTF8
        }
    }

    # =========================================================================
    # 5. SYSTEM FILE CHECKS
    # =========================================================================
    Write-Host ''
    Write-Host '=== System file checks ===' -ForegroundColor Cyan
    if ($SkipDism) {
        Add-Result 'DISM CheckHealth' 'SKIP' '-SkipDism'
    } else {
        $dismLog = Join-Path $reportDir 'dism-checkhealth.txt'
        cmd.exe /c "dism /Online /Cleanup-Image /CheckHealth > `"$dismLog`" 2>&1" | Out-Null
        $dismText = (Get-Content $dismLog -Raw -ErrorAction SilentlyContinue) -replace "`0", ''
        if     ($dismText -match 'No component store corruption detected') { Add-Result 'DISM CheckHealth' 'PASS' }
        elseif ($dismText -match 'repairable|corrupt')                     { Add-Result 'DISM CheckHealth' 'FAIL' 'Corruption flagged - see dism-checkhealth.txt' }
        else                                                               { Add-Result 'DISM CheckHealth' 'INFO' 'See dism-checkhealth.txt' }
    }

    if (-not $RunSfc) {
        Add-Result 'SFC verify' 'SKIP' 'not requested - add -RunSfc'
    } else {
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
    # 6. INTERACTIVE CHECKS
    # =========================================================================
    Write-Host ''
    Write-Host '=== Interactive checks ===' -ForegroundColor Cyan
    if ($SkipInteractiveTests) {
        foreach ($t in 'Webcam picture', 'Speakers', 'Microphone', 'Keyboard', 'Touchpad', 'Display', 'USB ports') {
            Add-Result $t 'SKIP' '-SkipInteractiveTests'
        }
    } else {
        if ($cams.Count) {
            Write-Host '  Opening the Camera app...' -ForegroundColor DarkGray
            Start-Process 'microsoft.windows.camera:'
            Start-Sleep -Seconds 2
            if (Ask 'Webcam: live picture visible?') { Add-Result 'Webcam picture' 'PASS' } else { Add-Result 'Webcam picture' 'FAIL' }
        } else {
            Add-Result 'Webcam picture' 'FAIL' 'No camera device to test'
        }

        Write-Host '  Playing a test sound 3 times (check volume is up / not muted)...' -ForegroundColor DarkGray
        try {
            $player = New-Object System.Media.SoundPlayer "$env:windir\Media\tada.wav"
            1..3 | ForEach-Object { $player.PlaySync(); Start-Sleep -Milliseconds 300 }
            if (Ask 'Speakers: heard it clearly?') { Add-Result 'Speakers' 'PASS' } else { Add-Result 'Speakers' 'FAIL' }
        } catch {
            Add-Result 'Speakers' 'FAIL' "Could not play test sound: $_"
        }

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
    # 7. RESTORE POWER SETTINGS  (last, so nothing slept through the update)
    # =========================================================================
    Write-Host ''
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
            Add-Result 'Power restore' 'FAIL' "$_"
            Write-Host "  State file kept so you can retry: $StateFile" -ForegroundColor Yellow
        }
        if ($restored) {
            Remove-Item $StateFile -Force
            Add-Result 'Power restore' 'PASS' "Plan '$($state.SchemeName)' back to pre-repair values"
        }
    } else {
        Add-Result 'Power restore' 'INFO' 'No saved state for this machine (Start-Repair not run from this stick)'
    }

    # =========================================================================
    # 8. SHOP WIFI PROFILE
    # =========================================================================
    if ($RemoveWifiProfileOnFinish) {
        Remove-ShopWifiProfile -Ssids @($ShopSsid5GHz, $ShopSsid24GHz)
        Add-Result 'Shop WiFi profile' 'INFO' 'Removed from customer machine'
        if ($rebootNeeded) {
            Write-Host '  NOTE: updates need a reboot and the shop WiFi is now gone.' -ForegroundColor Yellow
            Write-Host '        Re-run Start-Repair if you need the machine back online.' -ForegroundColor Yellow
        }
    } else {
        Add-Result 'Shop WiFi profile' 'INFO' 'Kept - machine reconnects by itself after reboot / on rework'
    }

    # =========================================================================
    # 9. SUMMARY + REPORT
    # =========================================================================
    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor Cyan
    $fails = @($Results | Where-Object { $_.Status -eq 'FAIL' })
    $warns = @($Results | Where-Object { $_.Status -eq 'WARN' })
    if ($fails.Count) {
        Write-Host "  $($fails.Count) check(s) FAILED: $(($fails.Check) -join ', ')" -ForegroundColor Red
    } elseif (-not $warns.Count) {
        Write-Host '  All checks passed.' -ForegroundColor Green
    }
    if ($warns.Count) {
        Write-Host "  $($warns.Count) warning(s): $(($warns.Check) -join ', ')" -ForegroundColor Yellow
    }
    if ($rebootNeeded) { Write-Host '  REBOOT REQUIRED to finish Windows Update.' -ForegroundColor Yellow }

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
    if ($rebootNeeded) { $lines += ''; $lines += 'REBOOT REQUIRED to finish Windows Update.' }
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
rem Double-click me to run QA and end repair mode.
rem By default Windows Update is CHECK ONLY - nothing is installed.
rem Switches pass straight through, e.g.:
rem   Finish-Repair.cmd -InstallUpdates         (actually install the updates)
rem   Finish-Repair.cmd -RunSfc                 (SFC is opt-in, adds minutes)
rem   Finish-Repair.cmd -SkipWindowsUpdate
rem   Finish-Repair.cmd -SkipDism -SkipInteractiveTests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Finish-Repair.ps1" %*
'@

$files['README.txt'] = @'
Laptop Repair Toolkit
=====================

Everything lives on the USB stick you run the scripts from. Nothing is written
to C:\ except the power settings themselves.

Files
-----
Repair-Config.ps1    The only file you edit. Shop WiFi SSIDs + password,
                     Windows Update options, retry counts.
Repair-Common.ps1    Shared functions. Leave alone.
Start-Repair.cmd     Run at intake.
Finish-Repair.cmd    Run at completion.
*.ps1                The scripts the .cmd launchers call.

First-time setup
----------------
1. Extract to a technician USB drive.
2. Open Repair-Config.ps1 in Notepad and put in your two SSIDs and the
   password. 5 GHz SSID goes in $ShopSsid5GHz, 2.4 GHz in $ShopSsid24GHz.
3. Save. Done - that file is not overwritten if you re-run the installer.

Daily use
---------
At intake:      double-click  Start-Repair.cmd
At completion:  double-click  Finish-Repair.cmd

The .cmd launchers start PowerShell with -ExecutionPolicy Bypass for that one
process only, so there is no Set-ExecutionPolicy step and no policy change is
left on the customer's machine. The scripts request elevation themselves - just
approve the UAC prompt.

What Start-Repair does
----------------------
- Saves the active power plan's display / sleep / hibernate timeouts (AC and
  battery) and the lid-close action, then sets them all to Never / Do nothing.
- Connects to the shop WiFi: tries the 5 GHz SSID first, falls back to 2.4 GHz.
- WiFi failure here is a WARNING only. A dead WiFi card may be the fault you
  are about to fix, so it does not stop the job.

What Finish-Repair does, in order
---------------------------------
1. Network gate. Connects (5 GHz then 2.4 GHz) and verifies real internet
   access, not just association. Retries $NetworkRetryCount times on its own,
   then stops and offers Retry / Quit. QA does not start without WiFi.
2. Hardware inventory.
3. Automatic checks: storage health, battery charge + wear %, WiFi, Bluetooth,
   camera / audio / mic device presence, Windows licence / DPK.
4. Windows Update: CHECK ONLY - lists what is available and installs nothing
   unless you pass -InstallUpdates.
5. DISM /CheckHealth. SFC /verifyonly only if you pass -RunSfc.
6. Interactive checks: camera picture, test sound, mic level meter, keyboard,
   touchpad, display, USB ports.
7. Restores the power settings saved by Start-Repair.
8. Shop WiFi profile handling - kept on the machine by default.
9. Writes the report.

Power settings are restored LAST on purpose. Restoring them first would let the
machine sleep partway through Windows Update.

Ethernet does not satisfy the network gate. Proving the WiFi card works is part
of QA, so the gate requires actual WiFi association plus internet.

Optional finish modes
---------------------
   Finish-Repair.cmd -InstallUpdates      actually download + install the
                                          updates (default is check only)
   Finish-Repair.cmd -RunSfc              turn SFC /verifyonly ON (opt-in;
                                          it adds several minutes)
   Finish-Repair.cmd -SkipWindowsUpdate   skip the update check entirely
   Finish-Repair.cmd -SkipDism
   Finish-Repair.cmd -SkipInteractiveTests

They combine, e.g.:

   Finish-Repair.cmd -SkipWindowsUpdate -SkipInteractiveTests

Battery wear check
------------------
Reports current charge, then wear: how much of the battery's original design
capacity is gone. Figures come from the Windows battery report (design vs
full-charge capacity in mWh) plus cycle count, because Win32_Battery reports a
null design capacity on most laptops.

   under 20% wear   PASS
   20-40%           WARN - tired, worth mentioning on the job sheet
   40% and over     FAIL - quote a replacement

Thresholds are $BatteryWearWarnPercent / $BatteryWearFailPercent in
Repair-Config.ps1. Machines with two batteries are all measured and the worst
one sets the result. Some batteries report no design capacity at all, in which
case wear cannot be calculated and the check reports INFO.

battery-report.html and battery-report.xml are both saved in the report folder.

Licence / DPK check
-------------------
Reports the Windows edition and channel, the activation state, and the OEM
Digital Product Key held in firmware (the ACPI MSDM table).

It also compares the last 5 characters of the firmware key against the key
Windows is actually running on. A mismatch is flagged FAIL - that is what a
board swap looks like, or a machine running on someone else's licence.

Keys are masked to the last 5 characters in the report. A tech USB slowly
collecting customers' full product keys is a liability if the stick goes
missing. Set $RecordFullProductKey = $true in Repair-Config.ps1 if you need
the full key for a rebuild.

Where things are stored (all on the USB)
----------------------------------------
State:    <toolkit folder>\State\<COMPUTERNAME>_<SERIAL>.json
Reports:  <toolkit folder>\Reports\<COMPUTERNAME>_<SERIAL>_<TIMESTAMP>\
          Report.txt, battery-report.html, windows-updates.txt, DISM/SFC logs

State is keyed per machine, so you can have several laptops in repair mode at
once from the same stick. The state file is deleted only after the power
settings restore successfully.

WiFi profile and password
-------------------------
- The shop WiFi profile is KEPT on the customer's machine when the job ends.
  The profile is set to auto-connect, so the laptop comes back online by itself
  after an update reboot or if it returns for rework. Set
  $RemoveWifiProfileOnFinish = $true in Repair-Config.ps1 to delete it instead.
- The password sits in plain text in Repair-Config.ps1. Anyone holding the
  stick has your shop WiFi.
- A kept profile also stores the password on the customer's laptop, where any
  user of that machine can read it back with:
      netsh wlan show profile name="YOUR-SSID" key=clear
  A bench/guest VLAN separate from the office network handles both of those.

Important limitations
---------------------
- Device detection proves Windows sees a device; it does not prove the camera
  image, mic quality, speaker sound, ports or controls actually work. Hence the
  interactive confirmations.
- Get-PhysicalDisk health is not a substitute for the drive manufacturer's
  diagnostic utility or a full SMART analysis.
- SFC /verifyonly checks protected Windows files but does not repair them, and
  is off unless you pass -RunSfc.
- DISM /CheckHealth is a quick corruption-state check, not a full repair.
- Windows Update only CHECKS by default. Nothing is downloaded, no EULA is
  accepted, nothing is changed - you get a list of what is outstanding. Pass
  -InstallUpdates to actually install, or set $InstallUpdatesByDefault = $true.
- Driver updates are excluded even when installing ($UpdateIncludeDrivers),
  because WU drivers are a common cause of "it worked when it left the bench"
  callbacks.
- If updates need a reboot, the machine reconnects to the shop WiFi on its own
  afterwards, because the profile is kept and set to auto-connect.
- Battery wear is a capacity measurement, not a safety check. A swollen or
  overheating pack can still report low wear - your eyes and hands decide that
  one, not the script.
- Run the start and finish scripts from the SAME USB stick. A network share
  will not work: elevated processes do not see mapped drives.
- Start-Repair parses English powercfg output; on a non-English Windows UI it
  stops with an error before changing anything.
'@

$files['.gitignore'] = @'
# Your shop WiFi password lives in Repair-Config.ps1 - never commit it.
Repair-Config.ps1

# Per-machine repair state and QA reports (contain customer serials).
State/
Reports/
'@

foreach ($name in $files.Keys) {
    $path = Join-Path $dest $name
    if (($protected -contains $name) -and (Test-Path $path)) {
        Write-Host ('  kept  {0} (already exists - your settings are safe)' -f $name) -ForegroundColor Yellow
        continue
    }
    # Here-strings drop the final newline; add it back. Force CRLF and plain
    # ASCII: no BOM, because cmd.exe chokes on one.
    $text = ($files[$name] -replace "`r?`n", "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::ASCII)
    Write-Host ('  wrote {0} ({1:N0} bytes)' -f $name, $text.Length) -ForegroundColor Green
}

Write-Host ''
Write-Host "Laptop Repair Toolkit installed to:`n  $dest" -ForegroundColor Cyan
if (Select-String -Path (Join-Path $dest 'Repair-Config.ps1') -Pattern 'CHANGE-ME' -Quiet) {
    Write-Host ''
    Write-Host 'NEXT STEP: open Repair-Config.ps1 and set your shop WiFi SSIDs + password.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Start a job:  double-click Start-Repair.cmd'
Write-Host 'End a job:    double-click Finish-Repair.cmd'
Write-Host '              add -InstallUpdates to install updates (default: check only)'
Write-Host '              add -RunSfc to run SFC /verifyonly'
Write-Host ''
Read-Host 'Press Enter to close' | Out-Null
