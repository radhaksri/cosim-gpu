# Spike S4 — gfx942 VM-Fault Driver Contract (findings)

Purpose: capture the exact hardware contract the **unmodified** gfx942 amdgpu/KFD driver expects
for a recoverable VM fault, so gem5 (Phases 3–4 of `plan-xnack.md`) can conform to it. The driver
is the fixed point; gem5 must match these values.

Source of truth: the in-guest driver's own register headers,
`amdgpu-dkms .../amd/include/asic_reg/gc/gc_9_4_3_offset.h` and `gc_9_4_3_sh_mask.h`.
**MI300X is GC IP 9.4.3** (not 9.4.2). gem5's existing `MI300X_*` constants confirm this
(e.g. `MI300X_VM_INVALIDATE_ENG17_ACK = 0x08a6` == `regVM_INVALIDATE_ENG17_ACK` in gc_9_4_3).
Bitfield shifts are identical across 9.4.2/9.4.3; only register offsets differ.

## Status of this capture

| Part of contract | Status | Source |
|---|---|---|
| GC VML2 fault registers (offsets + fields) | **Verified** | `gc_9_4_3_*` headers (driver) |
| Retry-fault arming bit | **Verified** | `gc_9_4_3_sh_mask.h` |
| VM invalidate (retry trigger) registers | **Verified** | `gc_9_4_3_offset.h` |
| IH client IDs / fault source IDs | **Verified** | amdgpu-dkms 6.14.14 `soc15_ih_clientid.h`, `irqsrcs_vmc_1_0.h` |
| IV cookie layout read by ISR | **Verified** | amdgpu-dkms `soc15_int.h`, `gmc_v9_0.c:543-672` |
| Fault-address encoding | **Verified** | `gmc_v9_0.c:562-563` |

Driver sources obtained by extracting the exact in-guest driver package:
`amdgpu-dkms_6.14.14.30100000-2204008.24.04_all.deb` from
`repo.radeon.com/amdgpu/7.0/ubuntu` (matches the disk image's apt repo). Unpacked under
`../amdgpu-dkms-src/extracted/usr/src/amdgpu-6.14.14-2204008.24.04/` (outside the git repos).
gem5's existing `dev/amdgpu/interrupt_handler.hh` client-ID enum (RLC, SDMA0-7, GRBM_CP) is the
in-tree authority that already interoperates with the driver for CP/SDMA — extend it with the
values below.

## 1. GC VML2 fault registers (verified)

All are GC IP, SOC15 segment 0 (`*_BASE_IDX = 0`). Absolute MMIO byte address =
`<GC seg0 base> + offset*4` — gem5's `AMDGPUDevice` already decodes the GC aperture, so these must
be made readable there.

| Register | dword offset (gc_9_4_3 / MI300X) |
|---|---|
| `VM_L2_PROTECTION_FAULT_CNTL`  | `0x0827` |
| `VM_L2_PROTECTION_FAULT_STATUS`| `0x082b` |
| `VM_L2_PROTECTION_FAULT_ADDR_LO32` | `0x082c` |
| `VM_L2_PROTECTION_FAULT_ADDR_HI32` | `0x082d` |

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

### ADDR_LO32/HI32 — secondary (cookie is authoritative)
The modern ISR derives the fault address from the **IH cookie** (see §4:
`addr = (src_data[0]<<12) | ((src_data[1]&0xf)<<44)`), not from these registers. Populate the ADDR
registers with `(addr>>12)` low/hi for completeness/debug, but the cookie is what drives recovery.

## 2. Retry-fault arming (verified)

`VM_CONTEXT1_CNTL` (offset `0x0861`, seg 0) bit **7** =
`RETRY_PERMISSION_OR_INVALID_PAGE_FAULT`. When the driver sets this for the compute VMID context,
invalid-page faults become **retry** (recoverable) faults instead of fatal. Related fields:
`RANGE_PROTECTION_FAULT_ENABLE_DEFAULT` (shift 10), `DUMMY_PAGE_PROTECTION_FAULT_ENABLE_DEFAULT`
(shift 12), `PAGE_TABLE_BLOCK_SIZE` (shift 3). `VM_CONTEXT0_CNTL` = `0x0860`.

**gem5 implication:** only generate recoverable (park + interrupt + retry) faults when the driver
has set bit 7 on the relevant context's CNTL; otherwise preserve the existing fatal/non-retry
behavior. gem5 must therefore observe writes to `VM_CONTEXTn_CNTL`.

## 3. VM invalidate = the retry trigger (verified)

After the driver installs the PTE it issues a TLB invalidate; gem5 uses this as the
"re-walk parked translations now" signal (Phase 4). Engine 0 register set (seg 0):

| Register | dword offset (gc_9_4_3 / MI300X) |
|---|---|
| `VM_INVALIDATE_ENG0_SEM` | `0x0871` |
| `VM_INVALIDATE_ENG0_REQ` | `0x0883` |
| `VM_INVALIDATE_ENG0_ACK` | `0x0895` |
| `VM_INVALIDATE_ENG0_ADDR_RANGE_LO32` | `0x08a7` |
| `VM_INVALIDATE_ENG0_ADDR_RANGE_HI32` | `0x08a8` |

(gem5 already defines `MI300X_VM_INVALIDATE_ENG17_ACK = 0x08a6` = `0x0895 + 17`, confirming the
ENG stride and the gc_9_4_3 base.)

Engines are strided (ENG1 = ENG0 + 1 dword for REQ/ACK/SEM; ADDR_RANGE strided by 2). `REQ`
fields (shifts verified): `PER_VMID_INVALIDATE_REQ=0`, `FLUSH_TYPE=16`, `INVALIDATE_L2_PTES=18`,
`INVALIDATE_L1_PTES=22`. Driver writes `REQ`, polls `ACK`. **gem5 must: on `REQ` write →
invalidate PWC + matching TLB entries, re-run parked WalkerStates, then set `ACK`** so the driver's
poll completes.

## 4. IH interrupt cookie for a recoverable VM fault (verified)

### Client/source IDs the driver listens on (`gmc_v9_0.c:1959-1971`)
The driver registers three VM-fault sources:
| client_id | src_id | hub (in ISR) |
|---|---|---|
| `SOC15_IH_CLIENTID_VMC` = **0x12** | `VMC_1_0__SRCID__VM_FAULT` = **0** | mmhub0 |
| `SOC15_IH_CLIENTID_VMC1` (=PCIE0) | 0 | mmhub1 |
| `SOC15_IH_CLIENTID_UTCL2` = **0x1b** | `UTCL2_1_0__SRCID__FAULT` = **0** | **gfxhub0** |

**A compute-shader / GC-L2 fault (where ASAN shadow accesses fault) must use
`client_id = SOC15_IH_CLIENTID_UTCL2 (0x1b)`, `src_id = 0`** → the ISR's `else` branch attributes
it to gfxhub0 (`gmc_v9_0.c:571-580`). VMC (0x12) would be misrouted to MMHUB.

### IV wire entry = 8 dwords (`soc15_int.h:38-48`); decode maps `dword[4+i] → src_data[i]`
| dword | contents |
|---|---|
| `dw[0]` | `[7:0]`=client_id, `[15:8]`=src_id, `[23:16]`=ring_id, `[27:24]`=vmid, `[31]`=vmid_type |
| `dw[1],dw[2]` | timestamp |
| `dw[3]` | `[15:0]`=pasid, `[23:16]`=node_id |
| `dw[4]` = src_data[0] | `addr >> 12` (low 32 bits of faulting page) |
| `dw[5]` = src_data[1] | `[3:0]`=addr bits `[47:44]`; **bit 5 = write_fault**; **bit 7 = retry_fault** |
| `dw[6]` = src_data[2] | `[9:0]` = retry-CAM index (only if retry-CAM enabled) |
| `dw[7]` = src_data[3] | — |

### Decode logic (`gmc_v9_0.c:547-563,665-668`)
```
retry_fault = src_data[1] & 0x80      // bit 7  -> MUST be set for recoverable fault
write_fault = src_data[1] & 0x20      // bit 5
addr = ((u64)src_data[0] << 12) | (((u64)src_data[1] & 0xf) << 44)
// after the interrupt, driver also RREG32s VM_L2_PROTECTION_FAULT_STATUS for CID/RW/FED
```
On a retry fault the ISR calls `amdgpu_vm_handle_fault(pasid, vmid, node_id, addr, ts, write_fault)`
→ `svm_range_restore_pages` fills the page tables (the demand-paging fix), then a VM invalidate
(§3) is issued. So **gem5's cookie must carry the real faulting PASID and GPU VMID** (the current
`prepareInterruptCookie` hardcodes `pasid=0x8000` and zeroes vmId — both must be set correctly).

### gem5 work (Phase 3)
1. Extend `interrupt_handler.hh` client enum with `UTCL2=0x1b` (and `VMC=0x12`); add src_id 0;
   relax the asserts in `prepareInterruptCookie`.
2. Populate the cookie: client=0x1b, src=0, vmid=<faulting VMID>, pasid=<faulting PASID>,
   node_id=0 (single-AID), src_data[0]=addr>>12, src_data[1]=`(addrhi&0xf) | (write<<5) | (1<<7)`.
3. Also fill `VM_L2_PROTECTION_FAULT_STATUS` (§1) with matching VMID/RW/CID so the ISR's
   post-interrupt RREG32 is consistent.

### Runtime caveat to confirm (spike S1/S5)
`gmc_v9_0.c:584` branches on `adev->irq.retry_cam_enabled`. If the guest enables the retry-CAM,
the driver expects to write a CAM doorbell (`WDOORBELL32(retry_cam_doorbell_index, cam_index)`,
line 597) and reads `cam_index` from `src_data[2]`. Simplest for gem5 is the **non-CAM path**
(lines 600-620: filter + `amdgpu_vm_handle_fault` + delegate to soft ring 8). Confirm whether
gfx942 turns retry-CAM on in this driver build; if so, gem5 must supply a valid `src_data[2]`
index and honor the CAM doorbell.

## Phase mapping
- §1 STATUS/ADDR/CNTL registers → **Phase 3** (implement readable regs in `amdgpu_vm.*`).
- §2 retry arming → **Phase 3/4** (observe CNTL writes; gate recoverable faults).
- §3 invalidate → **Phase 4** (retry trigger + ACK).
- §4 IH IDs/cookie → **Phase 3** (now fully specified; no blockers).

S4 is complete: the full driver-facing contract is verified against the exact in-guest driver
(amdgpu-dkms 6.14.14). Only one runtime detail (retry-CAM on/off, §4 caveat) needs confirmation on
a booted cosim.
