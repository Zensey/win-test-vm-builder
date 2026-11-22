# Builds the Windows 7 x64 (SP1) VirtualBox VM, as a Win7 counterpart to
# ../win10-testvm.pkr.hcl -- same approach (bake in test signing, kernel
# debug/bcdedit settings, UAC off, an administrator account, Guest
# Additions, a serial port on a named pipe), but kept as a fully separate
# Packer config in its own directory, not extra variables/sources bolted
# onto the Win10 one.
#
# Why separate instead of one shared .pkr.hcl: `packer build <dir>` builds
# every source block in every *.pkr.hcl in that directory as one merged
# config, and HCL variable names can't be declared twice in one config.
# Win10's win10-testvm.pkr.hcl already owns "vm_name", "iso_url", etc. in
# ../ -- a second source block with the same variable names next to it
# would either collide or (worse) silently build both VMs on one
# `packer build .`. A separate directory keeps each OS version its own
# config, buildable on its own.
#
# Usage (normally via ../build-win7.ps1, which wraps all of this):
#   cd packer/win7
#   packer init .
#   packer build -var iso_url=<path-or-url-to-win7-x64-sp1.iso> -var iso_checksum=<sha256> .
#
# The VM name must match what you pass to vbox_autotest.py as --vm.

packer {
  required_plugins {
    virtualbox = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/virtualbox"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "w7"
}

variable "iso_url" {
  type        = string
  description = "Path or URL to a Windows 7 x64 SP1 install ISO"
}

variable "iso_checksum" {
  type        = string
  description = "e.g. sha256:<hex>"
}

variable "winrm_username" {
  type    = string
  default = "tester"
}

variable "winrm_password" {
  type      = string
  default   = "DriverTestTest!1"
  sensitive = true
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 2048
}

variable "disk_size" {
  # Cap for the dynamic VDI, not how much it actually uses on disk; it only
  # grows as Windows writes to it.
  type    = number
  default = 40960
}

source "virtualbox-iso" "w7" {
  vm_name          = var.vm_name
  guest_os_type    = "Windows7_64"
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  cpus             = var.cpus
  memory           = var.memory
  disk_size        = var.disk_size
  # No VM window during the build: everything here (install, WinRM,
  # provisioning) only ever needed the guest reachable over the network,
  # never a visible console. Debugging this template did rely on
  # `VBoxManage controlvm <name> screenshotpng`/keyboardputstring against a
  # headless VM, which both still work the same as against a windowed one.
  headless = true

  # One level up, not "${path.root}/output-...": output-w10-pro already
  # lives at the top of packer/ (next to build-win10.ps1/build-win7.ps1),
  # so output-w7-pro goes there too instead of nesting under win7/ --
  # keeps both OS versions' build output next to each other regardless of
  # where each one's own .pkr.hcl/scripts have to live.
  output_directory = "${path.root}/../output-${var.vm_name}"

  keep_registered = true
  skip_export     = true

  guest_additions_mode = "attach"

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "6h"

  # Getting Packer to connect over WinRM here took finding two bugs, not
  # one -- see ../README.md's "Getting Packer to actually connect" for the
  # full story. Short version:
  # 1. FirstLogonCommands had an unquoted `@{Basic=true}`, which `winrm
  #    set` silently rejects; the trailing "& exit 0" swallowed the error,
  #    leaving Basic auth disabled. That surfaced as "http response error:
  #    401 - invalid content type" and looked exactly like a Packer/
  #    masterzen-winrm bug -- it wasn't. Fixed by quoting it properly
  #    (`@{Basic="true"}`).
  # 2. With Basic auth actually enabled, Packer still hung forever, this
  #    time because packer-plugin-virtualbox 1.1.6 pins a masterzen/winrm
  #    commit (5f8e6c707321, Sept 2025) whose ParseOpenShellResponse
  #    silently returns an EMPTY shell ID for a valid CreateShell response
  #    -- a real upstream bug, confirmed by isolating the exact XPath it
  #    uses and by diffing behavior against masterzen/winrm's current HEAD
  #    (d693523ae428, Nov 2026), which doesn't have it. CreateShell()
  #    itself doesn't need a shell ID so it "succeeds", but every
  #    operation that does (run a command, read output, close the shell)
  #    then fails with "InvalidSelectors ... requires ... ShellId", which
  #    Packer's WinRM waiter retries forever without ever logging above
  #    [INFO]. Fixed on this machine by `build-patched-plugin.ps1`, which
  #    rebuilds packer-plugin-virtualbox against current masterzen/winrm
  #    and installs it over the official 1.1.6 binary -- re-run that
  #    script on a new machine, since the patched binary isn't (and
  #    shouldn't be) committed here.
  # winrm_use_ntlm = false stays here regardless of either bug, just
  # because it doesn't hurt and documents that NTLM was never the right
  # lever to pull for either one.
  winrm_use_ntlm = false

  # VirtualBox's NAT engine accepts a TCP connection's handshake right
  # away even before the guest has anything actually listening behind it,
  # so a connection attempt made while Setup is still running (before
  # FirstLogonCommands creates the WinRM listener) can end up ESTABLISHED
  # but talking to nothing -- confirmed live with `Get-NetTCPConnection`:
  # one such connection sat "Established" for 9+ minutes with Packer still
  # waiting on it, while a brand new connection to the same port (a
  # throwaway Go program using the same WinRM library) got a normal
  # response immediately. Without a connect timeout, Packer's WinRM waiter
  # can get stuck on that one bad connection indefinitely instead of
  # retrying fresh. These two options (added in packer-plugin-virtualbox
  # 1.1.6) bound that: give up and retry every 10s instead of hanging.
  winrm_connect_timeout = "10s"
  winrm_retry_interval  = "10s"

  # No scripts/enable-winrm.cmd here, unlike the Win10 build: WinRM is set
  # up entirely through Group Policy registry keys in Autounattend.xml's
  # specialize pass (see its comment) rather than a floppy script running
  # "winrm quickconfig", which turned out not to work reliably on Win7.
  floppy_files = [
    "${path.root}/http/Autounattend.xml",
  ]

  # Same reasoning as win10-testvm.pkr.hcl: a named-pipe serial port for
  # --kd, all three USB controllers on so vbox_autotest.py's
  # "VBoxManage controlvm usbattach" always has one to attach to, and VRAM
  # raised from the builder's 4 MB default so Guest Additions' auto-resize
  # actually works when the VM window is resized.
  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--uart1", "0x3F8", "4"],
    ["modifyvm", "{{.Name}}", "--uartmode1", "server", "\\\\.\\pipe\\${var.vm_name}-com1"],
    ["modifyvm", "{{.Name}}", "--usbohci", "on", "--usbehci", "on", "--usbxhci", "on"],
    ["modifyvm", "{{.Name}}", "--vram", "32"],
  ]

  shutdown_command = "shutdown /s /t 5 /f /d p:4:1 /c \"packer shutdown\""
  shutdown_timeout = "15m"

  boot_wait = "2m"
}

build {
  sources = ["source.virtualbox-iso.w7"]

  provisioner "powershell" {
    script = "${path.root}/scripts/provision.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  provisioner "powershell" {
    inline = [
      "bcdedit /enum | findstr /i testsigning",
      "bcdedit /enum | findstr /i debug",
    ]
  }

  # After the restart, not before: harmless either way (TESTSIGNING turned
  # out not to matter for Guest Additions -- see install-guest-additions
  # .ps1's header comment for the real fix), but there's no reason to move
  # it back before the reboot.
  provisioner "powershell" {
    script = "${path.root}/scripts/install-guest-additions.ps1"
  }

  # skip_clean = true: without it, Packer's own powershell provisioner hits
  # a known, harmless upstream bug after this script finishes --
  # https://github.com/hashicorp/packer/issues/11013 -- where its separate
  # post-script cleanup step (deleting the uploaded script + env-vars temp
  # files) fails with "The term 'c:/Windows/Temp/packer-ps-env-vars-....ps1'
  # is not recognized", confirmed harmless upstream ("non critical error as
  # the build completes") and confirmed here too: shrink.ps1's own
  # Write-Host output (hibernate off, DISM cleanup, temp files, zeroing)
  # all appears in the log BEFORE this error, meaning the script itself
  # already ran to completion -- it's purely that one cosmetic cleanup
  # command, not shrink.ps1, that the bug hits. skip_clean just skips that
  # cleanup step instead of letting it fail noisily; the few KB of leftover
  # script/env-var files it would have deleted from C:\Windows\Temp are not
  # worth chasing a flaky upstream race for.
  provisioner "powershell" {
    script     = "${path.root}/scripts/shrink.ps1"
    skip_clean = true
  }

  # No compaction post-processor on purpose -- see win10-testvm.pkr.hcl's
  # comment for why. Always run `packer build` with -on-error=abort, then
  # compact by hand afterwards:
  #   VBoxManage modifymedium --compact <path printed at the end of the build>
}
