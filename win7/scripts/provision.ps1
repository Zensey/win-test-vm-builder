# Win7 counterpart to ../../scripts/provision.ps1: bakes in test signing,
# kernel debug/bcdedit settings, the Driver Verifier debug-print registry
# value, and UAC off. Run by win7-testvm.pkr.hcl via the "powershell"
# provisioner, BEFORE windows-restart. Guest Additions installation lives
# in install-guest-additions.ps1, run AFTER that restart instead of here --
# see its header comment for why (TESTSIGNING needs the reboot to actually
# take effect, and installing before that reboot was failing).
#
# Differs from the Win10 script in what it deliberately leaves OUT, not
# just what it does: Windows 7 ships PowerShell 2.0, which has neither the
# CIM cmdlets (Get-CimInstance needs PS3+) nor the Appx cmdlets
# (Get-AppxProvisionedPackage needs Windows 8+/PS3+) nor the Storage module
# (Get-Volume needs Windows 8+). There is no Store/Copilot/Xbox bloat to
# remove or block on Win7 in the first place, so that whole section of the
# Win10 script has no Win7 equivalent -- it's not ported, it's just not
# needed.

$ErrorActionPreference = "Stop"

Write-Host "== test signing + kernel debugging =="
bcdedit /set TESTSIGNING ON
bcdedit /set nointegritychecks OFF
bcdedit /debug on
bcdedit /dbgsettings serial debugport:1 baudrate:115200

Write-Host "== Debug Print Filter (DbgPrint -> kernel debugger) =="
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter" `
    /v DEFAULT /t REG_DWORD /d 0xf /f

Write-Host "== UAC off (guest control / winrm need an elevated token) =="
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name EnableLUA -Value 0 -Type DWord

Write-Host "== done; a reboot is needed for TESTSIGNING/debug/UAC to take effect =="
