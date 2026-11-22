#Requires -Version 5.1
<#
.SYNOPSIS
  Zero-fills free space inside an already-built VM's guest, then compacts
  its VDI on the host -- the two steps shrink.ps1 + build-win10.ps1 do during a
  fresh build, run here by hand against a VM that already exists (e.g. one
  that has idled and accumulated writes, or was never built through
  build-win10.ps1 at all).

.DESCRIPTION
  1. Starts the VM headless if it isn't running.
  2. Waits for Guest Additions / guest control to answer, then runs the same
     zero-fill shrink.ps1 uses (real zero bytes, not `cipher /w` -- its last
     pass writes random data and defeats compaction) inside the guest via
     `VBoxManage guestcontrol run`.
  3. Shuts the guest down cleanly and waits for poweroff.
  4. Runs `VBoxManage modifymedium --compact` on the VDI and prints
     before/after size.

  Needs the VM to already have Guest Additions installed (anything built by
  build-win10.ps1 does) and a guest account guestcontrol can log into.

.PARAMETER VmName
  VM name as registered in VirtualBox.

.PARAMETER GuestUsername
  Guest account for guestcontrol / shutdown. Default matches
  http/Autounattend.xml's local account.

.PARAMETER GuestPassword
  Password for -GuestUsername. Default matches the CURRENT
  http/Autounattend.xml / win10-testvm.pkr.hcl's winrm_password -- a VM
  built before either was last edited still has whatever password it was
  actually built with, so pass -GuestPassword explicitly for an older VM
  (repeated attempts with a wrong password will lock -GuestUsername out
  under Windows' default account-lockout policy, so this script only tries
  3 times, not in a loop).

.PARAMETER VdiPath
  Path to the VM's VDI. Default: output-<VmName>\<VmName>.vdi next to this
  script, matching what win10-testvm.pkr.hcl's output_directory produces.

.EXAMPLE
  .\compact-vm.ps1 -VmName w10-pro
#>
param(
    [Parameter(Mandatory = $true)][string]$VmName,
    [string]$GuestUsername = "tester",
    [string]$GuestPassword = "DriverTestTest!1",
    [string]$VdiPath,
    [int]$BootTimeoutSec = 300,
    [int]$ShutdownTimeoutSec = 180,
    # How long a single `guestcontrol run` call is allowed to hang before
    # it's treated as failed. The zero-fill itself can legitimately take a
    # while on a large disk, hence the much larger default than the other
    # guestcontrol calls (login check, shutdown trigger) use.
    [int]$ZeroFillTimeoutSec = 900
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

if (-not $VdiPath) {
    $VdiPath = Join-Path $root "output-$VmName\$VmName.vdi"
}
if (-not (Test-Path $VdiPath)) {
    throw "VDI not found: $VdiPath (pass -VdiPath explicitly if it lives elsewhere)"
}

function Find-VBoxManage {
    $candidates = @(
        $env:VBOXMANAGE,
        $(if ($env:VBOX_MSI_INSTALL_PATH) { Join-Path $env:VBOX_MSI_INSTALL_PATH "VBoxManage.exe" }),
        "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    ) | Where-Object { $_ }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    throw "VBoxManage.exe not found; set VBOXMANAGE"
}

function Invoke-VBoxQuiet {
    # $ErrorActionPreference = "Stop" turns a native exe's stderr output into
    # a terminating NativeCommandError -- expected here (e.g. "Guest
    # Additions are not installed or not ready (yet)" while the guest is
    # still booting), so swallow it and let the caller check $LASTEXITCODE.
    #
    # Runs in a background job with a timeout, not just `&` directly:
    # `guestcontrol run` has been observed to hang indefinitely on this
    # project's Win7 test VM (confirmed live -- the zero-fill step below
    # sat for 8+ minutes with no file ever created on the guest side, no
    # error, nothing to Ctrl+C), even though Guest Additions themselves are
    # genuinely installed and working, and the very same call can succeed
    # fine moments before or after. Without a timeout, that hang is this
    # script's hang -- there is no other way to detect or recover from it.
    param([string[]]$VBoxArgs, [int]$TimeoutSec = 60)
    # NOT named $Args for the scriptblock parameter: that shadows
    # PowerShell's own automatic $args variable, which silently broke
    # `@Args` splatting here the first time this was written -- VBoxManage
    # received garbage and printed its own usage text instead of running,
    # which then got misread as an exit code (see the exitCode fix below).
    $job = Start-Job -ScriptBlock {
        param($VBoxExe, $CmdArgs)
        & $VBoxExe @CmdArgs 2>$null | Out-Null
        $LASTEXITCODE
    } -ArgumentList $script:vbox, $VBoxArgs
    try {
        if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
            $script:LastInvokeTimedOut = $true
            $global:LASTEXITCODE = -1
            return
        }
        $script:LastInvokeTimedOut = $false
        # -Last 1, not the whole thing: Receive-Job returns every object the
        # scriptblock wrote, including whatever the native command printed
        # to stdout before the trailing $LASTEXITCODE -- without -Last 1,
        # $exitCode becomes that entire array, which then gets caught up
        # jamming the actual VBoxManage output into "exit $LASTEXITCODE"
        # error messages elsewhere in this script instead of a number.
        $exitCode = Receive-Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1
        $global:LASTEXITCODE = if ($null -eq $exitCode) { -1 } else { $exitCode }
    } finally {
        Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Get-VmState {
    param($VBox, $Name)
    $line = & $VBox showvminfo $Name --machinereadable 2>$null | Select-String '^VMState='
    if (-not $line) { throw "VM '$Name' not found" }
    ($line -split '=')[1].Trim('"')
}

$vbox = Find-VBoxManage

$state = Get-VmState $vbox $VmName
Write-Host "== $VmName is currently '$state' ==" -ForegroundColor Cyan

$weStartedIt = $false
if ($state -ne "running") {
    Write-Host "== starting $VmName headless =="  -ForegroundColor Cyan
    & $vbox startvm $VmName --type headless
    if ($LASTEXITCODE -ne 0) { throw "startvm failed" }
    $weStartedIt = $true
}

Write-Host "== waiting for Guest Additions to report in (no login attempts yet) =="  -ForegroundColor Cyan
# Polls a guest property instead of repeatedly calling `guestcontrol run`
# with credentials: enough failed logon attempts in a row trips Windows'
# default account-lockout policy and locks -GuestUsername out, which
# happened the hard way once already. This only proves the GA driver/service
# are up, not that -GuestUsername/-GuestPassword are correct -- that's
# checked next, with a small bounded number of attempts.
$deadline = (Get-Date).AddSeconds($BootTimeoutSec)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $version = & $vbox guestproperty get $VmName "/VirtualBox/GuestAdd/Version" 2>$null
    if ($version -match "^Value:") { $ready = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $ready) {
    throw "Guest Additions never reported in within ${BootTimeoutSec}s; is the VM's network/Guest Additions up?"
}

Write-Host "== confirming guest control actually logs in (up to 3 attempts, 15s apart) =="  -ForegroundColor Cyan
$loggedIn = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Invoke-VBoxQuiet -TimeoutSec 60 -VBoxArgs @(
        "guestcontrol", $VmName, "run",
        "--username", $GuestUsername, "--password", $GuestPassword,
        "--exe", "C:\Windows\System32\cmd.exe", "--", "cmd.exe", "/c", "exit 0"
    )
    if ($LASTEXITCODE -eq 0) { $loggedIn = $true; break }
    if ($attempt -lt 3) { Start-Sleep -Seconds 15 }
}
if (-not $loggedIn) {
    $timeoutNote = if ($script:LastInvokeTimedOut) { " (the last attempt hung rather than failing outright -- guestcontrol on this VM has been observed to do that intermittently even with correct credentials; just retrying the script often works)" } else { "" }
    throw "guest control login/exec failed after 3 attempts (exit $LASTEXITCODE)$timeoutNote -- check -GuestUsername/-GuestPassword are right for THIS VM (an older VM may still use whatever password it was actually built with, not necessarily what's in Autounattend.xml/win10-testvm.pkr.hcl's current default), and check for account lockout (lusrmgr.msc on the guest) before retrying by hand rather than re-running this script in a loop"
}

Write-Host "== zeroing free space on C: inside the guest (same as shrink.ps1) -- started $(Get-Date -Format 'HH:mm:ss'), can take up to ${ZeroFillTimeoutSec}s on a large disk ==" -ForegroundColor Cyan
# Not `cipher /w`: its last pass writes random data and leaves free space
# non-zero, defeating compaction -- see shrink.ps1's comment for the
# measured before/after this caused.
$zeroFillCmd = @'
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
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($zeroFillCmd))
Invoke-VBoxQuiet -TimeoutSec $ZeroFillTimeoutSec -VBoxArgs @(
    "guestcontrol", $VmName, "run",
    "--username", $GuestUsername, "--password", $GuestPassword,
    "--exe", "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
    "--", "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded
)
if ($script:LastInvokeTimedOut) {
    Write-Warning "zero-fill didn't finish within ${ZeroFillTimeoutSec}s -- guestcontrol on this VM has been observed to hang here intermittently even though the command itself is fine (confirmed by hand: the same call succeeds moments later). Continuing to shutdown/compact anyway, since whatever got written so far is still worth compacting, but this run may not have zeroed everything it could have -- re-run this script if the compaction result looks smaller than expected."
} elseif ($LASTEXITCODE -ne 0) {
    Write-Warning "zero-fill exited $LASTEXITCODE (often just 'disk full' once it hits the target -- continuing)"
}

Write-Host "== shutting down $VmName =="  -ForegroundColor Cyan
Invoke-VBoxQuiet -TimeoutSec 60 -VBoxArgs @(
    "guestcontrol", $VmName, "run",
    "--username", $GuestUsername, "--password", $GuestPassword,
    "--exe", "C:\Windows\System32\cmd.exe",
    "--", "cmd.exe", "/c", "shutdown /s /t 0 /f"
)
if ($LASTEXITCODE -ne 0) {
    $timeoutNote = if ($script:LastInvokeTimedOut) { " (timed out rather than failing outright -- try again, or trigger the shutdown by hand)" } else { "" }
    throw "triggering guest shutdown failed (exit $LASTEXITCODE)$timeoutNote"
}

$deadline = (Get-Date).AddSeconds($ShutdownTimeoutSec)
$off = $false
while ((Get-Date) -lt $deadline) {
    if ((Get-VmState $vbox $VmName) -eq "poweroff") { $off = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $off) {
    throw "VM did not reach poweroff within ${ShutdownTimeoutSec}s; leaving the VDI alone -- compacting a running/live VM's disk would corrupt it"
}

$before = (Get-Item $VdiPath).Length
Write-Host ("== compacting {0} ({1:N1} GB before) ==" -f $VdiPath, ($before / 1GB)) -ForegroundColor Cyan
& $vbox modifymedium --compact $VdiPath
if ($LASTEXITCODE -ne 0) { throw "compaction failed (exit $LASTEXITCODE)" }

$after = (Get-Item $VdiPath).Length
Write-Host ("== done: {0:N1} GB -> {1:N1} GB ==" -f ($before / 1GB), ($after / 1GB)) -ForegroundColor Green

if ($weStartedIt) {
    Write-Host "(VM was off before this script ran; left it off now too)" -ForegroundColor DarkGray
}
