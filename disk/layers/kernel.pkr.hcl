# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Kernel overlay: a specific Linux kernel + gem5_wmi.ko, on top of the base
# backing disk. Output is a qcow2 whose backing file is the base image. The
# extracted vmlinux is downloaded out next to the qcow2 and must be paired with
# this layer when launching cosim.

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "input_image" {
  type    = string
  default = "disk-image-base/x86-ubuntu-2404-base.qcow2"
}

variable "image_name" {
  type    = string
  default = "kernel.qcow2"
}

variable "output_dir" {
  type    = string
  default = "disk-image-kernel"
}

variable "kernel_version" {
  type    = string
  default = "6.8.0-79-generic"
}

variable "ssh_password" {
  type    = string
  default = "12345"
}

variable "ssh_username" {
  type    = string
  default = "gem5"
}

variable "qemu_path" {
  type    = string
  default = "/home/rsrimant/code/mi3xx-cosim/cosim-gpu/qemu/build/qemu-system-x86_64"
}

source "qemu" "kernel" {
  accelerator      = "kvm"
  disk_image       = true
  use_backing_file = true
  format           = "qcow2"
  # Must match the base virtual size (200000 MiB) so packer does not shrink the
  # overlay and truncate the root partition.
  disk_size        = "200000"
  iso_url          = "${var.input_image}"
  iso_checksum     = "none"
  cpus             = "4"
  memory           = "8192"
  headless         = "true"
  output_directory = "${var.output_dir}"
  qemu_binary      = "${var.qemu_path}"
  qemuargs         = [["-cpu", "host"], ["-display", "none"]]
  shutdown_command = "echo '${var.ssh_password}'|sudo -S shutdown -P now"
  ssh_password     = "${var.ssh_password}"
  ssh_username     = "${var.ssh_username}"
  ssh_wait_timeout = "30m"
  vm_name          = "${var.image_name}"
  ssh_handshake_attempts = "1000"
}

build {
  sources = ["source.qemu.kernel"]

  # gem5_wmi module sources, built against the target kernel by the script.
  provisioner "file" {
    destination = "/home/gem5/"
    source      = "../files/gem5_wmi"
  }

  provisioner "shell" {
    execute_command   = "echo '${var.ssh_password}' | {{ .Vars }} sudo -E -S bash '{{ .Path }}'"
    environment_vars  = ["KERNEL=${var.kernel_version}"]
    scripts           = ["scripts/kernel-install.sh"]
  }

  # Pull the extracted vmlinux out next to the qcow2 (paired with this layer).
  provisioner "file" {
    direction   = "download"
    source      = "/home/gem5/vmlinux-${var.kernel_version}"
    destination = "${var.output_dir}/vmlinux-${var.kernel_version}"
  }
}
