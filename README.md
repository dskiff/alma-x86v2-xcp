# alma-x86v2-xcp

AlmaLinux cloud-init images for XCP-ng on x86_64_v2 hardware.

## should I use this?

Probably not. I made these for a homelab use case.
However, they may be useful as a reference for your own builds.

They are released under MIT, though, and you may do whatever you like with them.

## build

You need Packer and QEMU (including `qemu-img`), plus `git`, `ssh-agent`,
`ssh-keygen`, `python3` and `createrepo_c` (the `createrepo-c` package on
Debian and Ubuntu, `createrepo_c` in Homebrew). [devbox](https://www.jetify.com/devbox) installs the pinned
Packer and QEMU from `devbox.json`: run `devbox shell`, or let direnv load it
through `.envrc`. Builds work on macOS and Linux; on macOS they emulate the
CPU, so expect them to be slow.

```bash
# Build a specific image
./build.sh alma9
./build.sh alma10

# Build all images (in parallel)
./build.sh
```

| Variable | Default | |
|---|---|---|
| `PKR_VAR_accelerator` | `tcg` | QEMU accelerator. `tcg` emulates the CPU in software, the only way macOS can run x86 guests. On an x86 Linux host, `kvm` is far faster |
| `PKR_VAR_cpus` | `8` | vCPUs |
| `PKR_VAR_memory` | `8192` | MiB |
| `RPM_LOCK` | `1` | `0` installs from the floating repositories instead of the lockfiles; see [package sources](#package-sources) |

```bash
PKR_VAR_accelerator=kvm ./build.sh alma9   # on an x86 Linux host with /dev/kvm
```

Each build writes `output/alma_<major>_<commit>_<timestamp>/`, holding the
image as `<same name>.vhd` (the format XCP-ng imports), its `SHA256SUMS`, and
`build-evidence/` (installed packages, the CIS scan report). Follow the
install with `tail -f output/<build>/serial.log`.

`build.sh` records the commit in the image, and marks the build `-dirty` if
the working tree has uncommitted changes.

## accounts

The only login is `ansible`, with passwordless sudo. The image gives it no SSH
keys and no password: install keys on first boot with cloud-init. `ansible` is
cloud-init's default user, in place of the stock `almalinux` or `cloud-user`,
so keys from the VM's metadata and top-level `ssh_authorized_keys` go to it:

```yaml
#cloud-config
ssh_authorized_keys:
  - ssh-ed25519 AAAA...
```

Naming `ansible` in a `users` list works too. But a `users` list replaces the
default user: unless it includes `default`, keys from metadata or top-level
`ssh_authorized_keys` go to no one.

SSH takes keys only, and only from members of the `localssh` group, so other
users you create need `groups: localssh`. They also get the CIS scan's password
aging, even with no password: about a year after cloud-init creates one, SSH
logins as it fail with "Password change required but no TTY available".
`ansible` is exempt. To exempt another user, add to user-data:

```yaml
runcmd:
  - chage -M -1 -I -1 alice
```

## first boot

cloud-init reads its configuration only from a local seed disk: a NoCloud disk
labelled `cidata`, which is what Xen Orchestra attaches for a VM's cloud config,
or a ConfigDrive (`config-2`). It doesn't probe cloud metadata services.

The image is hardened with the CIS Server Level 1 profile at build time (the
scan report ships in the build evidence). The scan uses only the SCAP content of
the locked `scap-security-guide` package and downloads nothing. Security updates install
automatically through `dnf-automatic`, without rebooting. The image ships
without an AIDE database: run `aide --init` on each VM once it is configured.

## package sources

Each image installs exactly the packages its lockfile lists, `rpms/<image>.lock`:
each RPM's path and SHA-256, from the repositories in `rpms/<image>.repos`.
`build.sh` downloads them (cached in `~/.cache/alma-x86v2-xcp/rpms`), checks
each digest, and serves the installer a repository of only those packages, so
a build installs the same packages whatever the upstream repositories hold by
then.

Renovate opens a PR when a repository's metadata changes. On that PR, the RPM
lock workflow (`.github/workflows/rpm-lock.yml`) builds each image from the
floating repositories (`RPM_LOCK=0 ./build.sh`), writes the packages it
installed into the lockfile (`scripts/rpm-lock.py lock`), checks that a build
from the new lockfile installs the same packages, and pushes the lockfile to
the PR. Merging that PR is what moves the images to newer packages.

Upstream keeps old packages only for a while: AlmaLinux moves them to
vault.almalinux.org at each point release, and EPEL drops a package's old
version soon after an update. A lockfile that old no longer builds until
Renovate's next PR updates it.

| Image | Packages from |
|---|---|
| `alma9` | AlmaLinux 9 and Fedora's EPEL 9 |
| `alma10` | AlmaLinux 10 (x86_64_v2) and AlmaLinux's x86_64_v2 rebuild of EPEL 10 (`almalinux-epel/10z`) |

Fedora's EPEL 10 is built for x86_64_v3, so `alma10` uses AlmaLinux's v2 rebuild
instead. That is a different publisher from Fedora EPEL: AlmaLinux, not the
Fedora Project, builds those packages.

## releases

Each release rebuilds every image from the lockfiles on `main`. Releases
go out on the first and third Monday of each month, when a template moves to a
new AlmaLinux point release, and by hand as needed, such as for a security fix.

Releases are versioned `v0.<UTC date>.<n>`, such as `v0.20261207.0`; `n`
goes up with each release that day. Each image is named after the AlmaLinux
version it contains, `alma9-9.9-v0.20261207.0.vhd.zst`, with its checksums
(`.SHA256SUMS`) and build evidence (`.evidence.tar.gz`) beside it. The
evidence's `build_info.yaml` records the commit and release; the image itself
doesn't, so that two builds of the same inputs are the same image.

## reproducibility

Two builds of the same commit, from the same packages, should produce the same
image. The disk, filesystem and LVM IDs are fixed (`http/storage.ks.pkrtpl`),
`scripts/seal.sh` removes build-specific state from inside the VM, and
`scripts/finalize.sh` removes what the VM writes while shutting down and sets
every timestamp newer than the newest package's build time to that time. The
packages come from the lockfiles (see [package sources](#package-sources)). That
last step needs Linux and root, so local macOS builds skip it. The
Reproducibility workflow builds each image twice and reports any difference.

## repository layout

| Path | |
|---|---|
| `alma9.pkr.hcl`, `alma10.pkr.hcl` | Packer template for each image |
| `common.pkr.hcl` | Plugin pin, variables and locals shared by both templates |
| `http/*.ks.pkrtpl` | Kickstart for each image, rendered per build |
| `rpms/` | Each image's package repositories and lockfile; `scripts/rpm-lock.py` writes and fetches the lockfiles |
| `scripts/check-*.sh` | Checks that run inside the build VM and fail the build |
| `scripts/collect-evidence.sh`, `scripts/seal.sh` | Gather build records, then strip per-VM state before shutdown |
| `scripts/release-*.sh` | Release planning, versioning, drafting and notes, run by `release.yml` |
| `verify-iso.sh`, `keys/` | Check each template's ISO checksum against AlmaLinux's signed `CHECKSUM` |

## CI

Every pull request runs `verify-iso.sh`, `packer fmt` and `packer validate`,
`ksvalidator` on the rendered kickstarts, and `shellcheck`. A pull request that
changes a workflow also runs [zizmor](https://docs.zizmor.sh/), whose findings
appear under code scanning, and checks the actions lockfile. Renovate bumps the ISOs and
tool versions, and opens the PRs that update the RPM lockfiles; `verify-iso.sh` is what makes an ISO bump trustworthy, since
Renovate doesn't check signatures. Actions are pinned in
`.github/workflows/actions.lock`; after changing a workflow's `uses:`, run
`gh actions-lock` to update it.

## AI disclosure

Early versions of this were pre-LLM, but in the last few years there have
been significant contributions using generative AI tools.
Take that as you will. Use at your own risk.
