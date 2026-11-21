@echo off
rem Run from the attached floppy during Windows Setup's specialize pass
rem (see Autounattend.xml). Brings up a WinRM listener Packer can connect to.
rem Auth/firewall are re-applied in FirstLogonCommands too: this early in
rem specialize the firewall service isn't reliably up yet, so a netsh call
rem here can silently no-op.

winrm quickconfig -q
winrm set winrm/config @{MaxTimeoutms="1800000"}
winrm set winrm/config/winrs @{MaxMemoryPerShellMB="1024"}
winrm set winrm/config/service @{AllowUnencrypted="true"}
winrm set winrm/config/service/auth @{Basic="true"}
winrm set winrm/config/client/auth @{Basic="true"}

netsh advfirewall firewall add rule name=WinRM-HTTP dir=in action=allow protocol=TCP localport=5985 profile=any

net stop winrm
sc config winrm start= auto
net start winrm
