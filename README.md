# alma-x86v2-xcp

AlmaLinux cloud-init images for XCP-ng on x86_64_v2 hardware.

## should I use this?

Probably not. I made these for a homelab use case.
However, they may be useful as a reference for your own builds.

They are released under MIT, though, and you may do whatever you like with them.

## build

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

```bash
PKR_VAR_accelerator=kvm ./build.sh alma9   # on an x86 Linux host with /dev/kvm
```

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

## package sources

| Image | Packages from |
|---|---|
| `alma9` | AlmaLinux 9 and Fedora's EPEL 9 |
| `alma10` | AlmaLinux 10 (x86_64_v2) and AlmaLinux's x86_64_v2 rebuild of EPEL 10 (`almalinux-epel/10z`) |

Fedora's EPEL 10 is built for x86_64_v3, so `alma10` uses AlmaLinux's v2 rebuild
instead. That is a different publisher from Fedora EPEL: AlmaLinux, not the
Fedora Project, builds those packages.

## releases

Each release rebuilds every image with the packages current that day. Releases
go out on the first and third Monday of each month, when a template moves to a
new AlmaLinux point release, and by hand as needed, such as for a security fix.

Releases are versioned `v0.<UTC date>.<n>`, such as `v0.20261207.0`; `n`
goes up with each release that day. Each image is named after the AlmaLinux
version it contains, `alma9-9.9-v0.20261207.0.vhd.zst`, with its checksums
(`.SHA256SUMS`) and build evidence (`.evidence.tar.gz`) beside it. In a VM,
`/root/build_info.yaml` records the release it was cloned from.

## AI disclosure

Early versions of this were pre-LLM, but in the last few years there have
been significant contributions using generative AI tools.
Take that as you will. Use at your own risk.
