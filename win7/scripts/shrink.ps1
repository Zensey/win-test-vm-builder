# Win7 counterpart to ../../scripts/shrink.ps1: keeps the test VM's dynamic
# VDI small by zero-filling freed clusters before the manual
# "VBoxManage modifymedium --compact" step (see ../../README.md).
#
# No Appx-removal section here: Get-AppxProvisionedPackage needs Windows
# 8+/PowerShell 3+, and Windows 7 has no provisioned Store apps to remove
# in the first place -- nothing to port. DISM's component-store cleanup
# also differs: /StartComponentCleanup is Windows 8+ only, so this uses
# /SPSuperseded instead (reclaims the old-service-pack backup files DISM
# keeps after an in-place SP install; a no-op, not an error, on an ISO that
# already has SP1 baked in rather than applied afterwards).

$ErrorActionPreference = "Continue"

Write-Host "== hibernation off (frees a RAM-sized reservation on disk) =="
powercfg /hibernate off

Write-Host "== component store cleanup (old service-pack backup files) =="
Dism /Online /Cleanup-Image /SPSuperseded
Stop-Service wuauserv -ErrorAction SilentlyContinue
Remove-Item -Path "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

Write-Host "== temp files =="
Remove-Item -Path "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "== zeroing free space on C: so the dynamic VDI can shrink =="
# Not "cipher /w": its three passes end by writing RANDOM data as the last
# pass, which leaves free-space clusters non-zero and defeats compaction --
# see ../../scripts/shrink.ps1's comment for the measured before/after this
# caused on the Win10 build.
$drive = Get-PSDrive C
$path = "C:\zero.tmp"
$buf = New-Object byte[] (64MB)
$fs = [System.IO.File]::Create($path)
$written = 0
$target = $drive.Free - 1GB
try {
    while ($written -lt $target) {
        $fs.Write($buf, 0, $buf.Length)
        $written += $buf.Length
    }
} catch {
} finally {
    $fs.Close()
}
Remove-Item $path -Force
