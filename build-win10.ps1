#Requires -Version 5.1
<#
.SYNOPSIS
  Builds the drivertest test VM end to end: packer build, then compaction.

.DESCRIPTION
  Wraps `packer build` instead of adding compaction as a Packer post-processor:
  a post-processor failure still fails the whole build, and Packer's default
  on-error cleanup then deletes the output directory (the VM's disk) -- see
  win10-testvm.pkr.hcl's comment on this. Doing the compact step out here,
  only after `packer build` itself has already exited 0, can't trigger that.

  Also replicates what a bad `cipher /w` run taught the hard way: compaction
  only reclaims clusters that are genuinely all-zero. shrink.ps1 (run inside
  the guest, as the last provisioner) already does the zero-fill with real
  zero bytes instead of cipher /w's random-data last pass, so the first
  `modifymedium --compact` here normally does the job -- but if you're
  re-compacting an older disk that was zeroed with cipher /w, or one that
  idled and accumulated writes since, run this twice: a dynamic VDI that
  somehow still shows little shrinkage usually needs the guest zero-filled
  again (boot it, see "Keeping it small" in README.md) before a second
  compact helps.

.PARAMETER IsoUrl
  Path or URL to a Windows 10 x64 install ISO.

.PARAMETER IsoChecksum
  Checksum for -IsoUrl, e.g. "sha256:<hex>". Omit it for a local -IsoUrl file
  and this script computes the SHA256 itself (certutil's job, automated); a
  remote URL still needs one given explicitly, since nothing has downloaded
  it yet to hash.

.PARAMETER VmName
  VM name (must match --vm passed to tests/vbox_autotest.py). Default "w10".

.PARAMETER PackerVersion
  packer.exe version to fetch from releases.hashicorp.com when none is found
  next to this script or on PATH. Default is the version this setup was
  validated against.

.EXAMPLE
  .\build-win10.ps1 -IsoUrl C:\Distr\Windows-10-pro-en.iso -VmName w10-pro
#>
param(
    [Parameter(Mandatory = $true)][string]$IsoUrl,
    [string]$IsoChecksum,
    [string]$VmName = "w10",
    [int]$Cpus,
    [int]$Memory,
    [int]$DiskSize,
    [string]$PackerVersion = "1.16.2"
)

$ErrorActionPreference = "Stop"
# The Packer CONFIG root (win10-testvm.pkr.hcl and everything relative to
# it, like output_directory) -- NOT this script's own location.
$root = Join-Path $PSScriptRoot "win10"

if (-not $IsoChecksum) {
    if ($IsoUrl -match "^[a-zA-Z][a-zA-Z0-9+.-]*://" -and $IsoUrl -notmatch "^file://") {
        throw "-IsoChecksum is required for a remote -IsoUrl (nothing to hash locally yet)"
    }
    if (-not (Test-Path $IsoUrl)) {
        throw "ISO not found: $IsoUrl"
    }
    Write-Host "== hashing $IsoUrl (no -IsoChecksum given) ==" -ForegroundColor Cyan
    $hash = (Get-FileHash -Path $IsoUrl -Algorithm SHA256).Hash.ToLower()
    $IsoChecksum = "sha256:$hash"
    Write-Host $IsoChecksum
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

function Install-Packer {
    param([string]$Version, [string]$DestDir)

    $zipName = "packer_${Version}_windows_amd64.zip"
    $base = "https://releases.hashicorp.com/packer/$Version"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "packer-install-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zipPath = Join-Path $tmp $zipName
        Write-Host "== downloading packer $Version =="  -ForegroundColor Cyan
        Invoke-WebRequest -Uri "$base/$zipName" -OutFile $zipPath

        # Verify against HashiCorp's own published SHA256SUMS, the same way
        # iso_checksum guards the Windows ISO above -- a plain binary
        # download is otherwise an unverified file from the network.
        $sumsPath = Join-Path $tmp "SHA256SUMS"
        Invoke-WebRequest -Uri "$base/packer_${Version}_SHA256SUMS" -OutFile $sumsPath
        $expected = (Select-String -Path $sumsPath -Pattern ([regex]::Escape($zipName))).Line -split '\s+' | Select-Object -First 1
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
        if (-not $expected -or $expected -ne $actual) {
            throw "packer $Version checksum mismatch (expected $expected, got $actual) -- not installing"
        }

        Expand-Archive -Path $zipPath -DestinationPath $tmp -Force
        Copy-Item (Join-Path $tmp "packer.exe") (Join-Path $DestDir "packer.exe") -Force
        Write-Host "== packer $Version installed to $DestDir ==" -ForegroundColor Green
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$vboxManage = Find-VBoxManage
# Shared packer.exe next to this script (and build-win7.ps1) -- not a
# separate copy under win10/, since it's the same binary either way.
$packerExe = Join-Path $PSScriptRoot "packer.exe"
if (-not (Test-Path $packerExe)) {
    $onPath = Get-Command packer.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        $packerExe = $onPath.Source
    } else {
        Install-Packer -Version $PackerVersion -DestDir $PSScriptRoot
    }
}

Write-Host "== packer init ==" -ForegroundColor Cyan
& $packerExe init $root
if ($LASTEXITCODE -ne 0) { throw "packer init failed" }

$buildArgs = @(
    "build", "-on-error=abort",
    "-var", "vm_name=$VmName",
    "-var", "iso_url=$IsoUrl",
    "-var", "iso_checksum=$IsoChecksum"
)
if ($Cpus) { $buildArgs += @("-var", "cpus=$Cpus") }
if ($Memory) { $buildArgs += @("-var", "memory=$Memory") }
if ($DiskSize) { $buildArgs += @("-var", "disk_size=$DiskSize") }
$buildArgs += $root

Write-Host "== packer build ($VmName) started at $(Get-Date -Format 'HH:mm:ss') ==" -ForegroundColor Cyan
Write-Host "   (OS install, OOBE and WinRM bring-up can take 10-30+ min before" -ForegroundColor DarkCyan
Write-Host "   provisioning output starts -- that's normal, not a hang; note the" -ForegroundColor DarkCyan
Write-Host "   time above if you need to judge how long it's actually been stuck)" -ForegroundColor DarkCyan
& $packerExe @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "packer build failed (exit $LASTEXITCODE); VM/disk left in place for inspection -- see README.md"
}

$vdi = Join-Path $PSScriptRoot "output-$VmName\$VmName.vdi"
if (-not (Test-Path $vdi)) {
    Write-Warning "build succeeded but $vdi was not found; compact it by hand once you locate it"
    exit 0
}

$before = (Get-Item $vdi).Length
Write-Host ("== compacting {0} ({1:N1} GB before) ==" -f $vdi, ($before / 1GB)) -ForegroundColor Cyan
# $ErrorActionPreference = "Stop" (above) turns VBoxManage's own progress
# output ("0%...10%...") into a terminating NativeCommandError if any of it
# lands on stderr, even when VBoxManage itself exits 0 -- swallow stderr
# and check the real exit code ourselves instead of letting PowerShell's
# error promotion decide (same fix as build-win7.ps1/compact-vm.ps1).
try {
    & $vboxManage modifymedium --compact $vdi 2>$null
} catch {
}
if ($LASTEXITCODE -ne 0) {
    Write-Warning "compaction failed (exit $LASTEXITCODE); the VM is still usable, just larger on disk than it needs to be"
    exit 0
}

$after = (Get-Item $vdi).Length
Write-Host ("== done: {0:N1} GB -> {1:N1} GB ==" -f ($before / 1GB), ($after / 1GB)) -ForegroundColor Green
