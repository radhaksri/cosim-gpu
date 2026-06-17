# cosim — QEMU + gem5 MI300X Co-simulation

## Build

```bash
# Option A: script-based
./scripts/run_mi300x_fs.sh build-all
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..

# Option B: manual (build Docker image first — json-c + ccache live in the image)
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..
./scripts/build_gem5.sh                 # gem5.opt with ccache (persistent host cache)
# (./scripts/build_gem5.sh --stats to see ccache hit/miss; JOBS=N to cap parallelism)
cd qemu && mkdir -p build && cd build && ../configure --target-list=x86_64-softmmu && make -j$(nproc)
cd ../..
docker run --rm -v "$(pwd)/gem5:/gem5" -w /gem5 gem5-run:local \
    bash -c "cd util/m5 && scons build/x86/out/m5"
cp gem5/util/m5/build/x86/out/m5 disk/files/
./scripts/run_mi300x_fs.sh build-disk
```

Use `-j1` for gem5 linking if OOM-killed.

## Performance

- **CPU governor:** set `performance` (`sudo cpupower frequency-set -g performance`).
  gem5's GPU model is **single-threaded**, so simulation (and build) speed scales with
  single-core clock; `powersave` leaves ~15-20% on the table.
- **ccache:** enabled via `Dockerfile.run` + `build_gem5.sh` (persistent cache at
  `~/.cache/gem5-ccache`). Speeds up iterative gem5 rebuilds.
- **QEMU `-smp` does NOT speed up GPU tests.** gem5 (the GPU simulator) is the
  serial bottleneck; the guest CPU work is KVM-native and mostly idle waiting on
  the GPU. Adding guest vCPUs only helps guest-side CPU-parallel work, which
  rocrtst/hipblaslt are not. Expect ~2 host cores busy during a run (1 gem5 + 1 QEMU).
- For faster non-debug runs, a `gem5.fast` build (`scripts/build_gem5.sh
  build/VEGA_X86/gem5.fast`) is ~20-30% faster but strips DPRINTF traces — keep
  `gem5.opt` for debugging.

## Launch

```bash
./scripts/cosim_launch.sh                         # default
./scripts/cosim_launch.sh --gem5-debug MI300XCosim # with debug trace
```

After guest boots: driver auto-loads via `cosim-gpu-setup.service` (dd ROM + modprobe).
Manual: `dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128 && modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2`

## Architecture

QEMU (Q35+KVM) ←Unix socket→ gem5 (MI300X GPU model, no kernel).
Shared memory: `/dev/shm/cosim-guest-ram` (guest RAM) + `/dev/shm/mi300x-vram` (VRAM).
BAR layout: 0+1=VRAM, 2+3=Doorbell, 4=MSI-X, 5=MMIO.
Driver params: `ip_block_mask=0x67` (disable PSP+SMU), `ppfeaturemask=0 dpm=0 audio=0` (disable power-play/DPM/audio), `discovery=2` (firmware).

## Debugging

```bash
--gem5-debug MI300XCosim                          # cosim socket messages
--gem5-debug AMDGPUDevice,PM4PacketProcessor      # MMIO + PM4
--gem5-debug SDMAEngine                           # SDMA
--qemu-trace "mi300x_gem5_*"                      # QEMU trace events
docker logs gem5-cosim 2>&1 | tee /tmp/gem5.log   # gem5 logs
python3 scripts/cosim_test_client.py /tmp/gem5-mi300x.sock  # socket test
```

| Symptom | Fix |
|---------|-----|
| gem5 container exited | `docker logs gem5-cosim` (config error or OOM) |
| NULL deref in `amdgpu_atom_parse_data_header` | Must `dd` ROM to 0xC0000 before modprobe |
| KIQ disable timeout (-110) | Expected in cosim; harmless |
| DRM client -13 / EPERM | Rebuild disk image with latest gem5-resources |

## Commit Rules

- gem5: pre-commit hooks (clang-format, black, isort). Tags from `MAINTAINERS.yaml`.
- QEMU: checkpatch.pl (<90 chars).
- Top-level cosim: no hooks.
- Signed-off-by: derive from `git config user.name` and `git config user.email`.

## Documentation Rules

- All docs under `docs/` must have both `docs/zh/` and `docs/en/` versions.
- First line: `[English](../en/<file>.md)` or `[中文](../zh/<file>.md)`.
- When adding or modifying a doc, always update both language versions.
