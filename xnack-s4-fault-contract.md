# Spike S4 — gfx942 VM-Fault Driver Contract (findings)

Purpose: capture the exact hardware contract the **unmodified** gfx942 amdgpu/KFD driver expects
for a recoverable VM fault, so gem5 (Phases 3–4 of `plan-xnack.md`) can conform to it. The driver
is the fixed point; gem5 must match these values.

Source of truth used here: `TheRock/rocm-systems/.../aqlprofile/linux/registers/gc/gc_9_4_2_offset.h`
and `gc_9_4_2_sh_mask.h` (the gfx942 GC register definitions present in the clone).

## Status of this capture

| Part of contract | Status | Source |
|---|---|---|
| GC VML2 fault registers (offsets + fields) | **Verified locally** | `gc_9_4_2_*` headers |
| Retry-fault arming bit | **Verified locally** | `gc_9_4_2_sh_mask.h` |
| VM invalidate (retry trigger) registers | **Verified locally** | `gc_9_4_2_offset.h` |
| IH client IDs / fault source IDs | **NOT in clone** — need Linux amdgpu tree | `soc15_ih_clientid.h`, `soc15_int.h` |
| IV cookie `src_data` layout read by ISR | **NOT in clone** — need `gmc_v9_0.c` | kernel `gmc_v9_0_process_interrupt` |
| Fault-address encoding in ADDR_LO32/HI32 | **Inferred** (standard gfx9) — confirm vs `gmc_v9_0.c` | — |

The amdgpu kernel driver C sources are **not** present in the clones (only register headers via
rocprofiler-sdk). gem5's existing `dev/amdgpu/interrupt_handler.hh` client-ID enum (RLC, SDMA0-7,
GRBM_CP) is the in-tree authority that already interoperates with the driver for CP/SDMA
interrupts — extend it using the kernel's `soc15_ih_clientid.h` values.

## 1. GC VML2 fault registers (verified)

All are GC IP, SOC15 segment 0 (`*_BASE_IDX = 0`). Absolute MMIO byte address =
`<GC seg0 base> + offset*4` — gem5's `AMDGPUDevice` already decodes the GC aperture, so these must
be made readable there.

| Register | dword offset |
|---|---|
| `VM_L2_PROTECTION_FAULT_CNTL`  | `0x0847` |
| `VM_L2_PROTECTION_FAULT_CNTL2` | `0x0848` |
| `VM_L2_PROTECTION_FAULT_STATUS`| `0x084b` |
| `VM_L2_PROTECTION_FAULT_ADDR_LO32` | `0x084c` |
| `VM_L2_PROTECTION_FAULT_ADDR_HI32` | `0x084d` |

### STATUS bitfields (shifts verified; widths standard gfx9)
| Field | shift | width |
|---|---|---|
| `MORE_FAULTS` | 0 | 1 |
| `WALKER_ERROR` | 1 | 3 |
| `PERMISSION_FAULTS` | 4 | 4 |
| `MAPPING_ERROR` | 8 | 1 |
| `CID` (client id) | 9 | 8 |
| `RW` (0=read,1=write) | 18 | 1 |
| `VMID` | 20 | 4 |
| `FED` | 30 | 1 |

gem5 must populate STATUS with the faulting VMID/RW/CID and the appropriate error bit when it
raises the fault, then the driver reads it in its ISR.

### CNTL — which fault types raise an interrupt (enable bits, shifts verified)
`RANGE_PROTECTION...=2`, `PDE0_PROTECTION...=3`, `TRANSLATE_FURTHER...=6`,
`DUMMY_PAGE_PROTECTION...=8`, `VALID_PROTECTION_FAULT_ENABLE_DEFAULT=9`.
A "PTE not present" demand-paging fault is a **VALID** protection fault (bit 9). gem5 should only
generate the interrupt for the fault classes the driver has enabled in CNTL.

### ADDR_LO32/HI32 (encoding inferred — confirm against `gmc_v9_0.c`)
Standard gfx9: the faulting address is reported page-shifted (`>>12`); LO32 holds the low 32 bits
of `(addr>>12)`, HI32 the upper bits. The kernel reconstructs `addr = ((u64)hi32<<32 | lo32)<<12`.
**Confirm the exact shift/packing in `gmc_v9_0_process_interrupt` before implementing.**

## 2. Retry-fault arming (verified)

`VM_CONTEXT1_CNTL` (offset `0x0881`, seg 0) bit **7** =
`RETRY_PERMISSION_OR_INVALID_PAGE_FAULT`. When the driver sets this for the compute VMID context,
invalid-page faults become **retry** (recoverable) faults instead of fatal. Related fields:
`RANGE_PROTECTION_FAULT_ENABLE_DEFAULT` (shift 10), `DUMMY_PAGE_PROTECTION_FAULT_ENABLE_DEFAULT`
(shift 12), `PAGE_TABLE_BLOCK_SIZE` (shift 3). `VM_CONTEXT0_CNTL` = `0x0880`.

**gem5 implication:** only generate recoverable (park + interrupt + retry) faults when the driver
has set bit 7 on the relevant context's CNTL; otherwise preserve the existing fatal/non-retry
behavior. gem5 must therefore observe writes to `VM_CONTEXTn_CNTL`.

## 3. VM invalidate = the retry trigger (verified)

After the driver installs the PTE it issues a TLB invalidate; gem5 uses this as the
"re-walk parked translations now" signal (Phase 4). Engine 0 register set (seg 0):

| Register | dword offset |
|---|---|
| `VM_INVALIDATE_ENG0_SEM` | `0x0891` |
| `VM_INVALIDATE_ENG0_REQ` | `0x08a3` |
| `VM_INVALIDATE_ENG0_ACK` | `0x08b5` |
| `VM_INVALIDATE_ENG0_ADDR_RANGE_LO32` | `0x08c7` |
| `VM_INVALIDATE_ENG0_ADDR_RANGE_HI32` | `0x08c8` |

Engines are strided (ENG1 = ENG0 + 1 dword for REQ/ACK/SEM; ADDR_RANGE strided by 2). `REQ`
fields (shifts verified): `PER_VMID_INVALIDATE_REQ=0`, `FLUSH_TYPE=16`, `INVALIDATE_L2_PTES=18`,
`INVALIDATE_L1_PTES=22`. Driver writes `REQ`, polls `ACK`. **gem5 must: on `REQ` write →
invalidate PWC + matching TLB entries, re-run parked WalkerStates, then set `ACK`** so the driver's
poll completes.

## 4. Still required from the Linux amdgpu tree (S4 follow-up)

Obtain these small headers/functions from the in-guest driver version (the apt `amdgpu-dkms`
built from the kernel; matches the disk image's ROCm 7.0 / kernel 6.8.0-79):

1. `soc15_ih_clientid.h` → `SOC15_IH_CLIENTID_VMC`, `_VMC1`, `_UTCL2` (the client IDs gem5's IH
   cookie must carry; extend `interrupt_handler.hh`).
2. Fault **source IDs** (e.g. `VMC_1_0__SRCID__VM_FAULT`) the ISR matches on.
3. `gmc_v9_0_process_interrupt` (`drivers/gpu/drm/amd/amdgpu/gmc_v9_0.c`) → the exact IV
   `src_data[0/1]` fields it reads (fault status + address packing) and which hub it attributes the
   fault to (GC VML2 vs MMHUB). This defines the cookie `source_data_dw*` gem5 must fill in
   `prepareInterruptCookie`.
4. Confirm the ADDR register encoding (§1) and the per-context retry arming sequence (§2).

These cannot be guessed without breaking the unmodified-driver constraint — they gate Phase 3
cookie population and Phase 4 fault attribution. Recommended: copy these four items out of the
exact kernel source the guest runs, or capture them live via MMIO/IH tracing in spikes S1/S5.

## Phase mapping
- §1 STATUS/ADDR/CNTL registers → **Phase 3** (implement readable regs in `amdgpu_vm.*`).
- §2 retry arming → **Phase 3/4** (observe CNTL writes; gate recoverable faults).
- §3 invalidate → **Phase 4** (retry trigger + ACK).
- §4 IH IDs/cookie → **Phase 3** (blocked on kernel headers).
