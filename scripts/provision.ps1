# Bakes into the image everything tests/vbox_autotest.py expects the guest to
# already have set up by hand (see vm_guest_setup_bcd.bat and the README at the
# top of vbox_autotest.py): test signing, kernel debug/bcdedit settings, the
# Driver Verifier debug-print registry value, and VirtualBox Guest Additions.
# Run by packer/win10-testvm.pkr.hcl via the "powershell" provisioner.

$ErrorActionPreference = "Stop"

Write-Host "== test signing + kernel debugging =="
bcdedit /set TESTSIGNING ON
bcdedit /set nointegritychecks OFF
bcdedit /debug on
bcdedit /dbgsettings serial debugport:1 baudrate:115200

Write-Host "== Debug Print Filter (DbgPrint -> kernel debugger) =="
# Matches tests/vbox_autotest.py's ug_verifier.bat: DEFAULT=0xf lets DbgPrint
# through once a kernel debugger (kd.exe, --kd) is attached.
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter" `
    /v DEFAULT /t REG_DWORD /d 0xf /f

Write-Host "== UAC off (guest control / winrm need an elevated token) =="
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name EnableLUA -Value 0 -Type DWord

Write-Host "== VirtualBox Guest Additions =="
# guest_additions_mode = "attach" (win10-testvm.pkr.hcl) attaches the ISO
# around the same time this provisioner starts, so the optical drive can take
# a few seconds to actually enumerate with a drive letter -- retry instead of
# failing on the first look. Win32_CDROMDrive is also sometimes a beat behind
# a disk that *is* already there, so fall back to any CD-ROM volume by label.
function Find-GuestAdditionsSetup {
    $byCdromDrive = Get-CimInstance Win32_CDROMDrive |
        Where-Object { $_.Drive } |
        ForEach-Object { Join-Path $_.Drive "VBoxWindowsAdditions.exe" } |
        Where-Object { Test-Path $_ }
    $byVolume = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq "CD-ROM" -and $_.DriveLetter } |
        ForEach-Object { Join-Path "$($_.DriveLetter):\" "VBoxWindowsAdditions.exe" } |
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
    Write-Host "installing Guest Additions from $setup"
    $proc = Start-Process -FilePath $setup -ArgumentList "/S" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "VBoxWindowsAdditions.exe exited with code $($proc.ExitCode)"
    }
    $installed = Test-Path "${env:ProgramFiles}\Oracle\VirtualBox Guest Additions\VBoxService.exe"
    if ($installed) {
        Write-Host "Guest Additions installed (VBoxService.exe present)"
    } else {
        Write-Warning "VBoxService.exe not found after install -- Guest Additions likely did not install correctly"
    }
} else {
    Write-Warning "VBoxWindowsAdditions.exe not found on any optical drive after ${attempts} attempts; attach the Guest Additions ISO (guest_additions_mode = attach) before running this script"
}

Write-Host "== blocking Windows' own re-install of consumer apps (Copilot, Store auto-download, Cloud Content) =="
# shrink.ps1 removes the provisioned packages (Xbox, OneNote, etc.) at the end
# of the build, but Windows can push several of them straight back on first
# logon via "Cloud Content"/consumer-experience and auto-download Store
# updates -- these policies stop that at the source instead of just chasing
# whatever shrink.ps1 catches.
$policies = @(
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsConsumerFeatures"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableCloudOptimizedContent"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableConsumerAccountStateContent"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"; Name = "AutoDownload"; Value = 2 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"; Name = "DisableStoreApps"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1 }
)
foreach ($p in $policies) {
    New-Item -Path $p.Path -Force | Out-Null
    New-ItemProperty -Path $p.Path -Name $p.Name -Value $p.Value -PropertyType DWord -Force | Out-Null
}

Write-Host "== removing bundled consumer apps (Xbox, OneNote, Copilot, etc.) now, not just at shrink time =="
# Best-effort and run again by shrink.ps1 at the end: removing these now
# means they don't sit there getting updated by Windows Update / the Store
# for the rest of the build, on top of what shrink.ps1 is for (disk size).
$unwantedPatterns = @(
    "*Copilot*", "*OneNote*", "*Xbox*", "*Office.OneNote*", "*OfficeHub*",
    "*Skype*", "*SolitaireCollection*", "*ZuneMusic*", "*ZuneVideo*",
    "*BingWeather*", "*BingNews*", "*GetHelp*", "*Getstarted*", "*People*",
    "*Clipchamp*", "*Todos*", "*PowerAutomateDesktop*"
)
Get-AppxProvisionedPackage -Online |
    Where-Object { $name = $_.PackageName; $unwantedPatterns | Where-Object { $name -like $_ } } |
    ForEach-Object {
        try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null }
        catch { Write-Warning "skip $($_.PackageName): $($_.Exception.Message)" }
    }

Write-Host "== done; a reboot is needed for TESTSIGNING/debug/UAC to take effect =="
