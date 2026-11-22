# Driver Test/Debug VM image builder

Builds the Windows 10 x64 VirtualBox VM for automated test/debug of drivers,
so the setup (`vm_guest_setup_bcd.bat`) doesn't need to be done by hand.
This file covers the Win10 build (`build-win10.ps1`); for Win7, see
[`win7/README.md`](win7/README.md) and `build-win7.ps1` -- same idea, kept
as its own Packer config under `win7/` since the two templates can't share
a directory (see `win7/win7-testvm.pkr.hcl`'s header comment for why).

The Win10 build bakes in:

- `bcdedit /set TESTSIGNING ON`
- `bcdedit /debug on` and `bcdedit /dbgsettings serial debugport:1 baudrate:115200`
- the `Debug Print Filter` registry value (`DEFAULT=0xf`) the test's
  `--verifier` flow relies on to see `DbgPrint` output once a debugger is
  attached
- UAC off and a local administrator account (`tester` / `win10/win10-testvm.pkr.hcl`'s
  `winrm_password` for `vbox_autotest.py`)
- VirtualBox Guest Additions
- a serial port wired to a named pipe (`\\.\pipe\<vm_name>-com1`), the one
  `--kd` looks for

## Prerequisites

- VirtualBox
- A Windows 10 x64 install ISO (Win7 x64 SP1 for `build-win7.ps1` instead)

## Build

One command, start to finish (build + compact):

```
cd packer
.\build-win10.ps1 -IsoUrl C:\Distr\Windows-10-pro-en.iso -VmName w10-pro
.\build-win7.ps1 -IsoUrl C:\Distr\Windows-7-pro-en.iso -VmName w7-pro
```

`build-win10.ps1` runs `packer init`, then `packer build -on-error=abort` (see why
below), and — only once that build has actually exited 0 — compacts the
resulting VDI itself and prints before/after size. A build failure leaves
the VM and disk in place and the script exits non-zero without touching
them, so nothing needs to be redone by hand on top of a fix.

For a local `-IsoUrl` it also hashes the file itself and fills in
`-IsoChecksum`, so there's no separate `certutil -hashfile` step — pass
`-IsoChecksum sha256:<hex>` explicitly only for a remote URL, or to skip
re-hashing a large ISO you've already checksummed.

To run the steps separately instead:

```
cd packer/win10
packer init .
packer build -on-error=abort -var vm_name=w10-pro -var iso_url=<path-or-url-to-win10-x64.iso> -var iso_checksum=sha256:<hex> .
VBoxManage modifymedium --compact ..\output-w10-pro\w10-pro.vdi
```

`output_directory` in `win10/win10-testvm.pkr.hcl` points one level up
(`../output-<name>`, not `output-<name>` here), so build output lands at
the top of `packer/`, not nested under `win10/`.

`-on-error=abort` matters: Packer's default on-error behavior deletes the
builder's output directory (the VM's disk) on ANY failure, including one in
a late, unrelated step — `keep_registered` only keeps the VM *registered*,
it does not protect the backing file. `abort` leaves the VM and disk as they
were so a failure can actually be inspected (or just reused) instead of
losing an hour's build to it. Compaction stays a separate step rather than a
Packer post-processor for the same reason: a post-processor failure is still
a build failure, so it would hit the exact cleanup-deletes-everything problem
`-on-error=abort` exists to avoid.

Useful overrides: 
`Autounattend.xml` installs "Windows 10 Pro" by `/IMAGE/NAME`; if your ISO's
`install.wim` has a different edition name or index, edit the `ImageInstall`
section accordingly (`dism /Get-WimInfo /WimFile:install.wim` on the ISO
lists them).

## After the build

The VM is left attached to the test ISO/Guest Additions media; eject them
(or let the next `vbox_autotest.py --device ...` run proceed — it doesn't
touch the optical drives). Nothing else from the manual setup is needed:
`vbox_autotest.py --preflight` and then a normal `--device <VID:PID>` run
should work directly against the built VM.

## Keeping it small

- `keep_registered`/`skip_export` are set so Packer leaves the VM registered
  in VirtualBox under `vm_name` instead of also exporting an OVA copy, which
  would roughly double the disk used.
- The disk is a dynamic VDI (default 40 GB cap, `-var disk_size=...` to
  change) — it only grows as Windows actually writes to it.
- `win10/scripts/shrink.ps1` runs last: drops provisioned consumer apps, turns
  hibernation off, runs a component-store cleanup, and zeroes freed disk
  space by writing real zero bytes to a temp file (not `cipher /w`: its last
  pass writes random data, which leaves free space non-zero and defeats
  compaction — measured 38.7 GB still used out of 40 GB with `cipher /w`,
  vs 12.3 GB with an actual zero-fill).
- Compaction happens in `build-win10.ps1`, after `packer build` itself, not as a
  Packer post-processor (see the `-on-error=abort` note above for why) — or
  run `VBoxManage modifymedium --compact output-<vm_name>\<vm_name>.vdi` by
  hand if you used the separate-steps form.
- `memory` defaults to 2048 MB; raise it with `-var memory=...` if the guest
  needs more while actually running tests (this only affects RAM, not disk).

## All settings applied

Everything baked into the image, file by file -- useful as a single place to
check what's actually in there without reading all four files.

### VM hardware (`win10/win10-testvm.pkr.hcl`, `vboxmanage`/builder settings)

- CPUs: 2 (`-var cpus=...`)
- Memory: 2048 MB (`-var memory=...`)
- Disk: 40 GB dynamic VDI cap (`-var disk_size=...`) -- only grows as Windows
  actually writes to it
- VRAM: 32 MB -- the builder's own default (4 MB) is too little for the
  VBoxSVGA graphics controller to actually switch resolution when the VM
  window is resized; Guest Additions' auto-resize silently does nothing
  above a small window size without enough VRAM to back the new mode
- Graphics controller: `vboxsvga` (the builder's default), needed for
  Guest Additions auto-resize at all
- USB: OHCI + EHCI + xHCI all enabled, so `vbox_autotest.py`'s
  `VBoxManage controlvm usbattach` always has a controller to attach a USB
  1.1/2.0/3.0 device to
- Serial port: COM1 (`0x3F8`, IRQ 4) wired to a named pipe
  `\\.\pipe\<vm_name>-com1`, the one `--kd` looks for
- `keep_registered = true`, `skip_export = true`: the VM stays registered in
  VirtualBox under `vm_name` instead of also being exported as an OVA, which
  would roughly double the disk used
- Guest Additions ISO attached (`guest_additions_mode = "attach"`)
- WinRM communicator: username `tester`, password from `winrm_password`
  (must match `win10/http/Autounattend.xml`'s local account)

### Windows unattended install (`win10/http/Autounattend.xml`)

- Language/locale: `en-US`
- Disk layout: 350 MB "System Reserved" + the rest as `C:`, both NTFS
- Edition: "Windows 10 Pro" by `/IMAGE/NAME`, with a generic (non-activating)
  KMS client setup key so Setup can pick an edition unattended on a
  multi-edition ISO
- EULA accepted automatically
- Computer name `testvm`, timezone UTC
- UAC disabled via registry during the specialize pass, before WinRM ever
  needs to log in, so it gets an elevated token for `tester` right away
- Local administrator account `tester` (password baked in -- must match
  `win10/win10-testvm.pkr.hcl`'s `winrm_password`), with `AutoLogon` enabled
- OOBE screens skipped (EULA, OEM registration, online account, wireless
  setup); network location set to "Work"
- `FirstLogonCommands` bring WinRM up over HTTP: reclassify the network as
  Private (VirtualBox's NAT adapter comes up "Public", and WinRM's
  `AllowUnencrypted` refuses to enable itself on a Public network), open the
  firewall for port 5985, enable `AllowUnencrypted` + Basic auth (both
  service and client), then restart the WinRM service

### Baked-in system config (`win10/scripts/provision.ps1`)

- `bcdedit /set TESTSIGNING ON`
- `bcdedit /set nointegritychecks OFF`
- `bcdedit /debug on` and `bcdedit /dbgsettings serial debugport:1 baudrate:115200`
- `Debug Print Filter` registry value (`DEFAULT=0xf`), so `DbgPrint` output reaches
  a kernel debugger once one is attached (`--kd`)
- UAC off (`EnableLUA=0`) -- belt-and-suspenders with the Autounattend.xml
  setting above, since this script also runs standalone against an existing
  VM in some workflows
- VirtualBox Guest Additions installed from the attached ISO: waits up to
  2 minutes for the optical drive to actually enumerate, installs silently
  (`/S`), then verifies `VBoxService.exe` actually landed on disk afterward
  instead of trusting the installer's exit code alone
- Policies that stop Windows from re-installing consumer apps on its own
  after they're removed: `DisableWindowsConsumerFeatures`,
  `DisableCloudOptimizedContent`, `DisableConsumerAccountStateContent`,
  Windows Store `AutoDownload=2`, `TurnOffWindowsCopilot`,
  `DisableSearchBoxSuggestions`
- Early removal of Xbox/OneNote/Copilot/Office Hub/Skype/Solitaire/Bing
  widgets/Clipchamp/etc. provisioned packages (before they can be touched
  by Windows Update or the Store for the rest of the build)

### Final cleanup (`win10/scripts/shrink.ps1`)

- Removes every remaining provisioned Appx package -- a blanket sweep that
  catches anything the named list in `provision.ps1` missed
- Hibernation off (`powercfg /hibernate off`), freeing the RAM-sized
  reservation on disk
- Component-store cleanup (`Dism /Cleanup-Image /StartComponentCleanup /ResetBase`)
  and clears Windows Update's download cache
- Clears temp files (`%WINDIR%\Temp`, `%TEMP%`)
- Zero-fills `C:`'s free space with real zero bytes (not `cipher /w`, whose
  last pass writes random data and defeats compaction -- see "Keeping it
  small" below)

### Orchestration (`build-win10.ps1`, `compact-vm.ps1`)

- `build-win10.ps1` self-installs `packer.exe` (checksum-verified against
  HashiCorp's published SHA256SUMS) if it isn't already next to it or on
  PATH, auto-hashes a local `-IsoUrl`, always runs `packer build
  -on-error=abort`, and only compacts the VDI after a confirmed-successful
  build (see "Build" above for why)
- `compact-vm.ps1` re-runs the zero-fill + compact against an existing VM
  by hand; its readiness check polls a guest property instead of repeatedly
  trying to log in with credentials, and the actual login check is capped
  at 3 attempts -- enough failed logins in a row trips Windows' default
  account-lockout policy and locks the guest account out

## Compacting an existing VM later

A VM keeps growing as it's used (updates, test runs, temp files), so the
disk drifts back up over time even after a fresh build was compacted.
`compact-vm.ps1` redoes both halves of that -- the in-guest zero-fill
`shrink.ps1` does during a build, and the host-side
`VBoxManage modifymedium --compact` -- against a VM that's already built,
running or not:

```
.\compact-vm.ps1 -VmName w10-pro
```

It starts the VM headless if it's off, waits for Guest Additions/guest
control to answer, zero-fills C:'s free space inside the guest the same way
`shrink.ps1` does (not `cipher /w` -- see the note above), shuts the guest
down, waits for `poweroff`, and only then compacts the VDI -- it refuses to
compact a VM that didn't actually reach `poweroff`, since compacting a disk
still attached to a running VM corrupts it. Needs Guest Additions and a
guest account `guestcontrol` can log into; `-GuestUsername`/`-GuestPassword`
default to `win10/http/Autounattend.xml`'s local account.
