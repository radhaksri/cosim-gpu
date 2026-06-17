# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Base (backing) disk: Ubuntu 24.04 + version-INDEPENDENT cosim infrastructure.
# Output is a qcow2 used as the backing file for kernel/driver/ROCm overlays.
# This layer changes very rarely (only when the OS itself is bumped).

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "image_name" {
  type    = string
  default = "x86-ubuntu-2404-base.qcow2"
}

variable "ssh_password" {
  type    = string
  default = "12345"
}

variable "ssh_username" {
  type    = string
  default = "gem5"
}

# Defaults to the cosim's custom QEMU build (no system qemu is installed). The
# build script also puts qemu/build on PATH so packer finds qemu-img.
variable "qemu_path" {
  type    = string
  default = "/home/rsrimant/code/mi3xx-cosim/cosim-gpu/qemu/build/qemu-system-x86_64"
}

source "qemu" "base" {
  accelerator      = "kvm"
  boot_command     = ["e<wait>",
                      "<down><down><down>",
                      "<end><bs><bs><bs><bs><wait>",
                      "autoinstall  ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<wait>",
                      "<f10><wait>"
                    ]
  cpus             = "4"
  disk_size        = "200000"
  format           = "qcow2"
  headless         = "true"
  http_directory   = "http"
  iso_checksum     = "sha256:d6dab0c3a657988501b4bd76f1297c053df710e06e0c3aece60dead24f270b4d"
  iso_urls         = ["https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"]
  memory           = "8192"
  output_directory = "disk-image-base"
  qemu_binary      = "${var.qemu_path}"
  qemuargs         = [["-cpu", "host"], ["-display", "none"]]
  shutdown_command = "echo '${var.ssh_password}'|sudo -S shutdown -P now"
  ssh_password     = "${var.ssh_password}"
  ssh_username     = "${var.ssh_username}"
  ssh_wait_timeout = "60m"
  vm_name          = "${var.image_name}"
  ssh_handshake_attempts = "1000"
}

build {
  sources = ["source.qemu.base"]

  # Stage version-independent assets into the build user's home.
  provisioner "file" {
    destination = "/home/gem5/"
    source      = "../files/m5"
  }
  provisioner "file" {
    destination = "/home/gem5/"
    source      = "../files/serial-getty@.service"
  }
  provisioner "file" {
    destination = "/home/gem5/"
    source      = "../files/cosim-gpu-setup.sh"
  }
  provisioner "file" {
    destination = "/home/gem5/"
    source      = "../files/cosim-gpu-setup.service"
  }
  provisioner "file" {
    destination = "/home/gem5/"
    source      = "../files/load_amdgpu.sh"
  }
  provisioner "file" {
    destination = "/home/gem5/"
    source      = "../files/run_gem5_app.sh"
  }

  # Install base infra (tools, m5, services, firmware staging).
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -E -S bash '{{ .Path }}'"
    scripts         = ["scripts/base-install.sh"]
  }

  # Drop hardware-data blobs after base-install made the targets writable.
  provisioner "file" {
    destination = "/root/roms/"
    source      = "../files/mi200.rom"
  }
  provisioner "file" {
    destination = "/root/roms/"
    source      = "../files/mi300.rom"
  }
  provisioner "file" {
    destination = "/usr/lib/firmware/amdgpu/mi300_discovery"
    source      = "../files/mi300_discovery"
  }
  provisioner "file" {
    destination = "/usr/lib/firmware/amdgpu/mi350_discovery"
    source      = "../files/mi350_discovery"
  }
}
