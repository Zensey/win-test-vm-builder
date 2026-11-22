#Requires -Version 5.1
<#
.SYNOPSIS
  Builds and installs a packer-plugin-virtualbox binary with a fixed
  masterzen/winrm dependency, working around a real upstream bug that
  otherwise makes this Win7 build hang forever on "Waiting for WinRM to
  become available".

.DESCRIPTION
  packer-plugin-virtualbox 1.1.6 (the latest release as of this writing)
  pins masterzen/winrm at commit 5f8e6c707321 (Sept 2025). That specific
  commit's ParseOpenShellResponse silently returns an EMPTY shell ID (no
  error) for a perfectly valid CreateShell response -- confirmed by
  isolating the exact XPath query ("//rsp:ShellId | //w:Selector
  [@Name='ShellId']") and running it standalone against a captured
  response: it finds the node fine on its own, but something in how
  parseResponse() calls it via the library's own code path returns "". The
  practical effect: CreateShell() itself succeeds (it doesn't need a shell
  ID), but every operation that needs one -- running a command, receiving
  its output, closing the shell -- fails with "InvalidSelectors ...
  requires the following selector: ShellId", because the request never
  includes it. Packer's own WinRM waiter runs an "echo" command to confirm
  the connection right after CreateShell(), so it hits this immediately
  and silently retries forever, logging nothing above [INFO]/[ERROR]
  level that points at the real cause.

  masterzen/winrm's current HEAD (checked here against commit d693523ae428,
  Nov 2026) does NOT have this bug -- the exact same unmodified test case
  returns the correct shell ID there. This script rebuilds
  packer-plugin-virtualbox against that newer masterzen/winrm and installs
  it over the official 1.1.6 binary, so Packer's own code is untouched --
  only the one broken transitive dependency is updated.

  This is a local, host-specific fix: `packer plugins install` always
  installs to this machine's plugin directory
  (%APPDATA%\packer.d\plugins\...), there's no way to pin it from
  win7-testvm.pkr.hcl itself, and the rebuilt binary isn't committed to
  this repo. Re-run this script after reinstalling Go/Packer on a new
  machine, or once a packer-plugin-virtualbox release actually picks up
  the fixed masterzen/winrm (check its go.mod/CHANGELOG).

.PARAMETER WorkDir
  Where to clone and build; defaults to a fresh temp directory.

.EXAMPLE
  .\build-patched-plugin.ps1
#>
param(
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) "packer-plugin-virtualbox-patch-$([guid]::NewGuid())")
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw "Go toolchain not found on PATH -- install it first (this only rebuilds a Go plugin binary, nothing else needs Go)"
}

$packerExe = Join-Path $PSScriptRoot "packer.exe"
if (-not (Test-Path $packerExe)) {
    $onPath = Get-Command packer.exe -ErrorAction SilentlyContinue
    if (-not $onPath) { throw "packer.exe not found next to this script or on PATH" }
    $packerExe = $onPath.Source
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
try {
    Write-Host "== cloning packer-plugin-virtualbox into $WorkDir ==" -ForegroundColor Cyan
    git clone --depth 1 https://github.com/hashicorp/packer-plugin-virtualbox.git $WorkDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }

    Push-Location $WorkDir
    try {
        Write-Host "== updating masterzen/winrm to latest (pulls in the ShellId parsing fix) ==" -ForegroundColor Cyan
        go get github.com/masterzen/winrm@latest
        if ($LASTEXITCODE -ne 0) { throw "go get failed" }

        $outExe = Join-Path $WorkDir "packer-plugin-virtualbox-patched.exe"
        Write-Host "== building (this pulls a lot of transitive deps the first time -- several minutes) ==" -ForegroundColor Cyan
        go build -o $outExe .
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }

        Write-Host "== installing over the official plugin binary ==" -ForegroundColor Cyan
        & $packerExe plugins install --path $outExe --force "github.com/hashicorp/virtualbox"
        if ($LASTEXITCODE -ne 0) { throw "packer plugins install failed" }

        Write-Host "== done -- re-run build.ps1 now =="  -ForegroundColor Green
    } finally {
        Pop-Location
    }
} finally {
    Write-Host "(build artifacts left in $WorkDir for inspection; delete it yourself once you've confirmed the fix works)" -ForegroundColor DarkGray
}
