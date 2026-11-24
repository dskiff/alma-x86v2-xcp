# alma-x86v2-xcp

AlmaLinux cloud-init images for XCP-ng on x86_64_v2 hardware.

## Should I use this?

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

## CI

Every PR runs [`packer.yml`](.github/workflows/packer.yml), which boots no VM:

- `verify-iso.sh` (see [boot ISO](#boot-iso))
- `packer fmt -check` and `packer validate`
- `ksvalidator` on each kickstart, rendered as the build renders it, against
  that release's kickstart syntax
- ShellCheck on every `*.sh`

The images themselves are only built by [`release.yml`](.github/workflows/release.yml),
when a `v*` tag is pushed.

## accounts

The only login is `ansible`, with passwordless sudo. The image gives it no SSH
keys and no password: install keys on first boot with cloud-init, as
[`tf/reusable/alma-fixed/cloud-init.yml`](../tf/reusable/alma-fixed/cloud-init.yml)
does. SSH takes keys only, from members of the `localssh` group.

cloud-init's default user (`almalinux` or `cloud-user`) is turned off, so
top-level `ssh_authorized_keys` in user-data, which would go to that user,
don't give you a login.

## boot ISO

Renovate bumps each template's `iso_url` and `iso_checksum` from the
`CHECKSUM` file next to the ISO, but never checks that file's signature.
`./verify-iso.sh` does. It verifies `CHECKSUM` against the AlmaLinux release
key for that major version, pinned by fingerprint, and fails unless the signed
text gives the template's digest. CI runs it on every PR and before each
release build. Running it locally needs `curl` and GnuPG.

## package sources

| Image | Packages from |
|---|---|
| `alma9` | AlmaLinux 9 and Fedora's EPEL 9 |
| `alma10` | AlmaLinux 10 (x86_64_v2) and AlmaLinux's x86_64_v2 rebuild of EPEL 10 (`almalinux-epel/10z`) |

Fedora's EPEL 10 is built for x86-64-v3, so `alma10` uses AlmaLinux's rebuild
instead. That is a different publisher from Fedora EPEL: AlmaLinux, not the
Fedora Project, builds those packages, and VMs keep taking EPEL updates from
it. Using `alma10` means trusting AlmaLinux for EPEL as well.

Anaconda doesn't check package signatures during the install. It relies on
HTTPS and the repo metadata's checksums. To make up for that,
`scripts/check-signatures.sh` fails the build unless rpm verifies every
installed package's signature with a key in `/etc/pki/rpm-gpg/`, the keys dnf
checks updates against. Those keys come from the install itself, so the check
catches unsigned packages and unexpected signers, but not a compromised source
that serves its own keys. The build log lists each signing key ID and how many
packages it signed: compare them with the fingerprints the publishers list.

## AI Disclosure

Early versions of this were pre-LLM, but in the last few years there have
been significant contributions using generative AI tools. 
Take that as you will. Use at your own risk.
