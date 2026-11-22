@echo off
rem UNUSED -- no longer referenced by win10-testvm.pkr.hcl's floppy_files or
rem Autounattend.xml. Its job (bringing up WinRM over HTTP) is now done
rem entirely through Autounattend.xml's own RunSynchronousCommand/GPO
rem registry keys in the specialize pass, which don't depend on network
rem category the way "winrm quickconfig"/these winrm set calls do -- see
rem that file's specialize-pass comment. Kept here only for reference.

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
