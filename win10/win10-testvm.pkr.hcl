# Builds the Windows 10 x64 VirtualBox VM that tests/vbox_autotest.py drives.
# Bakes in what that test currently expects to be set up by hand (see
# vm_guest_setup_bcd.bat and the prerequisites comment at the top of
# vbox_autotest.py): test signing, kernel debug/bcdedit settings, UAC off, an
# administrator account, Guest Additions, and a serial port on a named pipe
# for --kd.
#
# Usage (normally via ../build-win10.ps1, which wraps all of this):
#   cd packer/win10
#   packer init .
#   packer build -var iso_url=<path-or-url-to-win10-x64.iso> -var iso_checksum=<sha256> .
#
# The VM name must match what you pass to vbox_autotest.py as --vm (default
# "w10"); the kd pipe path below is derived from it.

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
  default = "w10"
}

variable "iso_url" {
  type        = string
  description = "Path or URL to a Windows 10 x64 install ISO"
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
  # grows as Windows writes to it. 40 GB covers a minimal Win10 Pro install
  # plus the driver/guard-control binaries with headroom for updates.
  type    = number
  default = 40960
}

source "virtualbox-iso" "w10" {
  vm_name          = var.vm_name
  guest_os_type    = "Windows10_64"
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  cpus             = var.cpus
  memory           = var.memory
  disk_size        = var.disk_size
  headless         = true

  # Explicit and vm_name-based so the disk's path is predictable for the
  # manual "VBoxManage modifymedium --compact" step after a build. One
  # level up, not "${path.root}/output-...": build output lives at the top
  # of packer/ (next to build-win10.ps1/build-win7.ps1), not nested under
  # win10/ -- same reasoning as win7-testvm.pkr.hcl's output_directory.
  output_directory = "${path.root}/../output-${var.vm_name}"

  # Keep the VM registered in VirtualBox under vm_name instead of exporting
  # an OVA copy and deregistering it: vbox_autotest.py drives it by name, and
  # skipping the OVA export avoids doubling the disk space used.
  keep_registered = true
  skip_export     = true

  guest_additions_mode = "attach"

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "6h"

  # enable-winrm.cmd used to be staged here too, but its job (bringing up
  # WinRM over HTTP in the specialize pass) is now done entirely through
  # Autounattend.xml's own RunSynchronousCommand/GPO registry keys -- see
  # that file's specialize-pass comment for why.
  floppy_files = [
    "${path.root}/http/Autounattend.xml",
  ]

  # A serial port wired to a named pipe, the way tests/vbox_autotest.py's
  # --kd expects to find it ("VM '%s' has no serial port on a named pipe").
  #
  # All three USB controllers on (OHCI/EHCI/xHCI) so USB 1.1/2.0/3.0 devices
  # all have a controller to land on: without one at all,
  # vbox_autotest.py's "VBoxManage controlvm usbattach" has nothing to attach
  # the host device to.
  #
  # 32 MB VRAM: the builder's own default (4 MB) is too little for VBoxSVGA
  # to actually switch resolution when the VM window is resized -- Guest
  # Additions auto-resize silently does nothing at anything above a small
  # window size with too little VRAM to back the new mode.
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
  sources = ["source.virtualbox-iso.w10"]

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

  # Shrink the footprint: drop bloat, zero freed clusters so the dynamic VDI
  # can actually give that space back, then compact it from the host side.
  provisioner "powershell" {
    script = "${path.root}/scripts/shrink.ps1"
  }

  # No compaction post-processor here on purpose: a failure in a post-processor
  # still fails the whole build, and Packer's default on-error cleanup then
  # deletes this builder's output directory -- taking the finished disk out
  # from under the VM it just spent an hour building, even with
  # keep_registered = true (that only keeps the VM *registered*; it doesn't
  # protect the backing file). Compact it afterwards instead:
  #   VBoxManage modifymedium --compact <path printed at the end of the build>
  # Always run `packer build` with -on-error=abort so a failure anywhere
  # leaves the VM and disk in place for inspection instead of wiping them.
}
