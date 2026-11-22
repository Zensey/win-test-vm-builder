# Keeps the test VM's dynamic VDI small: drop bloat that isn't needed to run
# drivertest/guard-control, then zero freed clusters so the manual
# "VBoxManage modifymedium --compact" step after the build (see README) can
# actually hand the space back.

$ErrorActionPreference = "Continue"

Write-Host "== removing provisioned consumer apps =="
Get-AppxProvisionedPackage -Online | ForEach-Object {
    try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null }
    catch { Write-Warning "skip $($_.PackageName): $($_.Exception.Message)" }
}

Write-Host "== hibernation off (frees a RAM-sized reservation on disk) =="
powercfg /hibernate off

Write-Host "== component store + update cache cleanup =="
Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase
Stop-Service wuauserv -ErrorAction SilentlyContinue
Remove-Item -Path "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

Write-Host "== temp files =="
Remove-Item -Path "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "== zeroing free space on C: so the dynamic VDI can shrink =="
# Not "cipher /w": its three passes end by writing RANDOM data as the last
# pass, which leaves free-space clusters non-zero and defeats compaction
# (VBoxManage modifymedium --compact only reclaims all-zero blocks) -- a
# build measured 38.7 GB still used out of 40 GB after cipher /w, vs 12.3 GB
# once free space was actually left zeroed.
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
