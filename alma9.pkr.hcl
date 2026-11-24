source "qemu" "alma9" {
  accelerator = var.accelerator
  headless    = true
  cpus        = var.cpus
  memory      = var.memory
  # Renovate bumps iso_url + iso_checksum together (see renovate.json); keep them adjacent.
  iso_url      = "https://raw.repo.almalinux.org/almalinux/9/isos/x86_64/AlmaLinux-9.9-x86_64-boot.iso"
  iso_checksum = "sha256:b42da86274caabc56294ab9bc37d1bb8b2298fcf4304dca40c21d4cfb938f651"

  # The kickstart is rendered per build because it carries the throwaway build
  # key. Serve it on loopback only: QEMU user networking maps the guest's
  # 10.0.2.2 to the host's 127.0.0.1, so the installer can still fetch it.
  # The boot command names 10.0.2.2 rather than {{.HTTPIP}}: since qemu plugin
  # 1.1.7, {{.HTTPIP}} is the bind address, which to the guest is its own
  # loopback.
  http_bind_address = "127.0.0.1"
  http_content = {
    "/alma9.ks" = templatefile("${path.root}/http/alma9.ks.pkrtpl", {
      build_ssh_authorized_key = local.build_ssh_authorized_key
    })
  }
  boot_command = [
    "<up><wait>",
    "<tab><wait>",
    "<spacebar>",
    "console=ttyS0,115200",
    "<spacebar>",
    "rd.multipath=0 rd.iscsi=0 rd.znet=0 rd.fcoe=0 net.ifnames=0",
    "<spacebar>",
    "inst.cmdline inst.ks=http://10.0.2.2:{{.HTTPPort}}/alma9.ks",
    "<enter>",
  ]
  boot_wait = "10s"
  # The boot command is typed over VNC, which listens on 127.0.0.1 with no
  # password by default: any local user could type into the installer (and its
  # root shell on another console) before the image is sealed. The builder
  # generates a random password per build and sets it over a QMP socket in the
  # output directory, which build.sh keeps private.
  vnc_use_password = true

  communicator = "ssh"
  ssh_username = "ansible"
  # build.sh holds the build key in a private ssh-agent; there's no key file.
  ssh_agent_auth = true
  ssh_timeout    = "60m"

  # Builder options, not raw -machine/-cpu qemuargs: a raw -machine replaces the
  # builder's "-machine type=...,accel=..." and silently drops `accelerator`.
  machine_type = "q35"
  cpu_model    = "IvyBridge"
  qemuargs = [
    # The builder forwards the guest's SSH port on 0.0.0.0; keep it on loopback.
    ["-netdev", "user,id=user.0,hostfwd=tcp:127.0.0.1:{{ .SSHHostPort }}-:22"],
    # A per-build file rather than a fixed TCP port, so builds can run in
    # parallel. Follow the install with: tail -f output/<build>/serial.log
    ["-serial", "file:{{ .OutputDir }}/serial.log"],
    ["-display", "none"],
  ]

  cdrom_interface = "ide"
  net_device      = "virtio-net"

  disk_size          = "20480M"
  disk_interface     = "virtio-scsi"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true

  format           = "qcow2"
  output_directory = "output/alma_9_${local.build_id}"

  shutdown_command = "sudo systemctl poweroff"
  shutdown_timeout = "10m"
}

build {
  sources = ["source.qemu.alma9"]

  provisioner "file" {
    content     = <<-YAML
git_hash: "${var.git_hash}"
release: "${var.release}"
timestamp: "${local.timestamp}"
source: "${source.name}"
packer_version: "${packer.version}"
YAML
    destination = "/tmp/build_info.yaml"
  }

  provisioner "shell" {
    inline = [<<-EOC
set -eux -o pipefail
sudo install -m 600 /tmp/build_info.yaml /root/build_info.yaml
sudo ls -l /root/build_info.yaml
EOC
    ]
  }

  provisioner "shell" {
    execute_command = "{{ .Vars }} bash '{{ .Path }}'"
    script          = "${path.root}/scripts/check-guest-agent.sh"
  }

  provisioner "shell" {
    inline = [<<-EOC
set -eux -o pipefail
sudo install -d -m 0755 /tmp/build-evidence
sudo oscap xccdf eval \
  --fetch-remote-resources \
  --progress \
  --remediate \
  --results-arf /tmp/build-evidence/oscap_arf.xml \
  --report /tmp/build-evidence/oscap_report.html \
  --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
  /usr/share/xml/scap/ssg/content/ssg-almalinux9-ds.xml < /dev/null || true
EOC
    ]
  }

  # The CIS scan remounts /tmp noexec, so later scripts run via bash, not exec.
  provisioner "shell" {
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    script          = "${path.root}/scripts/check-sshd.sh"
  }

  # After the CIS scan, which can install packages too.
  provisioner "shell" {
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    script          = "${path.root}/scripts/check-signatures.sh"
  }

  provisioner "shell" {
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    script          = "${path.root}/scripts/check-cloud-init-users.sh"
  }

  provisioner "shell" {
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    script          = "${path.root}/scripts/collect-evidence.sh"
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/build-evidence/"
    destination = "output/alma_9_${local.build_id}/"
  }

  # Must stay last: everything above creates per-instance state.
  provisioner "shell" {
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    script          = "${path.root}/scripts/seal.sh"
  }

  post-processor "shell-local" {
    inline = [
      "cd output/alma_9_${local.build_id}",
      # vpc => vhd
      # see: https://docs.openstack.org/image-guide/convert-images.html
      "qemu-img convert -O vpc packer-alma9 alma_9_${local.build_id}.vhd",
      "{ sha256sum alma_9_${local.build_id}.vhd 2>/dev/null || shasum -a 256 alma_9_${local.build_id}.vhd; } > SHA256SUMS",
    ]
  }
}
