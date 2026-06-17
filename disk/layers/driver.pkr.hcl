# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Driver overlay: amdgpu-dkms built for the underlying kernel layer, on top of a
# kernel qcow2. Output qcow2 backs onto the kernel layer image.

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
  default = "disk-image-kernel/kernel.qcow2"
}

variable "image_name" {
  type    = string
  default = "driver.qcow2"
}

variable "output_dir" {
  type    = string
  default = "disk-image-driver"
}

variable "amdgpu_repo_ver" {
  type    = string
  default = "7.0"
}

variable "amdgpu_pkg_ver" {
  type    = string
  default = ""
}

variable "kernel_version" {
  type    = string
  default = ""
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

source "qemu" "driver" {
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
  sources = ["source.qemu.driver"]

  provisioner "shell" {
    execute_command  = "echo '${var.ssh_password}' | {{ .Vars }} sudo -E -S bash '{{ .Path }}'"
    environment_vars = [
      "AMDGPU_REPO_VER=${var.amdgpu_repo_ver}",
      "AMDGPU_PKG_VER=${var.amdgpu_pkg_ver}",
      "KERNEL=${var.kernel_version}",
    ]
    scripts          = ["scripts/driver-install.sh"]
  }
}
