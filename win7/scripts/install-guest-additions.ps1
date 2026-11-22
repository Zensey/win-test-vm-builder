# Installs VirtualBox Guest Additions, split out of provision.ps1 and run
# AFTER the windows-restart provisioner (win7-testvm.pkr.hcl), not before
# it, so TESTSIGNING (which provision.ps1 only enables via bcdedit -- a
# reboot is needed for it to take effect) is active in case it's ever
# needed again. It turned out NOT to be the actual fix for the real
# problem here, but there's no reason to move it back before the reboot.
#
# The real problem, found by installing by hand over WinRM and reading
# install_drivers.log: VBoxWindowsAdditions.exe exited 1 with
# "ERROR_AUTHENTICODE_TRUST_NOT_ESTABLISHED (0xe0000242)" -- not a SHA-2
# digest issue, a plain untrusted-publisher one. A fresh Windows 7 install
# simply doesn't have Oracle's current code-signing certificate in its
# trusted-publisher store, and nothing in a normal unattended install ever
# adds it. `nointegritychecks ON` does NOT fix this (confirmed) -- that
# flag relaxes NT kernel code-integrity enforcement, a different subsystem
# from SetupAPI's WinVerifyTrust-based driver package validation.
#
# The fix: every Guest Additions ISO ships a Cert\ folder with
# VBoxCertUtil.exe and the current signing certificates
# (vbox-sha1.cer/vbox-sha256.cer); running
# `VBoxCertUtil.exe add-trusted-publisher` with THAT ISO's own certs before
# running the installer makes Windows accept its drivers immediately --
# confirmed live, byte for byte, down to VBoxWindowsAdditions.exe's own
# output changing from a bare failure to "Signed by trusted certificate."
# This worked with the exact Guest Additions version this VirtualBox host
# ships (no need for an older ISO, despite what earlier experimentation
# assumed) -- the certs must come from the SAME iso as the installer being
# run, not from some other Guest Additions version's leftover install
# directory, since the signing certificate is re-issued per release.

$ErrorActionPreference = "Stop"

Write-Host "== VirtualBox Guest Additions =="
# Same retry rationale as provision.ps1 originally had: guest_additions_mode
# = "attach" can take a few seconds to actually enumerate with a drive
# letter, especially this soon after a reboot. WMI, not the CIM cmdlets or
# Get-Volume, since neither exists on PowerShell 2.0.
function Find-GuestAdditionsSetup {
    $byCdromDrive = Get-WmiObject Win32_CDROMDrive |
        Where-Object { $_.Drive } |
        ForEach-Object { Join-Path $_.Drive "VBoxWindowsAdditions.exe" } |
        Where-Object { Test-Path $_ }
    # DriveType 5 = CD-ROM in Win32_Volume/Win32_LogicalDisk.
    $byVolume = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=5" |
        Where-Object { $_.DeviceID } |
        ForEach-Object { Join-Path "$($_.DeviceID)\" "VBoxWindowsAdditions.exe" } |
        Where-Object { Test-Path $_ }
    @($byCdromDrive) + @($byVolume) | Select-Object -First 1
}

$setup = $null
$attempts = 12
for ($i = 1; $i -le $attempts; $i++) {
    $setup = Find-GuestAdditionsSetup
    if ($setup) { break }
    Write-Host "Guest Additions ISO not visible yet (attempt $i/$attempts), waiting..."
    Start-Sleep -Seconds 10
}

if ($setup) {
    $isoRoot = Split-Path -Parent $setup
    $certUtil = Join-Path $isoRoot "cert\VBoxCertUtil.exe"
    if (Test-Path $certUtil) {
        Write-Host "== trusting this ISO's own publisher certificates =="
        Get-ChildItem (Join-Path $isoRoot "cert") -Filter "vbox-sha*.cer" |
            Where-Object { $_.Name -notmatch "root|timestamp" } |
            ForEach-Object {
                Write-Host "trusting $($_.FullName)"
                & $certUtil add-trusted-publisher $_.FullName
            }
    } else {
        Write-Warning "no cert\VBoxCertUtil.exe next to $setup -- proceeding without pre-trusting the publisher certificate; the install below will likely fail with ERROR_AUTHENTICODE_TRUST_NOT_ESTABLISHED if the cert isn't already trusted some other way"
    }

    Write-Host "installing Guest Additions from $setup"
    $proc = Start-Process -FilePath $setup -ArgumentList "/S" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "VBoxWindowsAdditions.exe exited with code $($proc.ExitCode)"
    }
    # VBoxService.exe ends up in System32, not under Program Files -- it's
    # the actual Windows service binary, copied there by the installer;
    # the Program Files\Oracle\VirtualBox Guest Additions folder holds the
    # uninstaller, docs, and per-feature subfolders, not this one.
    $installed = Test-Path "$env:WINDIR\System32\VBoxService.exe"
    if ($installed) {
        Write-Host "Guest Additions installed (VBoxService.exe present)"
        Start-Service VBoxService -ErrorAction SilentlyContinue
    } else {
        Write-Warning "VBoxService.exe not found after install -- check install_drivers.log and install.log under $isoRoot's installed copy (normally %ProgramFiles%\Oracle\VirtualBox Guest Additions) for the real error instead of assuming it's the same one this comment describes"
    }
} else {
    Write-Warning "VBoxWindowsAdditions.exe not found on any optical drive after ${attempts} attempts; attach the Guest Additions ISO (guest_additions_mode = attach) before running this script"
}
