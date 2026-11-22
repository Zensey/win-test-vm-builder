#Requires -Version 5.1
<#
.SYNOPSIS
  Builds the Win7 drivertest test VM end to end: packer build, then compaction.
  Win7 counterpart to build-win10.ps1 -- see its header comment for why
  compaction is a separate step here and not a Packer post-processor.

  Entry point lives here, at the top of packer/, alongside build-win10.ps1,
  but the actual Packer config (win7-testvm.pkr.hcl, http/, scripts/) stays
  under win7/ -- it can't live next to win10-testvm.pkr.hcl in the same
  directory: `packer build <dir>` merges every *.pkr.hcl in a directory
  into one config, and the two templates declare the same variable names
  (vm_name, iso_url, ...), which would collide. See win7/win7-testvm.pkr
  .hcl's own header comment for the full explanation.

.PARAMETER IsoUrl
  Path or URL to a Windows 7 x64 SP1 install ISO.

.PARAMETER IsoChecksum
  Checksum for -IsoUrl, e.g. "sha256:<hex>". Omit it for a local -IsoUrl
  file and this script computes the SHA256 itself; a remote URL still
  needs one given explicitly.

.PARAMETER VmName
  VM name (must match --vm passed to tests/vbox_autotest.py). Default "w7".

.PARAMETER PackerVersion
  packer.exe version to fetch from releases.hashicorp.com when none is
  found next to this script or on PATH.

.EXAMPLE
  .\build-win7.ps1 -IsoUrl C:\Distr\Windows-7-pro-sp1-x64-en.iso -VmName w7-pro
#>
param(
    [Parameter(Mandatory = $true)][string]$IsoUrl,
    [string]$IsoChecksum,
    [string]$VmName = "w7",
    [int]$Cpus,
    [int]$Memory,
    [int]$DiskSize,
    [string]$PackerVersion = "1.16.2"
)

$ErrorActionPreference = "Stop"
# The Packer CONFIG root (win7-testvm.pkr.hcl and everything relative to
# it, like output_directory) -- NOT this script's own location.
$root = Join-Path $PSScriptRoot "win7"

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
# Shared packer.exe next to this script (and build-win10.ps1) -- not a
# separate copy under win7/, since it's the same binary either way.
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

Write-Host "== packer build ($VmName) ==" -ForegroundColor Cyan
& $packerExe @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "packer build failed (exit $LASTEXITCODE); VM/disk left in place for inspection"
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
# lands on stderr, even when VBoxManage itself exits 0 -- same issue
# compact-vm.ps1 hit and fixed the same way: swallow stderr, check the real
# exit code ourselves instead of letting PowerShell's error promotion decide.
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
