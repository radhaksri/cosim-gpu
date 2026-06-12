# Enabling `gfx942:xnack+` in MI300X Co-simulation for ROCm ASAN

## Goal Description

Enable the simulated MI300X (gfx942) GPU in the QEMU + gem5 co-simulation to advertise and
functionally support `xnack+` (replayable / recoverable GPU page faults), so that
AddressSanitizer-instrumented ROCm/HIP builds can be run and validated under simulation.

### Hard Constraint: Unmodified Release Driver/Runtime

**The same release amdgpu kernel driver and ROCm user-space stack must work against the
simulated MI300 PCIe device, unmodified.** We may change:

- the gem5 GPU model (`gem5/src/...`),
- the QEMU cosim device (`qemu/hw/misc/mi300x_gem5.c`),
- the cosim socket protocol (both sides, kept in sync),
- guest **environment variables** (`HSA_XNACK`, target strings),
- the **firmware/discovery blob** (`mi300_discovery` / `ip_discovery.bin`) — this is hardware
  data, not driver code.

We may **NOT** patch amdgpu/KFD or the ROCm runtime. Consequence: every hardware-facing
contract the simulator presents — VM-fault register offsets, IH client/source IDs, interrupt
cookie layout, VM-invalidate registers, discovery capability bits — **must match exactly what
the stock gfx942 driver already expects**, as defined in the cloned ROCm kernel sources. This
makes the Phase 0 "contract capture" spikes decision-critical: the driver is the fixed point,
and gem5 must conform to it.

## Background: Why xnack+ Is Mandatory for ASAN (not optional)

Established from study of `TheRock/compiler/amd-llvm`:

1. **ASAN detection is software, but its memory layout forces hardware faults.** The
   instrumentation pass emits software shadow-byte checks (`llvm/lib/Transforms/Instrumentation/
   AddressSanitizer.cpp:1984-1993`; shadow scale=3, offset `0x7fff8000`). The shadow region is
   **host-resident**; device code dereferences it in `__global` address space
   (`amd/device-libs/asanrtl/inc/shadow_mapping.h:24`). Every instrumented access loads a shadow
   byte from host memory, so the **first touch of each shadow page takes a recoverable page
   fault serviced by HMM/SVM demand paging — during correct execution, on every kernel launch.**
   Therefore "advertise xnack+ but avoid faults" is impossible; the GPU faults on the first
   shadow load.

2. **Clang hard-requires xnack+ for ASAN.** `clang/lib/Driver/ToolChains/AMDGPU.h:279`:
   *"The xnack+ feature is only required for ASan on AMDGPU."* Enforced in
   `AMDGPU.cpp:1182-1217`.

3. **The compiler guarantees the faulting access is safely replayable.** With xnack+, LLVM forms
   *restartable* memory clauses: pointer live-ranges extended with `@earlyclobber`
   (`SIFormMemoryClauses.cpp:9-14`), `_ec` early-clobber load variants selected
   (`SILoadStoreOptimizer.cpp:1885-1959`), RAW-within-clause forbidden
   (`GCNHazardRecognizer.cpp:708-725`), `s[104:105]` (XNACK_MASK) reserved
   (`SIRegisterInfo.cpp:623-624`). The hardware contract (`AMDGPUUsage.rst:817-828`): on a page
   fault the faulting instruction/clause is **re-issued from scratch**; source registers are
   guaranteed intact.

4. **Error reporting + device malloc use hostcall, not faults.** `__ockl_sanitizer_report` →
   `__ockl_hostcall_preview(SERVICE_SANITIZER)` over a shared-memory ring; host handler in CLR
   `rocclr/device/devsanitizer.hpp`. Hostcall buffers are also host-resident → also exercise
   demand paging.

### Key Architectural Decision: Replay at the Translation Layer

Because the compiler guarantees source registers survive replay (point 3), we do **not** cancel
and re-issue the memory instruction through the compute pipeline. Instead we **park the in-flight
translation** at the page-table walker and **re-walk it** once the driver installs the PTE,
then deliver the (now-successful) translation response to the still-waiting memory instruction.
The wavefront simply waits on `vmcnt`, which gem5 already models. This avoids building a
wavefront-level replay state machine and is the central risk reduction of this plan.

```
WF mem instr → TLB miss → page-table walk → PTE not present
   ├─ populate VM_L2_PROTECTION_FAULT_{STATUS,ADDR,CNTL}  (VMID, GPA, RW) [HW-faithful offsets]
   ├─ push IH cookie (VMC/UTCL2 client) → IH ring in GUEST RAM → MSI-X → guest
   └─ PARK the WalkerState; do NOT send translation response      (WF waits on vmcnt)
                         │
   stock amdgpu/KFD: gmc_v9_0_process_interrupt → svm_range_restore_pages
                     → writes PTE into GPU page tables (VRAM shmem) → VM_INVALIDATE MMIO
                         │
   on VM_INVALIDATE MMIO write: flush PWC/TLB, re-run parked WalkerState
                         │
   walk finds PTE → translation response delivered → access completes → vmcnt decrements
```

## Current-State Gap Summary

| Layer | Current state | Evidence |
|-------|---------------|----------|
| GPU fault handling | Panic (SE) / silent sink to paddr=0 (cosim) — no recovery | `arch/amdgpu/vega/faults.cc:47`; `pagetable_walker.cc:213-222`; `amdgpu_vm.cc:587` |
| Translation replay | No park/re-walk; walker returns or sinks | `pagetable_walker.cc` |
| Interrupt path gem5→QEMU→guest | Works for CP_EOP/SDMA: IH→`intrPost`→`sendIrqRaise`(0x82)→`msix_notify` | `interrupt_handler.cc:68-72`; `amdgpu_device.cc:888-897`; `mi300x_gem5.c:197-216` |
| **IH ring DMA in cosim** | Suspect: writes via gem5 `DmaDevice` port → gem5 memory, not guest RAM; `cosimBridge->sendDmaWrite()` exists but unused by IH | `interrupt_handler.cc:152-168` vs `mi300x_gem5_cosim.cc:852-880` |
| VM fault registers | Absent (`VM_L2_PROTECTION_FAULT_*`); no VMC/UTCL2 IH client/source IDs; `prepareInterruptCookie` asserts & zeroes vmId | `interrupt_handler.cc:81-118` |
| xnack advertising | Nothing sets `HSA_XNACK`/`gfx942:xnack+`; relies on real KFD parsing `mi300_discovery` | grep: zero hits; `cosim-gpu-setup.sh` |
| PWC invalidation | `invalidatePWC()` exists, never called on remap | `pagetable_walker.cc:514-521` |

---

## Phase 0 — Spikes / Prototypes to Resolve Unknowns

Phase 0 is **investigation + throwaway prototypes only**. Each spike resolves one unknown and
produces a deterministic, recorded artifact (a measured yes/no, an exact offset table, or a
working proof). No production code is committed in Phase 0. Spikes are ordered by dependency;
several can run in parallel.

> Note on "throwaway": spike branches/patches are for learning. The deterministic *output*
> (tables, decisions, captured traces) is what carries into Phases 1–6.

### Spike S1 — Interrupt round-trip (settles the IH-DMA-to-guest-RAM unknown)
- **Unknown:** Does *any* GPU interrupt currently reach the stock guest driver, or does the IH
  ring DMA land in gem5 memory instead of `/dev/shm/cosim-guest-ram`?
- **Method:** Boot current cosim, run a trivial kernel that completes (CP_EOP). Trace with
  `--gem5-debug AMDGPUInterruptHandler,MI300XCosim`. Instrument (throwaway) the IH `dmaWrite`
  target address and compare against the guest IH ring base (`IH_RB_BASE` MMIO captured from the
  driver). Check guest `/proc/interrupts` and IH `RPTR` advancement.
- **Deterministic output:** (a) interrupts reach guest: yes/no; (b) if no, the exact address the
  cookie/wptr landed at vs. the guest ring base, confirming whether Phase 2 must reroute IH DMA
  through `cosimBridge->sendDmaWrite()`.

### Spike S2 — xnack+ capability reporting through the stock stack
- **Unknown:** With `HSA_XNACK=1`, does the unmodified KFD/runtime report the agent as
  `gfx942:xnack+`, given the current `mi300_discovery` blob?
- **Method:** Boot with `HSA_XNACK=1` exported; capture `rocminfo` and
  `cat /sys/class/kfd/kfd/topology/nodes/*/properties` (the `capability` field). Attempt to load
  a `gfx942:xnack+` code object and record the loader's accept/reject decision.
- **Deterministic output:** (a) advertised target string; (b) the `capability` bitfield value;
  (c) whether the blob already suffices or a patch is required (feeds S3).

### Spike S3 — Discovery-blob capability decode
- **Unknown:** If S2 shows xnack capability missing, *which exact field/byte* of
  `mi300_discovery` / `ip_discovery.bin` must change, per the stock driver's parser?
- **Method:** Read the discovery parser in the cloned ROCm kernel sources (amdgpu `discovery.c`,
  `amdgpu_discovery.c`, the GC/HARVEST table structs) to map blob layout → derived capability.
  Hexdump the blob; correlate. Cross-check against KFD's capability derivation
  (`kfd_topology.c`, `HSA_CAP_*`).
- **Deterministic output:** Either "blob already advertises xnack+ → no change" or an exact
  byte/field patch spec that the stock parser will honor (no driver change).

### Spike S4 — Stock-driver fault contract capture (most decision-critical)
- **Unknown:** The exact hardware contract the unmodified gfx942 driver expects for a recoverable
  VM fault — register offsets, IH client/source IDs, cookie field layout, and invalidate
  registers. gem5 must match these precisely.
- **Method:** From the cloned ROCm kernel sources, extract for gfx942/aldebaran:
  - `VM_L2_PROTECTION_FAULT_STATUS / _ADDR_LO32 / _ADDR_HI32 / _CNTL` register offsets and bit
    layout (`gmc_v9_0.c`, `gc/gc_9_4_*` register headers).
  - The IH interrupt entry fields `gmc_v9_0_process_interrupt` reads (client_id, source_id,
    vmid, pasid, ring fault address composition) and the VMC/UTCL2 client IDs
    (`soc15_ih_clientid.h`: `SOC15_IH_CLIENTID_VMC`=0x12, `VML2`=0x1f) and source IDs.
  - `VM_INVALIDATE_ENG*_REQ/_ACK/_ADDR_RANGE` register offsets (the retry trigger).
  - Whether/how KFD arms **retry** faults vs no-retry for the compute VMID (the register writes
    that select retry mode), since recoverable faults only occur in retry mode.
- **Deterministic output:** A reference table (offsets, IDs, bitfields, cookie layout) that
  Phases 3–4 implement verbatim. This is the contract gem5 conforms to.

### Spike S5 — Park-and-retry feasibility microspike in gem5 (settles core risk R1)
- **Unknown:** Can the translation-layer park/re-walk mechanism work in gem5's timing model
  without deadlock or violating coalescer/outstanding-request assumptions?
- **Method:** Throwaway gem5 patch: on a translation fault, instead of sink/panic, **delay** the
  `WalkerState` by N ticks and re-walk **once** against a pre-planted PTE (no driver/interrupt
  involvement). Verify `invalidatePWC()` + TLB flush + delivering the late translation response
  lets the waiting wavefront resume on `vmcnt` and the kernel completes correctly.
- **Deterministic output:** Proof that park→re-walk→resume is viable (or a list of concrete
  blockers in the coalescer/CU accounting to fix before Phase 4).

### Spike S6 — xnack+ code-object execution compatibility
- **Unknown:** Does gem5 correctly decode/execute real `gfx942:xnack+` code objects (the `_ec`
  early-clobber opcodes, reserved `s[104:105]`)?
- **Method:** Compile a trivial kernel `--offload-arch=gfx942:xnack+`; run under current cosim
  with all memory pre-resident (no faults). Diff disassembly against the xnack- build; confirm
  gem5 executes without illegal-instruction/decoder errors.
- **Deterministic output:** gem5 ISA compatibility yes/no + a list of any missing opcode handlers.

### Spike S7 — Hostcall round-trip (ASAN reporting + device malloc dependency)
- **Unknown:** Does the hostcall mechanism (`SERVICE_SANITIZER`, device printf) function in cosim
  with the stock runtime?
- **Method:** Run a kernel using device `printf` (and, if available, a minimal sanitizer-report
  path) with memory pre-resident; confirm the host receives the payload.
- **Deterministic output:** hostcall works yes/no; if no, the failing stage (buffer setup vs
  doorbell vs demand-paging of the buffer — the last would be unblocked by Phase 4).

### Spike S8 — PTE write-path coherence probe
- **Unknown:** When KFD services a fault (`svm_range_restore_pages`), does its PTE write reach
  the same `vramShmem` the gem5 walker reads, and via which path (SDMA vs CPU/HDP)?
- **Method:** From kernel sources, identify the PTE-update path used on SVM fault restore. In
  cosim, force a fault (using S5 infra or a deliberate unmapped access) and trace where the PTE
  write lands (`--gem5-debug SDMAEngine,AMDGPUDevice`), comparing the target against
  `pagetable_walker.cc:443-472` read addresses.
- **Deterministic output:** Confirmation that walker reads observe driver PTE writes (coherent),
  or the specific bridging needed in Phase 5.

### Phase 0 Exit Criteria
- S1, S2 answered (interrupt delivery status; xnack reporting status).
- S3 produces a concrete blob decision (no-change or exact patch).
- S4 produces the complete stock-driver fault-contract table.
- S5 proves (or scopes) the park/re-walk mechanism.
- S6, S7, S8 answered.
- A short findings note recorded; Phases 1–6 are re-scoped against these deterministic results
  before any production code is written.

---

## Phase 1 — Advertise xnack+ (env + discovery, no driver changes)
1. `gem5-resources/src/x86-ubuntu-gpu-ml/files/cosim-gpu-setup.sh` and
   `scripts/cosim_guest_setup.sh`: `export HSA_XNACK=1`; set `HCC_AMDGPU_TARGET=gfx942:xnack+`.
2. If S2/S3 require it, patch `mi300_discovery` per S3's exact spec (firmware data only).
3. **Gate:** `rocminfo` shows `gfx942:xnack+`; a trivial xnack+ kernel with pre-resident memory
   runs to completion (builds on S6).

## Phase 2 — Interrupt delivery to guest RAM — **NOT NEEDED (verified)**
**Original premise was a misdiagnosis.** The IH writes the cookie/wptr via gem5's `DmaDevice`
port (`interrupt_handler.cc:148,165`). That port (`device_ih`) is wired through
`system._dma_ports` → `system.ruby.create(...)` into gem5's system memory
(`configs/example/gpufs/mi300_cosim.py:257,272,405`), and that memory is
`system.shared_backstore = /cosim-guest-ram` with `auto_unlink_shared_backstore = True`
(`mi300_cosim.py:321-322`) — i.e. gem5's system RAM is mmap-backed by the **same** shmem QEMU
exposes as guest RAM, with matching mem_ranges. So `dmaWrite(guest_phys)` already lands in
guest-visible RAM; CP_EOP/SDMA interrupts work through this path today, and Phase 3's VM-fault
cookie will use the same working path with no DMA plumbing changes.

The bridge's `sendDmaWrite()`/`sendDmaRead()` (0x85/0x84) are unused dead code; `DmaReq` (0x05)
only services VRAM. None of that is on the interrupt path — do not reroute the IH through it.

**Residual check (cheap, runtime):** when a cosim is next booted, confirm guest
`/proc/interrupts` increments / IH `RPTR` advances on a CP_EOP, to validate by observation what is
here established by construction. This is the only remnant of old spike S1.

## Phase 3 — VM-fault registers + IH plumbing in gem5 (conform to S4 contract)
1. Implement `VM_L2_PROTECTION_FAULT_CNTL/STATUS/ADDR_LO32/HI32` in `amdgpu_vm.*` at the **exact
   offsets/bit layout from S4**, readable via the MMIO path; populate VMID/GPA/RW on fault.
2. Add the VMC/UTCL2 IH client + page-fault source IDs from S4; relax the asserts and populate
   `vmId`/`source_data` in `prepareInterruptCookie` (`interrupt_handler.cc:81-118`) to the cookie
   layout the stock `gmc_v9_0_process_interrupt` reads.
3. If S4 shows the driver must explicitly arm retry mode, ensure gem5 honors those register
   writes (retry vs no-retry) before generating recoverable faults.
4. **Gate:** a deliberately faulted access produces a guest-visible interrupt that the stock KFD
   ISR parses with correct address/VMID (observed in driver logs, no driver patch).

## Phase 4 — Park-and-retry in the walker/TLB (core; built on S5)
1. Replace the sink hacks (`pagetable_walker.cc:213-222`, `amdgpu_vm.cc:587`) and the `faults.cc`
   panic: on `!pte.v`, raise the fault (Phase 3) and **park** the `WalkerState` instead of
   returning a response.
2. Use the driver's `VM_INVALIDATE_ENG*_REQ` MMIO write (offsets from S4) as the retry trigger:
   `invalidatePWC()` + flush affected TLB entries + re-run parked walks.
3. On successful re-walk, deliver the normal translation response. Add a safety
   iteration cap / timeout to fail loudly rather than hang.
4. **Gate:** a kernel that touches an initially-unmapped page completes correctly via the full
   fault→interrupt→driver-fix→invalidate→retry loop.

## Phase 5 — PTE coherence (built on S8)
1. Ensure the driver's PTE-install path (per S8) lands in the `vramShmem` the walker reads
   (`pagetable_walker.cc:443-472`); fix ordering/bridging if S8 found a gap.
2. Honor HDP flush / `VM_INVALIDATE` semantics so re-walks observe fresh PTEs.
3. **Gate:** repeated fault/fix/retry cycles in a loop kernel remain correct (no stale-PTE reads).

## Phase 6 — ASAN end-to-end
1. Run the ROCm GPU-sanitizer sample with a deliberate device OOB; confirm the report surfaces
   via hostcall (S7) with the correct faulting address, using the unmodified ASAN runtime.
2. Regression: existing xnack- `square` app still passes.
3. Add a `MI300XCosimFault` debug flag tracing fault→IH→invalidate→retry.
4. **Gate:** instrumented kernel both (a) runs correctly when clean and (b) reports a real OOB.

---

## Risks

- **R1 — timing-model park (reduced by S5):** gem5 may assume bounded translation latency; watch
  coalescer/outstanding-request accounting for deadlock. Settled deterministically by S5 before
  Phase 4.
- **R2 — IH→guest-RAM DMA — RESOLVED/ELIMINATED:** verified not a bug; gem5 system memory is
  `shared_backstore`-mapped to the guest-RAM shmem, so IH `dmaWrite` already reaches the guest.
  No Phase 2 work needed (see Phase 2 section).
- **R3 — PTE coherence (S8, Phase 5):** if KFD installs PTEs via a path that bypasses
  `vramShmem`, re-walks won't see them.
- **R4 — hostcall (S7):** required for ASAN reporting; may itself depend on demand paging.
- **R5 — discovery blob (S2/S3):** opaque firmware data; capability patch must be honored by the
  stock parser, since we cannot change the driver.
- **R6 — driver-contract fidelity (S4):** because the driver is unmodifiable, any mismatch in
  register offsets / IH IDs / cookie layout silently breaks fault handling. S4 is the guard.
- **R7 — XNACK_MASK SGPRs `s[104:105]`:** defined in gem5 (`gpu_registers.hh:54-55`) but unused
  by translation; verify real xnack+ code objects execute correctly (S6).

## Recommended First Step

Run **Phase 0 in full**, prioritizing **S1, S2, S4** (they settle the unmodified-driver contract
and the interrupt-delivery question that gate everything downstream) and **S5** (de-risks the
core mechanism). Re-scope Phases 1–6 against the recorded results before committing production
code.

**Progress (updated):**
- S4 complete (see `xnack-s4-fault-contract.md`).
- S1 resolved statically — Phase 2 eliminated (`shared_backstore`).
- Phase 3 implemented + compiles (gem5 `gem5.opt` links clean).
- **S2 PASS (on booted cosim):** with `HSA_XNACK=1`, `rocminfo` reports
  `gfx942:sramecc-:xnack+` / `XNACK enabled: YES`. The discovery blob already supports xnack+ —
  **S3 (blob patch) NOT needed.** BUT: exporting `HSA_XNACK` only in `cosim-gpu-setup.sh` does not
  reach login/GPU processes (it was empty in the guest shell → xnack-). Fixed by writing
  `HSA_XNACK=1` to `/etc/environment` in `rocm-install.sh` (needs a disk rebuild to bake in; can be
  set live with `export HSA_XNACK=1`).
- **S6 PASS:** a `gfx942:xnack+` HIP kernel compiled and ran correctly through the cosim GPU
  (`RESULT: 100..107`) — gem5 executes the xnack codegen (`_ec` opcodes / reserved `s[104:105]`).
- **Retry-arming PASS:** the stock driver writes `VM_CONTEXT1..15_CNTL = 0x5554cd` with retry bit 7
  set on all user contexts (context 0 = system, bit 7 clear). So `raiseVmFault`'s
  `retryFaultEnabled()` gate is satisfied — Phase 4 faults will actually fire. (Confirmed even with
  the stripped init: `ip_block_mask=0x67`, PSP/SMU off.)
- **S5 PASS (gates Phase 4 / clears R1):** with a throwaway patch delaying 4 translation responses
  by 10 µs each, the kernel still returned the correct result — the CU/coalescer tolerate parked
  translations without deadlock or corruption. **The translation-layer park-and-retry approach is
  viable; Phase 4 is GO.**
- Note: default cosim backend is **vfio-user** (not the legacy socket); `shared_backstore` (and
  thus the Phase 2 IH-DMA conclusion) holds for both backends.
- Remaining live spike: **S7** (hostcall / device printf) — needed for ASAN reporting; not yet run.

### Verdict: Phase 4 unblocked
All gating spikes pass (S2, S6, retry-arming, S5). Implement Phase 4 per `xnack-phase4-draft.md`.
S3 dropped (blob already xnack+). S7 still pending but does not gate Phase 4 (it gates ASAN
reporting in Phase 6).

### Phase 4 status: gem5 side WORKING to the driver boundary; Phase 5 is the blocker
Implemented + boot-tested (managed-memory kernel). The gem5 half of the loop is validated against
the unmodified ROCm 7.0 driver:
- Compute access to an unmapped page → `raiseVmFault` → IH UTCL2 cookie + GFXHUB fault registers.
- The driver decodes it correctly: `[gfxhub0] retry page fault (src_id:0 vmid:1 pasid:32769)
  IH client 0x1b (UTCL2)`, and reads back `VM_L2_PROTECTION_FAULT_STATUS:0x00100000` (vmid 1<<20,
  exactly what `setFaultStatus` wrote). Interrupt delivery + cookie + fault-reg readback all good.

Two non-obvious fixes were required (single-GC model of a multi-hub/multi-XCC GPU):
1. Capture CONTEXT*_CNTL / FAULT_CNTL / VM_INVALIDATE REQ **only via the GRBM (GFXHUB) aperture**
   (`writeMMIOGfx940Fault`) — else MMHUB writes at the same dword offsets clobber them.
2. **Sticky** retry-arming per VMID (`contextRetryArmed`) — MI300X's 8 XCDs each program GFXHUB
   CONTEXT*_CNTL, aliasing onto one gem5 register; later instance writes were clearing retry.

**Phase 5 status — not-present loop CLOSED; write-protect is the frontier.**
Committed (`e82ea35`). Boot-tested against unmodified ROCm 7.0 with a managed-memory kernel.

Three fixes were needed to close the loop:
1. **Retry trigger = retry-CAM doorbell, not VM_INVALIDATE.** GC 9.4.3 enables the retry-CAM
   (`vega20_ih.c`), so after fixing a fault the driver rings the retry-CAM doorbell (offset 0xd18)
   to signal retry — gem5 didn't recognize it. Route unknown doorbell writes (and VM_INVALIDATE
   REQ) to `retryAllParkedWalks()`.
2. **Deferred retry.** Re-walking synchronously from inside the doorbell/MMIO handler re-enters the
   walk/TLB/CU stack and crashes QEMU. `retryParkedWalks()`/`retryParkedWrites()` now only schedule
   an event; the re-walk runs off the event queue.
3. **Write-protect park (HMM read-then-write).** The FS page walk is issued as Read (`tlb.cc`), so
   the walker can't see write mode; a write to a driver-mapped read-only page is detected in
   `GpuTLB::handleTranslationReturn`, raises a write fault, and parks at the TLB layer (re-issued on
   the retry trigger with PWC/TLB flush; same-page in-flight accesses deferred to avoid duplicate
   return events).

**Working:** not-present demand fault → IH UTCL2 cookie → driver `svm_range_restore_pages` → CAM
doorbell → deferred re-walk → resolved. Validated.

**Frontier (next): write-protect / migrate-on-write — root-caused to a driver SVM decision.**
Investigated with amdgpu dynamic debug (`kfd_svm.c`, `kfd_migrate.c`). Findings:
- Migration + SDMA PTE-write **work**: large prefetched/runtime ranges migrate to VRAM and the
  driver installs writable PTEs (`sdma copy memory fence done`; `map [...] vram 1 PTE
  0x200000000000075`). So the cosim's SDMA, ZONE_DEVICE/pgmap, and PTE delivery are fine — this is
  **not** a gem5 PTE-coherence bug.
- The stuck page is a **fault-created single-page managed range** (e.g. `[0x78d0d1f93]`, the test's
  `a` buffer). For it the driver logs `xnack 1 ... best loc 0xffffffff` (SVM_LOC_UNDEFINED) and
  `restore ... done, r=0` with **no `map` line** — it never maps/migrates it, so it stays
  system-RO and every retry re-faults until the cap.
- Root cause: `svm_range_best_restore_location` (`kfd_svm.c`) returns `-1` when the faulting
  `*gpuidx` is in **neither** `prange->bitmap_access` nor `bitmap_aip`. KFD topology is a single
  GPU (node 1, `gpu_id=0x43a1`), and the *working* ranges resolve `best_loc=0x43a1` with the same
  fault `node_id=0`/`vmid=1`, so `*gpuidx` resolution is consistent — the difference is the
  **range's access bitmap**: this range grants the GPU no access.

Open question / next step: why does this single-page range have the GPU excluded from its access
bitmap while sibling ranges include it? Candidates: (a) the runtime registered it via SET_ATTR with
restricted/host-only access (fine-grained/coherent alloc), or (b) a cosim KFD-topology quirk makes
the runtime grant access to a different gpuidx. **To distinguish, instrument the driver's
`best_loc==-1` return to dump `bitmap_access`/`bitmap_aip` and `*gpuidx`** (throwaway driver build),
or compare the range's attributes against real hardware. Until then RMW managed workloads can't
complete; read-only managed access and resident (`hipMalloc`) workloads work. (Current code degrades
gracefully — warn+drop — instead of crashing.) The separate GART sink (`amdgpu_vm.cc`) is unchanged.

### Update: write-protect is NOT fixable in gem5 — confirmed (driver provides no mapping)
Further investigation closed this out:
- **HMM/SVM is supported** in the guest: boot dmesg shows `HMM registered 16384MB device memory`, so
  `pgmap.type != 0` → `KFD_IS_SVM_API_SUPPORTED` true → `bitmap_supported` includes the GPU. (So
  it's not an empty-`bitmap_supported` problem.)
- Migration + SDMA PTE-writes work for ranges the driver grants the GPU access to. But for the
  fault-created managed range the driver returns `best_loc=-1` and installs a **PRT placeholder PTE**
  (`0x8000000000003`, bit 51 = `AMDGPU_PTE_PRT`) — i.e. **no real GPU mapping exists** for that page.
- Consequence: there is **no valid physical address for gem5 to complete the write**. Both attempted
  gem5 workarounds crash the simulator: writing the PRT paddr (huge, invalid) segfaults gem5;
  sinking the compute write to paddr 0 also segfaults (paddr 0 is only a safe sink in the DMA/GART
  path, not through the Ruby/L2 compute path). The **only** non-crashing behavior is graceful
  warn+drop (the access never completes → that wavefront hangs, but the sim survives).
- **Conclusion:** RMW on fault-created managed ranges cannot be made correct in gem5 — the driver
  never creates a mapping to write to. This is a driver/runtime SVM-attribute decision (the GPU is
  excluded from the range's access bitmap) that the cosim cannot satisfy from the gem5 side. A real
  fix requires understanding why the runtime/driver excludes the GPU for these ranges (driver-
  instrumented build dumping the range bitmaps + the `SET_ATTR` calls + the topology the runtime
  sees), and may be an inherent cosim KFD-topology limitation.

**Net for the project goal (ASAN):** the core recoverable-fault mechanism — **not-present demand
paging — works**, which is what device-ASAN shadow accesses (loads from host-resident shadow) need.
Read-only managed access and resident `hipMalloc` workloads work. The unresolved case is **writes to
demand-paged managed memory** (RMW), which is a secondary path for typical ASAN usage.

### BREAKTHROUGH: the real blocker was a VMID mismatch (fixed)
The earlier "best_loc=-1 / driver won't map it" conclusion was a symptom, not the root cause. With a
driver-instrumented build (throwaway `pr_err` in `svm_range_best_restore_location`) the true cause
surfaced: `svm_range_restore_pages` bailed at **`kfd node does not exist node_id:0 vmid:1`**
(`kfd_node_by_irq_ids` → NULL), *before* `best_restore_location`.

- gem5 raises faults with **VMID 1** (vega/tlb.cc hardcodes `getPageTableBase(1)`), but KFD reserves
  VMIDs **8–15** for compute (`compute_vmid_bitmap = ((1<<16)-1) - ((1<<first_kfd_vmid)-1) = 0xFF00`,
  `first_kfd_vmid=8`). `kfd_irq_is_from_node()` requires `(compute_vmid_bitmap & (1<<vmid))`, so
  VMID 1 never matches → restore never runs.
- **Fix (committed):** `AMDGPUDevice::raiseVmFault` now reports a **KFD compute VMID** (8+) in the IH
  cookie + fault-status register. svm restore is keyed by PASID
  (`amdgpu_vm_handle_fault → xa_load(pasids,pasid)`), so the literal VMID only has to satisfy the
  compute-vmid check; the PTE update targets the process's tables (which gem5 reads at VMID 1).
- **Verified on a booted cosim:** `kfd node does not exist` gone; `best_restore_location` reached
  with `bitmap_access=0x1` → `best_loc=gpuid`; the driver **migrates the page to writable VRAM** and
  gem5's walker **sees the writable VRAM PTE** (`PTE=0x2000003ee5d8065 writable=1`) after the
  retry-CAM doorbell. So driver-side fault handling **and** migrated-PTE coherence now work.

**Remaining (secondary):** the managed-RMW kernel still hangs after the data page is handled, with a
single retry-CAM doorbell and one **GART sink** (`amdgpu_vm.cc`, the unconverted DMA/GART
translation path, vaddr in the `0x7fff…` system aperture). The likely remaining blocker is the
**completion-signal / GART access being sunk** (write lost → `hipDeviceSynchronize` never sees
completion). That GART/SDMA path is a separate sink not yet converted to recoverable faults — the
next item. The compute write-protect path itself is now correct (page migrates writable; the write
no longer faults).

**(Earlier "not gem5-fixable" assessment is superseded** — the VMID mismatch WAS gem5-fixable, and
the migrate-on-write path now works; only the GART/completion sink remains.)

### Remaining issue isolated to the GART/DMA path (separate sub-system)
With park/done tracing (`WPARK`/`WDONE`) the compute path is confirmed fully working:
- A not-present compute translation parks (`WPARK vaddr=0x79ffcc800000`) and **completes** after the
  driver restore + retry-CAM doorbell (`WDONE`, same vaddr). No outstanding park, no walker sink.
- **Resident `hipMalloc` kernel runs correctly under xnack+** (`RES sync=no error: 100..107`) with no
  GART sink — so the compute-side recoverable-fault loop is solid.

The **managed-RMW kernel hangs at `hipDeviceSynchronize`**, correlated with a **GART sink**:
`GART cosim: unmapped page vaddr=0x7fff00404700 → sink` (`amdgpu_vm.cc` GARTTranslationGen). This is
the **single-level GART/GTT translation** used by DMA/CP for system-aperture access (an SVM/completion
GTT page specific to the managed path; resident kernels never hit it). The lookup misses the PTE
(neither `gartTable` nor the VRAM-shmem fallback finds it) and sinks to paddr 0 → the access returns
garbage → host sync never completes.

This is a **separate sub-system** from the compute walker. The existing code comments note that
*faulting* on the GART path "causes an infinite DMA retry loop that crashes gem5", so converting it
to recoverable faults is non-trivial. Two avenues for the next step: (a) figure out why the GART PTE
for this page is missing (driver writes it but gem5's `gartTable`/offset calc misses it → a lookup
fix, no faulting needed), or (b) give the GART/DMA path the same park/retry treatment as the walker.

**Status:** compute-side xnack+ recoverable faults (not-present demand paging + migrate-on-write)
fully working and validated — this is what device-ASAN shadow demand-paging needs. Resident workloads
pass. The one remaining gap is the GART/DMA translation sink on the managed-RMW completion path.

### GART "lookup fix" investigated — does NOT apply (it's a routing issue, not a missing PTE)
Instrumented `GARTTranslationGen::translate` to dump lookups (`P8DBG`). Findings:
- The GART lookup/fallback **works correctly** for in-aperture addresses: successful translations are
  at `vaddr=0x3fff8xxxxxxx` (`gart_addr ≥ ptStart*8 = 0x3fff800000`), and the VRAM-shmem fallback
  reads a valid PTE (`vram1off = gartBase + (gart_addr - ptStart*8)`, in range). No bug there.
- The sinking address **`0x7fff00404700`** has `gart_addr=0x7fff00420`, which is **far below** the
  GART aperture base (`ptStart*8=0x3fff800000`) and **outside** the GART table coverage
  (`ptStart..ptEnd = 0x7fff00000..0x7fff1ffff`). It is a **host user VA** (classic Linux mmap/SVM
  address) — not a `gartTable` key/offset mismatch.
- Conclusion: the PTE isn't "missing from the table"; this **SVM/host VA is being routed through the
  GART path at all**, when it should be translated via the user VM (the compute walker / VMID 1 page
  tables that already work). So **option 1 (lookup fix) does not apply.**

Next step is therefore NOT a lookup fix but one of: (a) trace the **requestor** of the
`0x7fff00404700` access (which engine — CP/SDMA — and why it uses GART vs user-VM addressing) to see
if it's a routing fix, or (b) the larger option 2 (recoverable faults on the GART/DMA path, which the
code warns risks an infinite DMA-retry crash). Core goal (compute-side xnack+) remains met.

### Requestor traced → SDMA; routing fix lands the hang (committed `5d2dd1c`)
Tracing (`SDMAEngine::translate`) showed the requestor is the **SDMA engine** with `cur_vmid == 0`
(kernel SDMA queue) accessing the process's **user/SVM VAs** (`0x7fff…`). These were falling through
to the GART aperture and sinking. The fault address packing confirms the VA is inside the GPUVM user
aperture (vmContext0 `ptStart` stores a page-shifted base; `0x7fff00404700` sits at offset
`0x404700` within `0x7fff00000000`), so the correct translation is the **GPUVM page-table walker**,
not GART.

**Fix (committed `5d2dd1c`):** `SDMAEngine::translate` now routes high canonical user VAs
(`>= 0x700000000000`) through `UserTranslationGen` (vmid 1, the working compute walker) **when the
page is present**. Presence is probed with a non-fatal functional walk first because the walker's
functional path `fatal()`s on an unmapped page; if it faults, fall back to GART (prior behavior) so
boot-time/transient unmapped accesses don't crash the model.

**Result (booted cosim, unmodified ROCm 7.0, `/root/mgd` hipMallocManaged RMW):**
- **Hang fixed:** `/root/mgd` now returns `EXIT=0`, `sync=no error` (was `EXIT=124` timeout). All
  SDMA poll/copy user VAs that were blocking now resolve through the walker. Boot survives; no fatals;
  resident/compute paths unaffected.
- **Remaining data gap:** result is stale — `MRESULT: 0 1 2 3 4 5 6 7` instead of `100..107`. Exactly
  **one** address still sinks, **once**: `0x7fff00404700`, the **device→host migration copy-back
  destination** at `hipDeviceSynchronize`. Its GPUVM PTE (vmid 1) is **not present** at access time
  (the page was migrated to VRAM for the kernel and its system PTE cleared), so the write-back sinks
  and the host never sees the kernel's `+100`.

### Open frontier: SDMA recoverable faulting (the copy-back write-back)
Making that single copy-back land correctly requires the **SDMA engine to fault the not-present page
in, let the driver restore it, and retry** — the SDMA analogue of the compute-walker park/retry that
already works, but the SDMA translate path is **synchronous/functional** and would need restructuring
to support async park-and-retry. The functional probe cannot demand-page. This is the next item
(user-approved: "1, then 2" — ship the routing fix, then pursue SDMA recoverable faulting).
**Core goal (compute-side xnack+ for device ASAN) is fully met and independent of this.**

## References (verbatim anchors)

- xnack hardware contract: `AMDGPUUsage.rst:817-828`; `GCNHazardRecognizer.cpp:717-725`.
- ASAN requires xnack+: `clang/lib/Driver/ToolChains/AMDGPU.h:279`; `AMDGPU.cpp:1182-1217`.
- Restartable clauses / codegen: `SIFormMemoryClauses.cpp:9-14`;
  `SILoadStoreOptimizer.cpp:1885-1959`; `SIRegisterInfo.cpp:623-624`.
- Shadow mapping (host-resident, demand-paged): `AddressSanitizer.cpp:1984-1993`;
  `asanrtl/inc/shadow_mapping.h:24`.
- Hostcall reporting: `__ockl_sanitizer_report`; `rocclr/device/devsanitizer.hpp`.
- gem5 fault/interrupt sites: `arch/amdgpu/vega/faults.cc:47`;
  `arch/amdgpu/vega/pagetable_walker.cc:213-222,443-472,514-521`;
  `dev/amdgpu/interrupt_handler.cc:68-118,152-168`; `dev/amdgpu/amdgpu_device.cc:888-897`;
  `dev/amdgpu/amdgpu_vm.cc:587`; `qemu/hw/misc/mi300x_gem5.c:197-216`.

### Step 2 finding: SDMA recoverable faulting is implemented but NOT the blocker for managed RMW
After shipping the routing fix (step 1), implemented SDMA park-and-retry (uncommitted): `userVaPresent()`
probe, `parkIfNotPresent()` (raise recoverable VM fault + park the op continuation), `retrySdmaOps()`
(re-run on the retry-CAM doorbell), guard on the `copyReadData` host-destination branch, and wiring in
`AMDGPUDevice::writeDoorbell`.

**An SDMA trace (`--gem5-debug SDMAEngine`) of `/root/mgd` (hipMallocManaged RMW) shows the mechanism
never fires, because the premise was wrong:**
- During the kernel+sync there are **zero SDMA Copy packets** (opcode 1 absent). The only SDMA traffic
  is **PTEPDE** (page-table/PDE writes to VRAM `0x3ee5xx000`, `init:0 inc:4096 count:512` — mapping
  pages), **Fence**, **rptr-writeback**, and small **Write** packets to page-table addresses.
- The earlier suspect `0x7fff00404700` is a **boot-time** GART sink (`warn_once`, fires once during
  setup); it is **never accessed during the mgd run** (0 occurrences after the run marker).
- So the stale result (`MRESULT: 0 1 2 3 4 5 6 7`, not `100..107`) is **not** caused by a faulting
  SDMA copy-back. There is **no host<->VRAM data migration copy at all** for the managed buffer. The
  driver maps pages (PTEPDE) but no SDMA byte-copy moves the kernel's results back to the CPU-visible
  system page, so the CPU `printf` reads the untouched system page.

**Conclusion:** the managed-RMW correctness gap is an **absent/incomplete HMM data-migration** issue
in the cosim (svm_migrate host<->VRAM byte copies don't occur for this allocation), a separate and
deeper problem than SDMA recoverable faulting. The SDMA park/retry code is a sound mechanism for
genuine SDMA copy faults but does not address this test. Hang fix (step 1, committed `5d2dd1c`) stands;
resident `hipMalloc` and compute-side xnack+ (the ASAN goal) remain fully working.

**Open (next): investigate why no `svm_migrate_copy_to_vram`/`_to_ram` SDMA copies occur** for the
fault-created managed range under cosim (driver decision / ZONE_DEVICE migration path), vs. deciding
whether managed-memory full coherence is in scope at all given the ASAN goal is already met.

### CRITICAL CORRECTION: the booted disk is xnack-OFF (test regime was wrong)
While investigating the missing migration, found that the running disk image has **no `HSA_XNACK` in
`/etc/environment`** (`HSA_XNACK=` empty in the guest shell; `rocminfo` → `XNACK enabled: NO`, device
`gfx942:...:xnack-`). The Phase 1 fix (`gem5-resources` commit `3d6d5123`, adds `HSA_XNACK=1` to
`/etc/environment` in `rocm-install.sh`) is committed but **not baked into this disk** — the disk was
not rebuilt since that commit (the 58GB raw image's recent mtime only reflects QEMU's read-write boot,
not a Packer rebuild). **All `/root/mgd` runs this session were therefore xnack-OFF**, so the
"hang fixed / EXIT=0" result was an xnack-OFF artifact, not a real managed-RMW fix.

Driver dynamic-debug (`kfd_migrate.c`,`kfd_svm.c`) for the xnack-OFF run:
`xnack 0 ... best loc 0xffffffff` → `Mapping range ... on domain: CPU` → `map ... vram 0 PTE
0x600000000000067` (valid+system+snooped+readable+writable to guest-phys). I.e. the managed range is
mapped **in place to system memory** (no VRAM migration, no SDMA copy) — consistent with the observed
absence of SDMA Copy packets.

With explicit `export HSA_XNACK=1` (the real target regime), `/root/mgd` **hangs** → GPU job timeout →
`amdgpu_device_gpu_recover` → mode1 reset → **`psp_gpu_reset` NULL-deref kernel oops** (psp is disabled
in cosim via `ip_block_mask`). This matches the *known* pre-existing managed-RMW hang in the plan; the
managed-RMW path under xnack is still broken.

**Ground-truth re-validation needed** (in the correct xnack-ON regime, with the committed routing fix
`5d2dd1c` and disk rebuilt to bake in `HSA_XNACK=1`): (a) does resident `hipMalloc` still pass
`100..107`? (b) does the routing fix change the managed-RMW hang at all? (c) is the managed-RMW hang
the compute write-back path or something else. The committed routing fix remains a valid SDMA
user-VA correctness improvement independent of the managed-RMW outcome.

### Ground truth re-established (xnack-ON, committed binary 5d2dd1c, disk still xnack-off by default)
Re-ran with explicit `export HSA_XNACK=1` (`XNACK enabled: YES`). Two clean reference points:

- **Resident `hipMalloc` (compute path): CORRECT data** — `RRESULT: 100..107`. Confirms compute-side
  xnack+ works. (Caveat: the process then hangs on **teardown** — `timeout` returns 124 *after* the
  result prints. A process-exit/queue-teardown hang, separate from data correctness.)
- **Managed `hipMallocManaged` RMW: WRONG data** — `MRESULT: 0 0 0 0 0 0 0 0` (committed/no-park
  binary; completes, no GPU reset). With the earlier park binary it instead hung → GPU reset → oops,
  so the SDMA park mechanism *caused* the hang; without it the op sinks and the run completes with
  bad data. Same teardown hang (`MEXIT=124` after printing).

Migration dmesg (`kfd_migrate.c`/`kfd_svm.c`) for the managed run shows the **full HMM cycle runs**:
`switching xnack from 0 to 1`; ranges get `best loc 0x43a1` → `sdma copy memory fence done` →
`Mapping range ... on domain: GPU` → `map ... vram 1 PTE 0x2000000000000_75` (host→VRAM migrate); the
fault page `0x7a5b47e26` is restored to `vram 1`; then `CPU page fault ... address 0x7a5b47e26000` →
`sdma copy memory fence done` → `CPU fault ... done` (VRAM→host migrate-back). The `P5DRV` probe shows
`acc=0x1` (GPU granted access), `best_restore r=0`.

**So the managed blocker is NOT "no migration" and NOT a driver access-bitmap decision** (both run
correctly now). The migration **byte-copies complete but move zeros/garbage** — `MRESULT` all-zeros
means even the CPU's initial `0..7` is gone after the round trip. The real bug is the **SDMA
migration copy in gem5 not moving the correct bytes** for these SVM ranges.

Note: xnack-ON SVM VAs are `~0x7a5xxxxxx` (≈30 GB), **below** the committed routing fix's threshold
(`0x700000000000`), so that fix does not apply in the real regime — these copies go through GART. The
routing fix remains valid only for the (artifactual) xnack-OFF `0x7fff…` addresses; it is harmless but
not load-bearing for the actual managed-memory path.

**Two distinct remaining issues, both in the xnack-ON regime:**
1. **SDMA migration copy moves wrong data** (managed RMW → zeros). Next: SDMA-trace the migration
   copies under xnack-ON; resolve source/dest translation for the ~30 GB SVM/dma-mapped addresses so
   the bytes actually move (likely a GART/dma-addr resolution issue in the SDMA copy path).
2. **Process-teardown hang** under xnack (resident *and* managed return 124 after printing correct/any
   result). Independent of data correctness; likely queue/fault drain at process exit.

Also: the default disk lacks `HSA_XNACK` — rebuild the disk (Packer re-runs `rocm-install.sh` with the
committed Phase 1 fix `3d6d5123`) so default boots are xnack-ON, or always `export HSA_XNACK=1`.

### SESSION PAUSE / follow-up marker (2026-06-11)
State recorded above. Validated this session (xnack-ON, `export HSA_XNACK=1`): compute/resident
`hipMalloc` → correct `100..107` (ASAN-relevant path works); managed RMW → all-zeros (SDMA migration
copy moves wrong bytes) + teardown hang (124 after print). Committed: routing fix `5d2dd1c` (harmless,
not load-bearing in real regime). Reverted: SDMA park/retry (caused GPU-reset hang). Open follow-ups:
(1) SDMA migration copy data movement; (2) process-teardown hang; (3) rebuild disk to bake in
`HSA_XNACK=1`. NEW direction: move to a base Ubuntu 24.04 backing disk + ROCm delta (qcow2 overlay)
workflow before resuming the above.

### DATA-MOVEMENT GAP FIXED (managed RMW now correct)
Root-caused with `--gem5-debug SDMAEngine,SDMAData` on the apt-ROCm disk
(xnack-ON). The full HMM round trip's data is correct until the very last write:
- host->VRAM migrate: `Copy src: 7fff00000000 -> 3ee5cf000`, `First: 0000000100000000`
  (a[0]=0,a[1]=1) — source read correct (via the existing getGARTAddr(source) +
  GART path), written to VRAM.
- kernel +100 in VRAM.
- VRAM->host migrate-back: `Copy src: 3ee5cf000 -> 7fff00000000`,
  `First: 0000006500000064` (a[0]=100,a[1]=101) — **read from VRAM correct**, then
  `Copying to host address 0x7fff00000000`.
- But `getDeviceAddress 0x7fff00000000 -> 0`: the dest user VA translated to
  **paddr 0**, so the 100..107 bytes were written to physical 0, not the CPU's
  page. (After ZONE_DEVICE migration the CPU page is a fresh zero page that the
  copy-back must fill; the lost write left it zero → `MRESULT` all-zeros.)

**Root cause:** `SDMAEngine::copy()` rewrote a host/system **source** through the
GART aperture (`getGARTAddr`) for the priv/vmid0 case, but never did so for the
**destination**. The migration copy-back's host dest was thus untranslated.

**Fix (gem5 `cc8ea3f`):** apply the same `getGARTAddr` rewrite to `pkt->dest`,
symmetric to the source. Verified on a booted cosim (apt ROCm, `HSA_XNACK=1`):
- managed `hipMallocManaged` RMW → `MRESULT: 100 101 102 103 104 105 106 107`
  (was all zeros);
- resident `hipMalloc` → `RRESULT: 100..107` (unchanged, no regression).

This supersedes the earlier "SDMA migration copy moves zeros" frontier — it was a
destination-translation bug, not a migration/PTE problem. The earlier user-VA
routing fix (`5d2dd1c`) is independent and remains for SDMA user-VA poll/copy
sinks; it is not what carried the migration data.

**Remaining (separate):** process-teardown hang — both managed and resident
return 124 *after* printing correct results (queue/fault drain at process exit),
independent of data correctness.
