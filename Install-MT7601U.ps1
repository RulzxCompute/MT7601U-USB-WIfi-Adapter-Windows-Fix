# MT7601U USB Wi-Fi adapter installer + USB serial-descriptor fix
# Intended to be launched by Install.cmd, which requests Administrator rights.

$ErrorActionPreference = 'Stop'
$script:failed = $false
$log = Join-Path $env:TEMP 'MT7601U_Install.log'
$transcriptStarted = $false

try {
    Start-Transcript -Path $log -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Host "Warning: could not start transcript: $($_.Exception.Message)" -ForegroundColor Yellow
}

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  $Text" -ForegroundColor Yellow
}

function Get-AdapterDevices {
    @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_148F&PID_7601*' })
}

function Get-UsbFlagKeys {
    param([object[]]$Devices)

    $keys = New-Object System.Collections.Generic.List[string]
    $keys.Add('148F76010000')   # VID 148F, PID 7601, REV 0000

    foreach ($d in $Devices) {
        $ids = @($d.InstanceId)
        try {
            $prop = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
            if ($prop -and $prop.Data) { $ids += @($prop.Data) }
        } catch { }

        foreach ($hwid in $ids) {
            if ($hwid -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})&REV_([0-9A-Fa-f]{4})') {
                $key = ($matches[1] + $matches[2] + $matches[3]).ToUpperInvariant()
                if (-not $keys.Contains($key)) { $keys.Add($key) }
            }
        }
    }

    return $keys.ToArray()
}

function Set-UsbSerialOverride {
    param([string[]]$Keys)

    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\usbflags'
    foreach ($key in $Keys) {
        $path = Join-Path $base $key
        if (-not (Test-Path $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        New-ItemProperty -Path $path -Name 'IgnoreHWSerNum' -PropertyType Binary -Value ([byte[]](1)) -Force | Out-Null
        Write-Ok "IgnoreHWSerNum=1 -> $key"
    }
}

function Show-DeviceState {
    param([object[]]$Devices)

    foreach ($d in $Devices) {
        $fresh = Get-PnpDevice -InstanceId $d.InstanceId -ErrorAction SilentlyContinue
        if (-not $fresh) { continue }
        Write-Host "  $($fresh.InstanceId)"
        Write-Host "    Status : $($fresh.Status)"
        Write-Host "    Problem: $($fresh.Problem) $($fresh.ProblemDescription)"
    }
}

function Get-AdapterNics {
    param([object[]]$Devices)

    $ids = @($Devices | ForEach-Object { $_.InstanceId })
    if ($ids.Count -eq 0) { return @() }
    @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $ids -contains $_.PnPDeviceID })
}

function Test-WlanInterfacePresent {
    param([object[]]$Devices)

    if (-not $Devices -or $Devices.Count -eq 0) { return $false }
    $nics = @(Get-AdapterNics -Devices $Devices)
    if ($nics.Count -eq 0) { return $false }

    $wlan = ''
    try {
        $wlan = (& netsh.exe wlan show interfaces 2>&1 | Out-String)
    } catch { }

    if (-not $wlan) { return $false }
    $wlanLower = $wlan.ToLowerInvariant()

    foreach ($n in $nics) {
        $mac = ($n.MacAddress -replace '-', ':').ToLowerInvariant()
        if ($mac -and $wlanLower.Contains($mac)) { return $true }
    }

    if ($wlan -match '802\.11n USB Wireless LAN Card') { return $true }
    return $false
}

function Wait-ForAdapter {
    param([int]$TimeoutSeconds = 60)

    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $devices = Get-AdapterDevices
        if ($devices.Count -gt 0) { return $devices }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $end)
    return @()
}

function Get-PublishedDriverName {
    param([string]$InfPath)

    $infName = if ($InfPath) { Split-Path -Leaf $InfPath } else { 'netr28ux.inf' }
    $output = @(& pnputil.exe /enum-drivers 2>&1)
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = @{}

    foreach ($line in $output) {
        if ($line -match '^Published Name:\s+(.+?)\s*$') {
            if ($current.ContainsKey('Published')) {
                $blocks.Add([pscustomobject]$current)
            }
            $current = @{ Published = $matches[1].Trim() }
        } elseif ($line -match '^Original Name:\s+(.+?)\s*$') {
            $current['Original'] = $matches[1].Trim()
        } elseif ($line -match '^Driver Version:\s+(.+?)\s*$') {
            $current['Version'] = $matches[1].Trim()
        }
    }
    if ($current.ContainsKey('Published')) {
        $blocks.Add([pscustomobject]$current)
    }

    $match = $blocks | Where-Object {
        $_.Original -eq $infName -and $_.Version -match '5\.1\.38'
    } | Select-Object -First 1

    if ($match) { return $match.Published }
    return $null
}

function Start-AdapterDevices {
    param([object[]]$Devices)

    foreach ($d in $Devices) {
        $id = $d.InstanceId
        $fresh = Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue
        if (-not $fresh -or $fresh.Status -eq 'OK') { continue }

        Write-Host ""
        Write-Host "  Restarting $id ..."
        & pnputil.exe /restart-device "$id" 2>&1 | ForEach-Object { Write-Host "    $_" }
        Start-Sleep -Seconds 10

        $fresh = Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue
        if (-not $fresh -or $fresh.Status -ne 'OK') {
            Write-Warn 'Still not started; trying disable/enable...'
            Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 10
            $fresh = Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue
        }

        if (-not $fresh -or $fresh.Status -ne 'OK') {
            Write-Warn 'Still not started; re-enumerating the USB device...'
            & pnputil.exe /remove-device "$id" 2>&1 | ForEach-Object { Write-Host "    $_" }
            Start-Sleep -Seconds 3
            & pnputil.exe /scan-devices 2>&1 | ForEach-Object { Write-Host "    $_" }
            Start-Sleep -Seconds 12
        }
    }
}

function Repair-DriverInstall {
    param(
        [string]$Inf,
        [object[]]$Devices,
        [string]$PublishedName
    )

    Write-Step 'Repairing the driver installation'

    foreach ($d in $Devices) {
        Write-Host "  Removing device $($d.InstanceId) ..."
        & pnputil.exe /remove-device "$($d.InstanceId)" 2>&1 | ForEach-Object { Write-Host "    $_" }
    }
    Start-Sleep -Seconds 3

    if (-not $PublishedName) {
        $PublishedName = Get-PublishedDriverName -InfPath $Inf
    }

    if ($PublishedName) {
        Write-Host "  Deleting driver package $PublishedName ..."
        & pnputil.exe /delete-driver "$PublishedName" /uninstall 2>&1 | ForEach-Object { Write-Host "    $_" }
        Start-Sleep -Seconds 5
    } else {
        Write-Warn 'Could not determine the published driver package name; skipping package deletion.'
    }

    Write-Host '  Re-adding and installing the driver package...'
    & pnputil.exe /add-driver "$Inf" /install 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Seconds 5
    & pnputil.exe /scan-devices 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Seconds 15
}

try {
    Write-Step 'Checking requirements'

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run as Administrator. Right-click Install.cmd and choose "Run as administrator".'
    }

    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'This driver package is for 64-bit x64 Windows (AMD64) only.'
    }

    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $driverDir = Join-Path $root 'driver'
    $inf = Join-Path $driverDir 'netr28ux.inf'
    $fwSource = Join-Path $root 'firmware\FW_7601.bin'
    $fwDest = Join-Path $env:WINDIR 'System32\drivers\FW_7601.bin'

    foreach ($file in @($inf, (Join-Path $driverDir 'netr28ux.sys'), (Join-Path $driverDir 'netr28ux.cat'), $fwSource)) {
        if (-not (Test-Path $file)) {
            throw "Required file is missing: $file"
        }
    }
    Write-Ok "Package files found in $root"

    Write-Step 'Fixing the USB serial-number descriptor'
    $devices = Get-AdapterDevices
    $keys = Get-UsbFlagKeys $devices
    Set-UsbSerialOverride -Keys $keys

    Write-Step 'Installing MT7601 firmware'
    Copy-Item -Path $fwSource -Destination $fwDest -Force
    $srcHash = (Get-FileHash -Path $fwSource -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash -Path $fwDest -Algorithm SHA256).Hash
    if ($srcHash -ne $dstHash) {
        throw "Firmware copy verification failed: $fwDest"
    }
    Write-Ok "FW_7601.bin -> $fwDest"

    Write-Step 'Installing MediaTek 5.1.38.0 driver'
    $pnputilOut = & pnputil.exe /add-driver "$inf" /install 2>&1
    $pnputilCode = $LASTEXITCODE
    $pnputilOut | ForEach-Object { Write-Host "  $_" }
    if ($pnputilCode -ne 0) {
        Write-Warn "pnputil returned exit code $pnputilCode. If the driver is already installed, this is normal."
    }

    $publishedName = $null
    foreach ($line in $pnputilOut) {
        if ($line -match 'Published Name:\s+(\S+)') {
            $publishedName = $matches[1].Trim()
        }
    }
    if (-not $publishedName) {
        $publishedName = Get-PublishedDriverName -InfPath $inf
    }
    if ($publishedName) {
        Write-Ok "Driver package published as $publishedName"
    }

    & pnputil.exe /scan-devices 2>&1 | ForEach-Object { Write-Host "  $_" }
    Start-Sleep -Seconds 3

    Write-Step 'Waiting for the adapter'
    $devices = Get-AdapterDevices
    if ($devices.Count -eq 0) {
        Write-Warn 'The adapter is not plugged in yet.'
        Write-Host '  Plug it into a rear USB 2.0 port (black, not blue). Waiting up to 60 seconds...'
        for ($i = 1; $i -le 30; $i++) {
            Start-Sleep -Seconds 2
            $devices = Get-AdapterDevices
            if ($devices.Count -gt 0) { break }
            if ($i % 5 -eq 0) { Write-Host "  Still waiting... ($($i * 2)s)" }
        }
    }

    if ($devices.Count -gt 0) {
        Start-Sleep -Seconds 5
        $devices = Get-AdapterDevices
        $keys = Get-UsbFlagKeys $devices
        Set-UsbSerialOverride -Keys $keys
    }

    Write-Step 'Starting the adapter'
    if ($devices.Count -eq 0) {
        Write-Warn 'No adapter was detected.'
        Write-Host '  The driver is installed and ready. Plug the adapter into a rear USB 2.0 port;'
        Write-Host '  Windows should start it automatically. If it does not, run Install.cmd again.'
    } else {
        Show-DeviceState -Devices $devices
        Start-AdapterDevices -Devices $devices
    }

    Write-Step 'Verifying the wireless interface'
    $devices = Get-AdapterDevices
    $ready = $false
    for ($i = 0; $i -lt 8; $i++) {
        $ready = Test-WlanInterfacePresent -Devices $devices
        if ($ready) { break }
        Start-Sleep -Seconds 2
    }

    if ($devices.Count -gt 0 -and -not $ready) {
        Write-Warn 'The adapter is detected, but Windows has not registered the wireless interface yet.'
        Write-Host '  Running a clean driver reinstall...'
        Repair-DriverInstall -Inf $inf -Devices $devices -PublishedName $publishedName

        $devices = Wait-ForAdapter -TimeoutSeconds 60
        if ($devices.Count -gt 0) {
            $keys = Get-UsbFlagKeys $devices
            Set-UsbSerialOverride -Keys $keys
            Start-AdapterDevices -Devices $devices
        }

        $devices = Get-AdapterDevices
        for ($i = 0; $i -lt 8; $i++) {
            $ready = Test-WlanInterfacePresent -Devices $devices
            if ($ready) { break }
            Start-Sleep -Seconds 2
        }
    }

    if ($devices.Count -eq 0) {
        Write-Warn 'The adapter is not connected.'
    } elseif ($ready) {
        Write-Ok 'The wireless interface is registered.'
    } else {
        Write-Warn 'The wireless interface is still not registered.'
    }

    Write-Step 'Result'
    $devices = Get-AdapterDevices
    $okDevices = @($devices | Where-Object { $_.Status -eq 'OK' })

    if ($okDevices.Count -gt 0 -and $ready) {
        foreach ($d in $okDevices) {
            $ver = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue
            Write-Ok "Device OK: $($d.FriendlyName)"
            Write-Host "    Instance : $($d.InstanceId)"
            if ($ver) {
                Write-Host "    Driver   : $($ver.Data)"
                if ($ver.Data -notmatch '^5\.1\.38') {
                    Write-Warn "Expected driver 5.1.38.0. If needed, update the driver manually from the driver folder."
                }
            }
        }

        $nics = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object { $_.PnPDeviceID -like 'USB\VID_148F&PID_7601*' })
        if ($nics.Count -eq 0) {
            Start-Sleep -Seconds 3
            $nics = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceDescription -like '*802.11n*' })
        }
        foreach ($n in $nics) {
            Write-Host "    Adapter  : $($n.Name) [$($n.Status)]"
            Write-Host "    MAC      : $($n.MacAddress)"
        }

        Write-Host ""
        Write-Host 'SUCCESS: the adapter is working.' -ForegroundColor Green
        Write-Host 'Open the Wi-Fi icon in the taskbar and connect to your network.'
        Write-Host 'This MT7601U adapter supports 2.4 GHz networks only.'
    } elseif ($okDevices.Count -gt 0) {
        Write-Warn 'The adapter is working, but Windows has not registered its wireless interface.'
        Write-Host '  Restart Windows, then run Install.cmd again if the Wi-Fi icon does not appear.'
        $script:failed = $true
    } elseif ($devices.Count -gt 0) {
        Write-Warn 'The adapter is detected but still not starting.'
        Write-Host '  Try a different rear USB 2.0 port, then run Install.cmd again.'
        Write-Host '  Device Manager will show the exact error code.'
        $script:failed = $true
    } else {
        Write-Warn 'The adapter is not connected.'
        Write-Host '  The driver and registry fix are installed. Plug the adapter into a rear USB 2.0 port;'
        Write-Host '  Windows should install and start it automatically. Run Install.cmd again if needed.'
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $script:failed = $true
} finally {
    Write-Host ""
    Write-Host "Log file: $log"
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

if ($script:failed) { exit 1 }
