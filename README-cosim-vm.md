# Launching a VM + cosim for a given ROCm / AMDGPU driver / Linux kernel

This guide shows how to build and boot the QEMU + gem5 MI300X co-simulation with
a **specific** Linux kernel, amdgpu driver, and ROCm version, using the layered
disk orchestrator `scripts/cosim_vm.py`.

The guest disk is a qcow2 **backing chain** ordered by how often each piece
changes, so you only rebuild what you change:

```
base.qcow2          OS  (Ubuntu 24.04 + cosim infra)        — rarely
  └─ kernel.qcow2   Linux kernel + gem5_wmi.ko + vmlinux     — sometimes
       └─ driver.qcow2   amdgpu-dkms (built for the kernel)  — weekly
            └─ rocm[-asan].qcow2   ROCm user space           — nightly
                 └─ (per-run scratch overlay, auto-created)
```

Each run boots a throwaway scratch overlay, so the named layers stay pristine.

---

## 1. One-time prerequisites

- **gem5** built: `gem5/build/VEGA_X86/gem5.opt` (see `CLAUDE.md` → Build).
- **QEMU** built: `qemu/build/qemu-system-x86_64` and `qemu/build/qemu-img`.
- **gem5 run image**: `docker build -t gem5-run:local -f scripts/Dockerfile.run scripts/`
- **packer** fetched: `gem5-resources/src/x86-ubuntu-gpu-ml/packer`
  (run `gem5-resources/src/x86-ubuntu-gpu-ml/build.sh` once if missing).
- **libguestfs-tools** (only for the `therock-asan` ROCm source): `sudo apt-get install -y libguestfs-tools`
  (a guest kernel is auto-downloaded for it — no extra setup).
- **gh** authenticated (only for `therock-asan`): `gh auth status`.

> No system `qemu-system-x86_64` is required — the scripts use the in-tree
> `qemu/build`.

---

## 2. Pick your versions — edit `cosim-vm.json`

```jsonc
{
  "layers_dir": "gem5-resources/src/x86-ubuntu-gpu-ml/layers",
  "base":   { "ubuntu": "24.04.2" },
  "kernel": { "version": "6.8.0-79-generic" },          // Linux kernel
  "driver": { "amdgpu_repo_ver": "7.0" },               // amdgpu-dkms repo channel
  "rocm":   { "source": "apt", "version": "7.0" }        // ROCm user space
}
```

**ROCm source options:**

- Released ROCm from the radeon apt repo:
  ```json
  "rocm": { "source": "apt", "version": "7.0" }
  ```
- A TheRock CI **ASAN** build (auto-discovers the latest scheduled+main run, or
  pin one with `run_url`):
  ```json
  "rocm": {
    "source": "therock-asan",
    "amdgpu_family": "gfx94X-dcgpu",
    "tests": true,
    "run_url": "https://github.com/ROCm/TheRock/actions/runs/<RUN_ID>",
    "env": { "ASAN_OPTIONS": "detect_odr_violation=0:quarantine_size_mb=600" }
  }
  ```

Pinnable knobs: `driver.amdgpu_pkg_ver` (exact apt version), `rocm.therock_ref`
(install-tooling git ref), `rocm.components` (extra `install_rocm_from_artifacts.py`
flags), `rocm.env` (extra `/etc/environment` entries).

---

## 3. Build the disk chain

```sh
python3 scripts/cosim_vm.py status     # show which layers are built / stale
python3 scripts/cosim_vm.py build      # build only the changed layers + above
```

Change detection is by content fingerprint (each layer's config + its build
script + its template + its parent). So:

| You change in `cosim-vm.json` | Rebuilds |
|-------------------------------|----------|
| `rocm` (version / ASAN run)   | rocm only (~minutes) |
| `driver.amdgpu_repo_ver`      | driver + rocm |
| `kernel.version`              | kernel + driver + rocm |
| `base`                        | everything |

`qemu-img info --backing-chain <layer>.qcow2` shows the resulting chain.
qcow2 is sparse, so the host only stores bytes actually used.

> Already built layers by hand? `python3 scripts/cosim_vm.py adopt` registers
> them so they aren't rebuilt.

---

## 4. Launch the cosim

```sh
python3 scripts/cosim_vm.py launch
```

This creates a per-run scratch overlay on the top layer, selects the matching
`vmlinux-<kver>`, and boots QEMU + gem5. The guest auto-logs-in on the serial
console; the GPU is initialized by `cosim-gpu-setup.service`.

Pass extra `cosim_launch.sh` flags after `--`:

```sh
python3 scripts/cosim_vm.py launch -- --gem5-debug SDMAEngine
python3 scripts/cosim_vm.py launch -- --num-cus 40 --vram-size 16GiB
```

Inside the guest, verify:

```sh
rocminfo | grep -iE "Name:|xnack"     # expect gfx942 ... xnack+
ls /opt/rocm
```

The scratch overlay is removed automatically on exit; the named layers are
untouched and reusable.

---

## 5. Common commands

```sh
python3 scripts/cosim_vm.py status               # build state of each layer
python3 scripts/cosim_vm.py build --only rocm    # rebuild just one layer (+above)
python3 scripts/cosim_vm.py build --force        # rebuild everything
python3 scripts/cosim_vm.py clean --layer rocm   # remove a layer's output
python3 scripts/cosim_vm.py launch --no-build    # boot without auto-building stale layers
```

---

## 6. Notes & gotchas

- **vmlinux pairing:** the cosim boots an external kernel (`qemu -kernel`); the
  launcher always uses the `vmlinux-<kver>` emitted by the kernel layer, so it
  matches the in-disk modules. Don't mix them by hand.
- **Don't move `disk-image-*` dirs** after building — qcow2 records absolute
  backing paths. Use `qemu-img rebase` if you must relocate.
- **DKMS couples driver↔kernel:** a kernel bump forces the driver (and ROCm)
  layers to rebuild; this is automatic.
- **ASAN images are large** (full build ≈ 77 GB); the layer virtual size is
  200 GB. Host cost is only the actual used bytes (qcow2 sparse).
- Per-layer mechanics and variant builds: see
  `gem5-resources/src/x86-ubuntu-gpu-ml/layers/README.md`.
