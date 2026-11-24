packer {
  required_plugins {
    qemu = {
      # An exact pin: Packer has no plugin lockfile, so a range would let
      # `packer init` install whatever is newest. Renovate bumps it (see
      # renovate.json); keep version directly above source. The templates
      # need 1.1.7 or later (see the http_bind_address comments).
      version = "1.1.8"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "git_hash" {
  type        = string
  default     = ""
  description = "Commit the image is built from, suffixed with -dirty when the repository has uncommitted changes. Set by build.sh."

  validation {
    condition     = can(regex("^[0-9a-f]{40}(-dirty)?$", var.git_hash))
    error_message = "The git_hash variable must be a full commit hash, optionally followed by -dirty. Use ./build.sh, which sets it."
  }
}

variable "release" {
  type        = string
  default     = "dev"
  description = "Release version recorded in the build evidence (build_info.yaml), such as v0.20261207.0. The release workflow sets it; local builds keep dev."

  validation {
    # v0.<UTC date>.<patch>, optionally -pre.<n>: see scripts/release-version.sh.
    condition     = can(regex("^(dev|v0\\.[1-9][0-9]{7}\\.(0|[1-9][0-9]*)(-pre\\.(0|[1-9][0-9]*))?)$", var.release))
    error_message = "The release variable must be dev or a release version such as v0.20261207.0 or v0.20261207.1-pre.0."
  }
}

variable "build_ssh_public_key" {
  type        = string
  description = "Public half of the throwaway key Packer logs in with. build.sh generates one per build and gives Packer the private half through an ssh-agent; scripts/seal.sh removes the key from the image."

  validation {
    # The kickstart embeds the key in a single-quoted string on one line, so
    # the comment is limited to printable ASCII without ' (0x20-0x26 and
    # 0x28-0x7E). A negated class like [^'] would also match newlines.
    condition     = can(regex("^ssh-ed25519 [A-Za-z0-9+/]+=*( [ -&(-~]*)?$", trimspace(var.build_ssh_public_key)))
    error_message = "The build_ssh_public_key variable must be an ssh-ed25519 public key. Use ./build.sh, which generates one."
  }
}

# Build VM settings. They don't change the image (the kickstarts fix the
# partition sizes), so a builder can fit them to its host with PKR_VAR_*
# environment variables. The defaults suit dev machines, including macOS.
variable "accelerator" {
  type        = string
  default     = "tcg"
  description = "QEMU accelerator. tcg emulates the CPU in software, which works anywhere (macOS can't run x86 guests otherwise). kvm is far faster on x86 Linux hosts; the guest still sees an Ivy Bridge CPU, but see scripts/check-guest-agent.sh for what it doesn't catch."
}

variable "cpus" {
  type        = number
  default     = 8
  description = "vCPUs for the build VM."
}

variable "memory" {
  type        = number
  default     = 8192
  description = "Memory for the build VM, in MiB."
}

locals {
  timestamp = formatdate("YYYYMMDD'T'hhmmss'Z'", timestamp())

  # Each build gets its own output directory: the qemu builder refuses to reuse
  # an existing one, and parallel builds must not share one.
  build_id = "${var.git_hash}_${local.timestamp}"

  # The kickstarts' authorized_keys line for the build key. scripts/seal.sh
  # removes the key, but a build that stops before it runs (packer build
  # -on-error=abort or ask) leaves a disk that still lists it. These options
  # limit where that disk accepts the key: only from 10.0.2.2, the address
  # Packer's connection comes from through QEMU's user networking (the SSH port
  # is forwarded from the host's loopback), and only for a day, which covers
  # even a slow TCG build.
  # Each image's kickstart, as the build serves it. The disk layout is shared
  # (http/storage.ks.pkrtpl): opt_mib is the one size that differs, since
  # AlmaLinux 10's mkfs.xfs won't make a filesystem under 300 MiB.
  kickstarts = {
    for image, opt_mib in { alma9 = 128, alma10 = 300 } : image => templatefile("${path.root}/http/${image}.ks.pkrtpl", {
      build_ssh_authorized_key = local.build_ssh_authorized_key
      storage = templatefile("${path.root}/http/storage.ks.pkrtpl", {
        image   = image
        opt_mib = opt_mib
        # fsuuid root, as http/storage.ks.pkrtpl's %pre computes it.
        root_uuid = join("-", [
          substr(sha256("${image}-root"), 0, 8), substr(sha256("${image}-root"), 8, 4),
          "4${substr(sha256("${image}-root"), 13, 3)}", "8${substr(sha256("${image}-root"), 17, 3)}",
          substr(sha256("${image}-root"), 20, 12),
        ])
      })
    })
  }

  build_ssh_authorized_key = join(" ", [
    format("from=\"10.0.2.2\",expiry-time=\"%s\"", formatdate("YYYYMMDDhhmm'Z'", timeadd(timestamp(), "24h"))),
    trimspace(var.build_ssh_public_key),
  ])
}
