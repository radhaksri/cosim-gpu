# Layered cosim disk images (base + kernel/driver/ROCm overlays)

> **Recommended entry point:** the orchestrator `cosim-gpu/scripts/cosim_vm.py`
> reads a JSON manifest (`cosim-gpu/cosim-vm.json`), fingerprints each layer, and
> rebuilds only what changed (plus descendants). The `build-*.sh` scripts below
> are the per-layer mechanics it drives; you can also run them by hand.
>
> ```sh
> python3 scripts/cosim_vm.py status     # what's built / stale
> python3 scripts/cosim_vm.py build      # bring chain up to date
> python3 scripts/cosim_vm.py launch     # per-run scratch overlay + boot cosim
> python3 scripts/cosim_vm.py adopt      # register already-built layers (no rebuild)
> ```
>
> **ROCm ASAN layer (host-side):** when the manifest's `rocm.source` is
> `therock-asan`, the ROCm layer is built **on the host** by `build-rocm-asan.sh`,
> NOT via packer: it auto-discovers the latest scheduled+main+success run of
> TheRock's `multi_arch_ci_asan.yml` (override with `rocm.run_url`), fetches it
> with `install_rocm_from_artifacts.py` (host `gh` auth + `boto3`), then injects
> the ROCm tree + env into a qcow2 overlay with **libguestfs** (`virt-customize`,
> offline — needs `sudo apt-get install -y libguestfs-tools`). This avoids putting
> the host's GitHub token / AWS creds / corporate CA inside a throwaway guest.
> Extra ASAN env from the wiki goes in `rocm.env` (a `{KEY:VALUE}` map merged into
> `/etc/environment`; `HSA_XNACK=1`, `ROCM_PATH`, `LD_LIBRARY_PATH`, `PATH` are set
> by default). `DRY_RUN=1 ./build-rocm-asan.sh` validates the fetch only.


A qcow2 backing chain that decouples the four things that change at very
different rates, so the gem5/QEMU cosim works irrespective of guest versions:

```
base.qcow2            OS  — changes very rarely (Ubuntu 24.04 + version-independent cosim infra)
  └─ kernel-<kver>    kernel — frequent   (linux-image/headers/modules-extra + gem5_wmi.ko + vmlinux)
       └─ driver-<dver>   amdgpu driver — weekly   (amdgpu-dkms built for <kver>)
            └─ rocm-<rver>     ROCm — nightly   (ROCm user space + HSA_XNACK; thin overlay)
                 └─ run-scratch  per cosim run (deltas stay pristine)
```

Ordered by change frequency (least-frequent at the bottom = backing). This also
matches the hard dependency order, since the cosim boots an **external** kernel
(`qemu -kernel <vmlinux> root=/dev/vda1`): the `vmlinux` you boot and the kernel
modules in the disk (amdgpu.ko via DKMS, gem5_wmi.ko) **must be the same
version**. Each kernel layer therefore emits a paired `vmlinux-<kver>` next to
its qcow2 — that is the file the launcher must boot for that chain.

## Build order

```sh
# 0) one-time: fetch packer (writes ../packer)
( cd .. && ./build.sh --help >/dev/null 2>&1 || true )   # or just run build-base.sh which checks

# 1) base (OS) — rarely
./build-base.sh

# 2) kernel layer
./build-layer.sh kernel -var kernel_version=6.8.0-79-generic

# 3) driver layer (built for the kernel above)
./build-layer.sh driver -var amdgpu_repo_ver=7.0 -var kernel_version=6.8.0-79-generic

# 4) ROCm layer (nightly)
./build-layer.sh rocm -var rocm_ver=7.0
```

## Variants (vary one axis, reuse the rest)

Each layer defaults `input_image` to the previous layer's default output. To keep
several variants side by side, set `input_image`/`output_dir` explicitly:

```sh
# A second ROCm version on the same driver layer:
./build-layer.sh rocm \
  -var rocm_ver=7.1 \
  -var input_image=disk-image-driver/driver.qcow2 \
  -var output_dir=disk-image-rocm-7.1 \
  -var image_name=rocm-7.1.qcow2

# A second driver on the same kernel:
./build-layer.sh driver \
  -var amdgpu_repo_ver=7.1 -var kernel_version=6.8.0-79-generic \
  -var input_image=disk-image-kernel/kernel.qcow2 \
  -var output_dir=disk-image-driver-7.1 -var image_name=driver-7.1.qcow2
```

## Notes / gotchas

- **Custom QEMU**: there is no system `qemu-system-x86_64`; the build scripts put
  `cosim-gpu/qemu/build` on PATH so packer finds both `qemu-system-x86_64` and
  `qemu-img`.
- **Backing-file paths are recorded at build time.** Do not move/rename a lower
  layer's qcow2 after building an overlay on it (qcow2 stores the backing path).
  Keep the `disk-image-*` directories in place. Use `qemu-img info <overlay>` to
  inspect the chain; `qemu-img rebase` to repoint if you must move things.
- **DKMS couples driver↔kernel**: a new kernel layer requires rebuilding the
  driver (and ROCm) layers above it. Driver layer builds the module explicitly
  for the kernel layer's version (`/etc/cosim-kernel-version`), not just the
  provisioning kernel.
- **Version markers** written into the image for the launcher to read:
  `/etc/cosim-kernel-version`, `/etc/cosim-amdgpu-version`, `/etc/cosim-rocm-version`.
- **Per-run scratch**: the cosim launcher creates a throwaway qcow2 overlay on
  the chosen rocm layer for each run, so named layers stay pristine and reusable.
