# Win7 test VM (packer/win7)

Windows 7 x64 (SP1) counterpart to `../win10-testvm.pkr.hcl`, as its own
Packer config in this directory (not extra sources bolted onto the Win10
one -- see the comment at the top of `win7-testvm.pkr.hcl` for why). Build
it via `../build-win7.ps1`, not a script in this directory -- the entry
points for both OS versions live together at the top of `packer/`
(`build-win10.ps1`/`build-win7.ps1`), even though each one's actual Packer
config (templates, `http/`, `scripts/`) has to stay in its own directory
for the reason above.

## Getting Packer to actually connect: two bugs, stacked

Getting from a fresh Win7 install to a Packer build that runs
`provision.ps1`/`shrink.ps1` took finding two unrelated bugs, one behind
the other.

**Bug 1 (ours): an unquoted value in `FirstLogonCommands` silently
disabled Basic auth.** Every Packer connection attempt failed with
`http response error: 401 - invalid content type`, even though a plain
`curl -u` with the same credentials against the same listener returned
200 OK. The actual cause: `FirstLogonCommands` enabled Basic auth with an
**unquoted** value, `@{Basic=true}`, which `winrm set` rejects with a
syntax error; the trailing `& exit 0` (there to stop an unrelated,
expected failure from aborting Setup) silently swallowed that error, so
Basic auth stayed disabled the whole time. With it genuinely off, the
server could only answer with `Negotiate`, Packer's Basic `Authorization`
header got flatly rejected, and *that* 401 (a rejection, not a
mid-handshake challenge) is what the client library can't parse.
**Lesson for `Autounattend.xml`'s command lists**: `& exit 0` (or any
error-swallowing trick) hides a genuine syntax error as well as it hides
the harmless one it's there for -- treat a step that needs it as writing
to a write-only destination, and independently verify the effect that
actually matters (here, "is Basic auth really enabled") instead of
trusting the command exited 0.

**Bug 2 (upstream, real): `masterzen/winrm`'s pinned commit returns an
empty shell ID.** With Basic auth actually fixed, `curl` and a bare
`CreateShell()` call both still worked -- but Packer kept retrying
forever anyway, this time with no error above [INFO] level at all.
Tracing it with `PACKER_LOG=1` down to an *actual command execution*
(not just shell creation) surfaced `InvalidSelectors: ... requires the
following selector: ShellId` -- the shell exists, but every request that
needs its ID (run a command, read output, close it) omits the selector
entirely, because `ParseOpenShellResponse` silently returns `("", nil)`
for a perfectly valid `CreateShell` response. Isolated with a one-off Go
program linked against the exact dependency
`packer-plugin-virtualbox` 1.1.6 pins (`masterzen/winrm` commit
`5f8e6c707321`, Sept 2025): the XPath it uses
(`//rsp:ShellId | //w:Selector[@Name='ShellId']`) finds the node fine
when run standalone against the captured response, but returns nothing
through the library's own `parseResponse()`/`ParseOpenShellResponse()`
call path -- a real upstream bug, not anything specific to this VM or to
Packer's own code. `masterzen/winrm`'s current HEAD (commit
`d693523ae428`, Nov 2026) does not have it.
**Fix**: `build-patched-plugin.ps1` clones `packer-plugin-virtualbox`,
updates its `masterzen/winrm` dependency to latest, rebuilds the plugin
binary, and installs it over the official 1.1.6 release with
`packer plugins install --path ... --force`. This is a local,
host-specific fix -- there's nothing to commit here, and it has to be
re-run on a new machine (or dropped once a `packer-plugin-virtualbox`
release actually picks up the fixed dependency).

**A third thing, not a bug, just a gap to cover**: VirtualBox's NAT
engine accepts a TCP connection's handshake immediately, even before the
guest has a real listener behind it, so a connection attempt made while
Setup is still running can end up `Established` but talking to nothing --
confirmed live with `Get-NetTCPConnection`, one such connection sat
`Established` for 9+ minutes with Packer stuck on it while a brand new
connection to the same port got a normal response right away. `win7-
testvm.pkr.hcl` sets `winrm_connect_timeout`/`winrm_retry_interval` to
`"10s"` (added in `packer-plugin-virtualbox` 1.1.6) so Packer gives up a
bad connection and retries fresh instead of hanging on it indefinitely.

```
cd packer/win7
.\build-patched-plugin.ps1   # one-time per machine -- see "Getting Packer to
                             # actually connect" above for why this is needed
cd ..
.\build-win7.ps1 -IsoUrl C:\Distr\Windows-7-pro-sp1-x64-en.iso -VmName w7-pro
```

Or step by step:

```
cd packer/win7
packer init .
packer build -on-error=abort -var vm_name=w7-pro -var iso_url=<path-or-url-to-win7-sp1-x64.iso> -var iso_checksum=sha256:<hex> .
VBoxManage modifymedium --compact ..\output-w7-pro\w7-pro.vdi
```

`output_directory` in `win7-testvm.pkr.hcl` points one level up
(`../output-<name>`, not `output-<name>` here), so build output lands next
to `output-w10-pro` at the top of `packer/`, not nested under `win7/`.

`../compact-vm.ps1` works against this VM unchanged -- just point
`-VdiPath` at `../output-<name>\<name>.vdi` (one level up from here) and
pass `-GuestUsername tester -GuestPassword DriverTestTest!1` (or whatever this
VM was actually built with) explicitly, since its own default VDI path
assumes the Win10 layout.

## What's different from the Win10 build, and why

- **Known limitation, not a bug to fix here:** VirtualBox cannot pass
  USB devices through to a **Hyper-V** guest at all (see the top-level
  `tests/vbox_autotest.py` prerequisites) -- not specific to Win7, just
  worth repeating since it's the reason this project uses VirtualBox for
  the actual USB allow/deny test in the first place, on either OS.
- **`Autounattend.xml`:** 100 MB System Reserved partition (Win7's own
  default, not Win8+'s 350 MB), a Win7-specific generic KMS client setup
  key (currently set for Enterprise -- `/IMAGE/NAME` and the key MUST
  match the edition actually in your ISO's install.wim, or Setup falls
  back to showing its normal interactive language/edition screens instead
  of silently applying this file; `dism /Get-WimInfo` on the ISO lists
  what's there).
- **WinRM setup is split across specialize (Group Policy registry keys)
  and `FirstLogonCommands` (the actual listener), not the Win10 build's
  single `winrm quickconfig`/Set-Item WSMan block:** the Win10 approach
  (reclassify the NAT adapter as Private via `Get-NetConnectionProfile`,
  then enable `AllowUnencrypted`) doesn't carry over -- Windows 7's
  PowerShell 2.0 has no `Get-NetConnectionProfile` (needs the NetTCPIP
  module, Win8+), and its replacement, the legacy `INetworkListManager`
  COM API, is suspected (not confirmed) to have raced an interactive "Set
  Network Location" dialog and gotten `FirstLogonCommands` stuck behind it
  the first time this was tried -- WinRM never came up, Guest Additions
  never got a chance to install, and the VM just sat there until someone
  dismissed the dialog by hand. Setting
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service\AllowUnencrypted`
  directly in specialize sidesteps that one setting's network-category
  check, confirmed by `winrm get winrm/config/service` showing
  `AllowUnencrypted = true [Source="GPO"]`. The rest -- actually creating
  the HTTP listener, enabling Basic auth, raising the WinRM shell quota --
  turned out to silently no-op when attempted the same way from
  specialize's SYSTEM/Session 0 context (confirmed live: the service came
  up `RUNNING` with no listener and the default quota regardless), so
  those three live in `FirstLogonCommands` instead, where they're confirmed
  to work instantly in a real logged-on session.
- **Default `MaxShellsPerUser` (5) is easy to exhaust before a flaky WinRM
  connection ever succeeds:** Packer's WinRM waiter opens a new shell on
  every health-check poll; several failed/abandoned polls in a row use up
  the quota, and every later attempt then fails with `QuotaLimit`, which
  looks identical to "not ready yet" from Packer's side -- confirmed live,
  this can make the build hang indefinitely even once everything else is
  configured correctly. `FirstLogonCommands` raises it to 50.
- **`scripts/provision.ps1`:** Guest Additions detection uses
  `Get-WmiObject` instead of `Get-CimInstance`, and a `Win32_LogicalDisk`
  filter instead of `Get-Volume` -- same PowerShell-2.0 reason. No
  Copilot/Store/Cloud-Content policy block and no `Get-AppxProvisionedPackage`
  removal: that's all Windows 8+/Store-app machinery that doesn't exist on
  Win7, not something ported over.
- **`scripts/shrink.ps1`:** `Dism /Cleanup-Image /SPSuperseded` instead of
  `/StartComponentCleanup` (Windows 8+ only) for the component-store step;
  everything else (hibernation off, temp cleanup, real zero-fill instead
  of `cipher /w`) is identical to the Win10 script. Its provisioner block
  also sets `skip_clean = true`, working around a known, harmless upstream
  Packer bug (https://github.com/hashicorp/packer/issues/11013): without
  it, the separate post-script step that deletes the uploaded script/
  env-vars temp files sometimes fails with "The term 'c:/Windows/Temp/
  packer-ps-env-vars-....ps1' is not recognized" -- confirmed harmless
  upstream and confirmed here too (shrink.ps1's own output, through the
  zero-fill, prints in full before this error, so the script itself
  already finished; only that one cosmetic cleanup command is affected).
  `skip_clean` just skips it outright instead of letting it fail noisily,
  at the cost of leaving a few KB of script/env-var files in
  `C:\Windows\Temp`.
- **`oobeSystem`'s `<OOBE>` block is the minimal, long-established Win7 set,
  not the fuller Win10 list:** `HideOnlineAccountScreens`,
  `HideOEMRegistrationScreen`, and `HideWirelessSetupInOOBE` are not in
  Windows 7's Shell-Setup catalog, even though they're part of the general
  unattend XML schema -- including any of them makes Setup fail outright
  with "Windows could not parse unattend answer file ... for pass
  [oobeSystem]. A component or setting specified in the answer file does
  not exist." The message never names which setting, so if you add more
  `<OOBE>`/`<Shell-Setup>` settings later and hit this again, remove them
  one at a time rather than assuming it's the same one as last time --
  this error only shows up once Setup actually reaches that pass, well
  after the disk/image steps succeed, so it's easy to assume the file is
  otherwise fine from the install getting that far. `SkipMachineOOBE`/
  `SkipUserOOBE` already skip the whole OOBE wizard on Win7, which is why
  dropping the Hide* flags (Win8+'s more granular replacement for the same
  thing) doesn't lose any automation here.
- **Autounattend.xml needs a UTF-8 BOM, unlike the Win10 one:** Windows 7's
  WinPE unattend parser is pickier about encoding detection than Win8+'s --
  without a BOM it can silently fail to apply the file at all and just
  fall back to Setup's normal interactive language-selection screen,
  which looks like the floppy wasn't found rather than a parse error.
  `../http/Autounattend.xml` (Win10) doesn't need this.
- **Guest Additions needs its publisher certificate trusted first --
  `install-guest-additions.ps1` does this automatically now.** The
  installer exited 1 with `ERROR_AUTHENTICODE_TRUST_NOT_ESTABLISHED
  (0xe0000242)`: not a SHA-2/KB3033929 issue (that was the first guess,
  wrong), not something TESTSIGNING or `nointegritychecks ON` fixes (both
  tried live, neither changed anything) -- a fresh Windows 7 install just
  doesn't have Oracle's current code-signing certificate in its
  trusted-publisher store. Every Guest Additions ISO ships the fix for
  this right next to the installer: a `cert\` folder with
  `VBoxCertUtil.exe` and that release's own `vbox-sha1.cer`/
  `vbox-sha256.cer`. Running `VBoxCertUtil.exe add-trusted-publisher` with
  those (not certificates left over from some other Guest Additions
  version -- the signing cert is reissued per release, confirmed live
  that an older version's certs don't satisfy a newer installer's
  signature check or vice versa) before running the installer makes it
  succeed immediately, confirmed down to `VBoxWindowsAdditions.exe`'s own
  output changing from a bare failure to "Signed by trusted certificate."
  No older Guest Additions ISO needed -- this works with whatever version
  the host ships.
  **Separately, also fixed**: the installed-successfully check looked for
  `VBoxService.exe` under `%ProgramFiles%\Oracle\VirtualBox Guest
  Additions`, which is wrong regardless of the certificate issue -- the
  actual service binary lands in `%WINDIR%\System32`. The old check would
  have reported "not found" even against a fully successful install.
- **`guard-control` itself won't run on this guest** if it's built with
  Go 1.21+ (see the top-level `AGENTS.md`/`tests/vbox_autotest.py`
  prerequisites: "Go 1.21+ builds of guard-control do not run on Windows
  7"). `provision.ps1`/`shrink.ps1` here get you a guest that's ready for
  manual driver work and WinRM-driven provisioning; running the actual
  `vbox_autotest.py` end-to-end flow against it additionally needs a
  `guard-control` built with an older Go toolchain.
