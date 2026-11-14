MT7601U USB Wi-Fi adapter - Windows 10/11 (64-bit) installer
=============================================================

This package installs:
  * MediaTek/Ralink netr28ux driver 5.1.38.0 (WHQL-signed, from Microsoft Update Catalog)
  * FW_7601.bin firmware required by the MT7601U chip
  * The USB descriptor fix for the adapter's broken serial-number string:
      HKLM\SYSTEM\CurrentControlSet\Control\usbflags\148F76010000
      IgnoreHWSerNum = 01 (REG_BINARY)

Why the registry fix is needed
------------------------------
Windows fails to validate this adapter's USB serial-number string descriptor,
retries enumeration, and leaves the device at Code 10. The Wi-Fi driver cannot
start until enumeration succeeds. IgnoreHWSerNum makes Windows skip that broken
string descriptor. The driver alone cannot fix it.

Requirements
------------
  * 64-bit x64 Windows 10 or Windows 11 (AMD64)
  * Administrator rights

How to install
--------------
  1. Extract this ZIP to a folder on the new PC. Do not run it from inside the ZIP.
     If Windows marked the ZIP as downloaded, right-click the ZIP -> Properties ->
     check "Unblock" -> OK before extracting.
  2. If the adapter is already plugged in, unplug it.
  3. Double-click Install.cmd and approve the UAC prompt.
     (Or right-click Install.cmd -> Run as administrator.)
  4. When the script asks, plug the adapter into a rear USB 2.0 port
     (black, not blue). The script waits up to 60 seconds for it.
  5. Wait for "SUCCESS". Then click the Wi-Fi icon in the taskbar and connect to
     your network. This adapter is 2.4 GHz only.

If it does not work
-------------------
  * Run Install.cmd again with the adapter plugged in. It will set the registry
    key, reinstall the driver, and restart the device.
  * Try a different rear USB 2.0 port. Avoid USB 3.0 ports and unpowered hubs.
  * Check Device Manager -> Network adapters -> "802.11n USB Wireless LAN Card".
    The expected driver version is 5.1.38.0.
  * If the installer window looks frozen, click inside it and press Enter.
    Selecting text in a console window pauses its output (QuickEdit).
  * The install log is %TEMP%\MT7601U_Install.log.

Manual registry fix (registry part only)
----------------------------------------
Open an elevated PowerShell and run:

  $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\usbflags\148F76010000'
  New-Item -Path $k -Force | Out-Null
  New-ItemProperty -Path $k -Name IgnoreHWSerNum -PropertyType Binary `
      -Value ([byte[]](1)) -Force

Then unplug/replug the adapter, or restart the device in Device Manager.

Files
-----
  driver\              MediaTek 5.1.38.0 driver package
                       (INF, SYS, CAT, co-installer, firmware for other chips)
  firmware\            FW_7601.bin - required by the MT7601U
  Install.cmd          launcher; requests Administrator rights
  Install-MT7601U.ps1  main installer / registry fix
