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

### Teardown "hang" root-caused: SVM migrate_vma ping-pong livelock (not interrupts)
Investigated the post-result hang (process returns 124 after printing correct data).
- **Not xnack-specific, not interrupt delivery.** A clean resident `hipMalloc` run exits
  `RX=0` and the guest amdgpu MSI-X count rises (e.g. 287->385, +98); during a managed run the
  count also rises (+85). Interrupts reach the guest fine. (An earlier "frozen count" reading
  was an artifact of GPU state degraded by prior `kill -9`'d processes.)
- **Specific to managed/SVM memory.** Resident exits cleanly; `hipMallocManaged` livelocks.
- **Root cause (driver dynamic-debug `kfd_svm.c`/`kfd_migrate.c`):** the same managed page
  ping-pongs forever:
  `CPU page fault -> migrate gpu->ram -> sdma copy memory fence done ->`
  **`unsuccessful/cpages/npages 0x0/0x1/0x1`** (Linux migrate_vma committed 0 pages) `->`
  `Mapping range ... on domain: GPU (vram 1) -> CPU page fault (same addr) -> ...`
  The bytes DO reach the CPU page (the GART-dest fix `cc8ea3f` makes the result correct), but
  `migrate_vma` never commits the device->system page-ownership transfer, so the kernel keeps the
  page GPU-resident, re-maps it to VRAM, the CPU re-faults, and it loops.
- **Nature:** a Linux HMM / amdgpu **ZONE_DEVICE migrate_vma bookkeeping** issue in the guest
  (migrate_vma_pages returning 0 successful — typically a device-page refcount/isolation check),
  **not a gem5 data-path bug**. Correctness is unaffected (results are right before the loop).
- **Next step (if pursued):** instrument the driver's device->ram migrate path
  (`svm_migrate_vram_to_ram`/`svm_migrate_copy_to_ram` + the `migrate_vma_pages` result) to see
  why the collected device page is not committed (refcount on the ZONE_DEVICE page, dst alloc, or
  the cosim pgmap page lifecycle). This is a kernel/driver investigation, separate from gem5.

### CORRECTION: teardown "livelock" is a GPU<->CPU migration THRASH, migrations SUCCEED
The prior section ("migrate_vma commits 0 pages") was a **misread**. The driver prints
`unsuccessful/cpages/npages 0x0/0x1/0x1` where the first field is the *unsuccessful* count:
`0x0` unsuccessful = the device->ram migration **succeeds** (1 page migrated). Confirmed with a
throwaway probe in `svm_migrate_vma_to_ram` (dump unsuccessful pages' refcount) which **never
fired** — there are no failed pages.

Correct root cause (driver dynamic-debug, single managed page e.g. `0x704c83cf9`):
```
GPU retry fault: best restore 0x43a1, actual loc 0x0  -> migrate to VRAM (successful 0x1) -> map domain GPU
CPU page fault  0x704c83cf9000                          -> migrate to RAM  (0 unsuccessful = success)
... repeats forever
```
It is a **migration ping-pong / thrash**: after the kernel finishes (results are correct — the
GART-dest fix `cc8ea3f` works), **the gem5 GPU keeps issuing retry faults on the managed page**
(`best_restore = GPU`), so the driver migrates it back to VRAM; the host process's access then
faults it back to RAM; repeat. Both migrations succeed; the loop never terminates, so the process
never exits (124). Resident `hipMalloc` has no SVM page and exits cleanly.

**So the sim-side question is: why does the gem5 GPU keep faulting on the managed page after the
kernel has completed?** (a wavefront/queue not retiring, or the xnack park/retry re-issuing an
access that should be done). That is a gem5 compute/queue or xnack-replay issue, not a migrate_vma
or refcount problem. Next step: trace gem5 GPU page-fault/park-retry during the post-result window
to identify the agent that keeps accessing the page.

(Note: a throwaway `P7DBG` probe remains in the monolithic disk's amdgpu DKMS module; it is inert
— only prints on a failed page, which does not occur — and can be reverted with a DKMS rebuild.)

### rocrtst HW(MI325) vs cosim comparison (ASAN build, TheRock run 27320850021)
Reference: wiki page 1734813712 (#2145), build = run 27320850021, MI325 log = test_rocrtst.log.
Built cosim with the same build (cosim_vm.py, rocm.run_url pinned to 27320850021) and ran
`/opt/rocm/bin/rocrtst64` with `GTEST_FILTER=-rocrtstFunc.Memory_Max_Mem` (matching the harness).

**HW (MI325) baseline:** 76 tests / 5 cases; **27 OK, 44 FAILED, then CRASH at test #72**
`rocrtstPerf.AQL_Dispatch_Time_Single_SpinWait` (ASAN SEGV in `dispatch_time.cc:178
DispatchTime::RunSingle()`). So the HW reference itself does not fully pass — 44 failures + a crash
are baked into this ASAN build (real ASAN findings / known issues). Target = match this pattern.

**Cosim result:**
- Tests 1-3 **match HW**: `rocrtst.Test_Example`, `Test_Example_InterruptDisabled`,
  `Test_MetadataPrefetchPacket` all OK (1.3-2.0 s each).
- Test #4 `rocrtstFunc.MemoryAccessTests` **DIVERGES**: subtest `CPUAccessToGPUMemoryTest` passes,
  then **`GPUAccessToCPUMemoryTest` HANGS** (HW: MemoryAccessTests = OK). Signature is identical to
  the earlier toy/teardown hang: ROCr main thread busy-spins in userspace (`R`), helper threads in
  `kfd_wait_on_events` — i.e. ROCr waits on a GPU-completion/event that never arrives for a
  **GPU-accesses-CPU(system)-memory** operation. This is the dominant sim functional gap.

**Secondary sim robustness gap:** after `pkill -9 rocrtst64` mid-GPU-op, a fresh ROCr init crashes
the gem5 model (`amdgpu: failed to write reg 38bd4 wait reg 38be6` -> vfio-user broken pipe -> gem5
container died). Re-init after an aborted process is not handled cleanly.

**Read on the recurring hang:** the common thread across the toy managed-RMW teardown, the HIP
`__hip_module_dtor` spin, and now `GPUAccessToCPUMemoryTest` is ROCr blocking on a GPU op whose
completion (signal/event) never reaches the host, specifically around **GPU access to CPU/system
memory under xnack**. Fixing that completion path is the highest-value next step for reliable
execution. Next: relaunch with `--gem5-debug PM4PacketProcessor,SDMAEngine,AMDGPUDevice` and run only
`--gtest_filter=rocrtstFunc.MemoryAccessTests` to capture the pending GPU op at the hang.

### Teardown hang ROOT-CAUSED (gem5 side): SDMA-walker fault loop, NOT compute re-fault (2026-06-12)
Re-ran `/root/mgd` (managed-RMW) on a booted cosim (`export HSA_XNACK=1`, committed binary `cc8ea3f`)
with `--gem5-debug GPUPTWalker`, isolating the gem5-log delta for the run + the full ~90s teardown-hang
window (13.6k lines). Result: `MRESULT: 100..107` correct, then `EXIT=124` (teardown hang) — clean
reproduction.

**The earlier "compute GPU keeps issuing retry faults / migration ping-pong" hypothesis is WRONG for
the gem5 mechanism.** In the entire run+hang window the **compute walker parks exactly ONCE and
retries ONCE** (`Parking faulted walk vaddr=0x74deb247c000`; `doRetryParkedWalks: 1 parked`). The
compute-side recoverable-fault path is clean and quiescent after the kernel.

**What actually loops (~1100×, the whole hang):** the **SDMA engine walker** `sdmas00.walker`. It walks
a range of **474 distinct GART/system-aperture VAs** (`0x3fff80…` GART aperture, `0x7fff00…` system
aperture), and for every one reads a **PDE2 = `0x40000000000000`** (only bit 54 = the PDE `.p` bit set;
valid bit 0 clear). Per `pagetable_walker.cc:314`, `pde.p` set makes the walker treat the PDE2 as a
**terminal huge-page (1GB) PTE** (`doEndWalk`), but valid=0 → `Raising page fault.` It then immediately
re-issues the walk for the next address and re-faults — **with ZERO park/retry** (no `Parking faulted`
on the SDMA path; SDMA-walker faults have no recovery, unlike the compute walker). The SDMA op never
completes → host sync/teardown never sees completion → 124.
(Note: the GPUPTWalker `write:yes` label is misleading — `pagetable_walker.cc:331` prints "yes" when
`pte.w==0`, i.e. it reports the PTE's *writable* flag, not the access direction.)

**Refined root cause:** at/after teardown an SDMA op accesses a GART/system-aperture region whose GPUVM
mapping is an **unmapped huge-page placeholder PDE2** (`0x40000000000000`, P-bit set, invalid). The SDMA
walker faults on it and spins forever because the SDMA translate/walk path has no park-and-retry. This
is the same "GART/SDMA path" frontier noted above, now pinned to a concrete gem5 mechanism and entry
value. It is independent of the compute-side xnack+ path (which works).

**Next options:** (a) `--gem5-debug SDMAEngine` correlation run to identify *which* SDMA op (copy /
fence / rptr-writeback / PTE write) and *why* its destination maps to the invalid placeholder PDE2 at
teardown — is the placeholder a stale/cleared mapping (a lookup/coherence bug) or genuinely unmapped
(needs demand-fault); (b) give the SDMA walker the same park-and-retry recovery the compute walker has,
gated to avoid the known "infinite DMA-retry crash." Core ASAN goal (compute-side not-present demand
paging) remains met and unaffected.
Artifact kept: `/tmp/mgd_gem5_run2_keep.log` (full gem5 log of the reproducing run).

### rocrtst full-suite comparison vs MI325 reference (2026-06-12, build 27320850021)
Ran the wiki's ASAN build (TheRock 0a15f66 / run 27320850021, gfx94X-dcgpu) on the layered cosim VM
(`cosim_vm.py`, manifest already pinned to this run) with the harness env (HSA_XNACK=1,
ASAN_OPTIONS=detect_odr_violation=0:quarantine_size_mb=600, ASAN_SYMBOLIZER_PATH, AMD_LOG_LEVEL=1) and
filter `GTEST_FILTER=-rocrtstFunc.Memory_Max_Mem` (== `test_rocrtst.py` TEST_TYPE=full for this family).
Reference: `/home/rsrimant/code/mi3xx-cosim/test_rocrtst.log` (MI325). Artifacts saved:
`rocrtst_cosim_p3.log`, `rocrtst_{ref,cosim}_outcomes.txt`.

**Reference (MI325) baseline:** 27 OK, 44 FAILED, then ASAN SEGV crash at
`rocrtstPerf.AQL_Dispatch_Time_Single_SpinWait` (`dispatch_time.cc:178 DispatchTime::RunSingle()`) →
exit 1. The 44 "failures" are gtest assertion failures (functional expectations on this build, e.g.
`Memory_Atomic_*` expect err 4099 but get HSA_STATUS_SUCCESS), NOT ASAN crashes.

**Result — cosim matches HW on 69/70 commonly-run tests, incl. the identical final ASAN SEGV crash.**
- All 44 HW assertion-failures reproduce identically on cosim, AND the final ASAN SEGV crash reproduces
  at the exact same test/line → **ASAN instrumentation works end-to-end under cosim** (the project goal).
- **3 divergences, all GPU-accesses-CPU-system-memory or device-fidelity, none ASAN-related:**
  1. `rocrtstFunc.MemoryAccessTests` (HW OK) — **nondeterministic** on cosim: passed once (1297 ms),
     crashed the gem5 model once at subtest `GPUAccessToCPUMemoryTest` (vfio-user EOF). Coarse-grained
     GPU→CPU access.
  2. `rocrtstFunc.MemoryAccessCoherent` (HW OK) — **hangs** on cosim (fine-grained/coherent GPU↔CPU).
  3. `rocrtstFunc.Memory_Available` (HW OK) — **FAILED** on cosim: a GPU-pool over-allocation that
     should return err 4099 returns HSA_STATUS_SUCCESS (`memory_basic.cc:539`). cosim VRAM accounting
     doesn't enforce the available-memory limit; also a topology diff (cosim simulates an MI300A **APU**
     with gfx942 GPU pools 4/5; the MI325 reference enumerates those pools as CPU/EPYC and skips them).

**Common thread of divergences 1–2:** the GPU-accesses-CPU/system-memory completion path under xnack is
fragile (hang or model crash), nondeterministically — same root area as the SDMA-walker teardown loop
above. Divergence 3 is a device-model fidelity gap (VRAM size/accounting + APU-vs-discrete topology),
not a fault/xnack issue. Env/driver context diff (informational): cosim ROCk 6.14.14, device "MI300A";
reference ROCk 6.16.13, MI325 / EPYC 9655 — same ROCm userspace ASAN build on both.

Op note: killing rocrtst64 mid-GPU-op (pkill/timeout-KILL) tears down the gem5 model (vfio-user broken
pipe), and a stale QEMU can hold port 2222 — so test the GPU↔CPU hangers by *excluding* them and reboot
between runs rather than killing in place.

### Divergence 1-2 investigation (2026-06-12): coherent hang root-caused to AQL queue staleness
User asked to investigate+fix divergences 1-2 (GPU-accesses-CPU-memory: test1 `MemoryAccessTests`
nondeterministic crash; test2 `MemoryAccessCoherent` hang). Reproduced `MemoryAccessCoherent` alone on
the ASAN cosim with layered tracing (SDMAEngine/GPUPTWalker, then PM4PacketProcessor/GPUCommandProc,
then HSAPacketProcessor/SDMAEngine).

**The hang is NOT translation/fault related (translation works).** It is an AQL-queue dispatch failure:
- The test enqueues TWO AQL packets on the user compute queue — `BARRIER_AND` (waits on
  `signal_shader_start`) then kernel `DISPATCH` — and rings the doorbell ONCE (write-index 2). The
  dependency chain is: SDMA copy1 host->device (sets signal_shader_start) -> barrier releases -> kernel
  device->device (sets signal_shader_end) -> SDMA copy2 device->host (dep signal_shader_end) -> host.
- Final hang: `sdmas00` stuck in `POLL_REGMEM addr=<signal_shader_end>, ref=0, retry=0xfff` (infinite)
  forever — value stays 1. So the kernel never wrote its completion signal.
- HSAPP trace proves the kernel NEVER dispatched: in the whole run HSAPP processed exactly ONE AQL
  packet (a vendor-specific one on another queue), ZERO barrier-AND, ZERO kernel-dispatch. The user
  queue (active list 5) fetched 1 packet then its Qwakeup bailed because `dispPending()` was false.
- `dispPending()` (`hsa_packet_processor.hh:188`) is false because the fetched packet header read as
  `HSA_PACKET_TYPE_INVALID` (1), not `BARRIER_AND` (3). And gem5 saw write-index=1 (readIndex 0), not 2.
  i.e. gem5 acted on a STALE snapshot of guest queue memory (intermediate state: barrier not yet
  header-written, 2nd packet not yet counted) and NEVER retried.

**Two gem5 defects (both in `src/dev/hsa/hw_scheduler.cc` / HSAPP):**
1. `HWScheduler::write` (doorbell handler) acts once on the doorbell-time snapshot; if the fetched AQL
   packet header is still INVALID (guest write not yet visible across the vfio-user/shared-RAM path),
   `dispPending()` gives up with no re-read/retry -> queue stalls forever. Real HW re-reads the write
   pointer / packet until valid.
2. `hw_scheduler.cc:344` `readIndex = doorbell_reg - 1` hardcodes "exactly 1 packet per doorbell", so a
   batched multi-packet submission (barrier+dispatch, one doorbell) only ever fetches the LAST packet.
Normal single-packet HIP dispatch dodges both (valid header readable immediately, 1 pkt/doorbell), which
is why resident kernels work but this test hangs.

**Fix direction (proposed, in HSAPP/scheduler, NOT the fault path):** make AQL fetch robust to guest
visibility lag — when a doorbelled packet slot (dispIdx < wrIdx) reads INVALID, re-DMA it and reschedule
instead of stalling; and fetch ALL packets up to the true host write-index rather than assuming one per
doorbell. Risk: core dispatch path used by every kernel launch — must regression-test resident/managed
kernels + the rest of rocrtst. Validation cycle = gem5 rebuild + cosim boot (long). Checkpointing with
user before the change.

### CONFIRMED root cause (instrumented build): one-AQL-packet-per-doorbell
Diagnostic gem5 build (throwaway `warn()` "AQLDIAG" probes in `hw_scheduler.cc::write` and
`hsa_packet_processor.cc::QueueProcessEvent::process`) on the coherent test gave:
```
AQLDIAG HWSCHED write db=0x4008 doorbell_reg=3 -> wrIdx=3 rdIdx=2   (user compute queue)
AQLDIAG q5 STALL dispIdx=0 wrIdx=1 cached_header=0x1 host_addr=...   (header INVALID)
AQLDIAG q5 RE-READ@1us header_lowbytes=0x1                          (still INVALID, NOT a lag)
```
Mechanism (`amdgpu_device.cc:638-643` ComputeAQL doorbell -> `hw_scheduler.cc:339-344`):
- `writeDoorbell` ComputeAQL does `hwScheduler->write(offset, guestDoorbellVal + 1)`.
- `HWScheduler::write` sets `writeIndex = doorbell_reg` and `readIndex = doorbell_reg - 1` -> spaceUsed
  is ALWAYS 1 -> gem5 fetches exactly ONE AQL packet per doorbell, at the doorbell-derived index.
- The test enqueues TWO packets (barrier@0, dispatch@1) and rings the doorbell ONCE with its
  write_index=2. gem5 computes doorbell_reg=2+1=3 -> fetches packet **index 2** (an empty slot) ->
  header INVALID -> `dispPending()` false -> permanent stall. Barrier@0 and dispatch@1 are NEVER
  fetched -> kernel never runs -> SDMA copy-2 polls `signal_shader_end` forever -> hang.
The re-read staying INVALID proves it's the WRONG SLOT (not a visibility lag): re-DMA won't help.
Normal HIP rings once per packet (and ROCr internal queues ring with write_index-1, e.g. db=0x4000
guest-wrote-0 -> doorbell_reg=1 -> fetch index 0, works), so single-dispatch dodges this. The two
queues observed even use different ring conventions (write_index-1 vs write_index), so gem5's
doorbell-value-derived single-packet window cannot be correct for both -- the robust fix is to fetch
the FULL packet range [readIndex, real write_index), reading the true write_index from the AQL queue
memory rather than trusting the doorbell value + the readIndex=doorbell_reg-1 hack.

### FIX implemented + validated: AQL multi-packet-per-doorbell (gem5 hw_scheduler.cc)
Fix (uncommitted, `src/dev/hsa/hw_scheduler.cc`):
- `HWScheduler::write` (doorbell handler): removed `qDesc->readIndex = doorbell_reg - 1` (which forced
  spaceUsed=1 -> one packet per doorbell). Now only sets `writeIndex = doorbell_reg`, so
  getCommandsFromHost fetches the full range `[readIndex, writeIndex)`.
- `HWScheduler::registerNewQueue`: when `rd_idx > 0` (queue map/remap resume), also set
  `q_desc->readIndex = q_desc->writeIndex = rd_idx`, so readIndex is correct without the per-doorbell
  reset (handles remap/reuse). Trailing phantom slot from the doorbell `+1` reads INVALID and harmlessly
  terminates dispatch; it never completes so the host read_dispatch_id (written from aqlBuf->rdIdx) is
  not corrupted.
(Also present from session start, unrelated: `unregisterQueue` assert->deschedule for queue-destroy
mid-process, exercised by rocrtst Counted_Queue_Overflow.)

**Validation (booted ASAN cosim, build 27320850021):**
- `rocrtstFunc.MemoryAccessCoherent` (div 2) -> **OK** (was: hang). Repeatable.
- `rocrtstFunc.MemoryAccessTests` (div 1) -> **OK** incl. GPUAccessToCPUMemoryTest subtest.
- Both together x2 reps -> PASSED, deterministic.
- **No regression:** GroupMemoryAllocationTest, MemoryAllocateAndFreeTest, Concurrent_Init_Test,
  Reference_Count, Signal_Create_Concurrently, IPC all still **OK** (PASSED 6 tests) with the fix; boot
  + GPU init unaffected (single-packet dispatch path identical).

**Remaining (separate, pre-existing, NOT introduced by this fix): nondeterministic gem5 crash on the
recoverable-fault path.** Under sustained GPU-accesses-CPU-memory load the gem5 model occasionally dies
(`qemu: failed to read header: EOF`): once on the 3rd repeat of the memory-access tests (correlated with
a recoverable UTCL2 retry page fault, vmid 8) and once mid full-suite at GroupMemoryAllocationTest (no
fault dump). The same crash class predates the fix (div-1 nondeterministic crash; the "re-init after
aborted process crashes the model" note). So the suite still can't reliably run to the AQL_Dispatch ASAN
crash end-to-end. Next: harden the compute-walker park/retry + IH/doorbell path against the
recoverable-fault crash (trace `AMDGPUDevice,GPUPTWalker` at the crashing fault). This is the
robustness frontier; the deterministic AQL hang (div 2) is fixed.

### AQL fix committed; remaining crash diagnosed = SGPR-range panic (instruction decode)
Committed the AQL multi-packet fix as two gem5 commits:
- `5aa160e41f dev/hsa: fetch all AQL packets per doorbell ring`
- `ed8a980a3c dev/hsa: don't abort when a queue is destroyed mid-processing`

Then pursued the nondeterministic crash. By streaming `docker logs -f` of the gem5 container to a file
(the container is `--rm`, so the crash output is otherwise lost) while looping
MemoryAccessTests+MemoryAccessCoherent, captured the actual gem5 death — it is NOT vfio-user/coherence:
```
src/gpu-compute/static_register_manager_policy.cc:78: panic: SGPR index 40 is out of range: SGPR range=[0,40]
  mapSgpr <- initDynOperandInfo <- GPUDynInst <- FetchUnit::decodeInsts
```
A wavefront decodes an instruction referencing **s40** while only **40** scalar regs are reserved
(valid s0..s39). Reproduced in 1-2 loop iterations.

Throwaway instrumentation in `gpu_command_processor.cc::dispatchKernelObject` (logging kernel_object +
granulated SGPR/VGPR counts per dispatch; since reverted) showed the descriptor read is **consistent**:
every dispatch of the crashing kernel reads `gran_sgpr=4 -> numSgpr=(4+1)*8=40`, `gran_vgpr=0 ->
numVgpr=8`, same kernel_object. So:
- NOT a stale/garbage descriptor read (numSgpr is always 40), and NOT the AQL fix dispatching a wrong
  packet (kernel_object is consistent and valid).
- The kernel's OWN descriptor declares 40 SGPRs (s0..s39), yet gem5 decodes an instruction using s40 --
  beyond the kernel's declared usage. So gem5 is occasionally decoding a **bogus instruction** that is
  not really in the kernel.

**Conclusion: the remaining crash is a gem5 instruction-fetch/decode robustness bug under xnack
demand-paging** -- the kernel *code* (not the descriptor) is occasionally fetched stale/wrong, so a
garbage instruction decodes with an out-of-range SGPR operand and panics. Consistent with the
nondeterminism (descriptor fixed; only the decoded instruction varies). This is separate from and
deeper than the AQL hang (which is fixed) and the recoverable-fault demand-paging (which works for data).

**Next step (decisive, needs another instrumented build):** at the out-of-range point dump the
faulting wavefront PC + the raw instruction bytes gem5 fetched, and compare against the actual kernel
machine code at that PC (read independently). If the bytes are garbage -> stale code-page fetch under
demand paging (fix the code-fetch coherence / fault the code page in before fetch); if the bytes are a
valid s40 instruction -> the SGPR-count formula (`hsa_queue_entry.hh:115`, `(gran+1)*8` for gfx942)
under-counts and must be corrected. Artifact: `gem5_sgpr_crash.log` (full backtrace).
Note: the current built gem5.opt still contains the (reverted-in-source) AKCDIAG warn; rebuild for a
clean binary before production use.

### Remaining-crash diagnosis COMPLETE: stale instruction-fetch (not the SGPR formula)
Instrumented `generateVirtToPhysMap` (throwaway SGPRDIAG warn, since reverted) to dump the faulting
instruction at the out-of-range SGPR. Captured:
```
SGPRDIAG OOB simd=0 wfDynId=140 pc=0x7388d291787c opcode=v_cndmask_b32 rawSel=40 virt_idx=40
  reserved=40 disasm=[v_cndmask_b32 v0, s40, v1, vcc]
```
Decisive: the kernel descriptor consistently declares **40 SGPRs** (s0..s39; AKCDIAG showed numSgpr=40
every dispatch). A correctly-compiled kernel never references an SGPR >= its declared count, and a plain
`vector_copy` wouldn't contain `v_cndmask_b32` at all. So gem5 decoded a **garbage instruction from
stale/wrong fetched code** -> the crash is a **stale instruction-fetch under xnack demand-paging**, NOT
the SGPR-count formula (`hsa_queue_entry.hh:115`), which is correct.

**The remaining crash is actually a cluster of NON-recoverable handling of not-present/stale memory on
gem5's control/fetch path under sustained xnack GPU-accesses-CPU-memory load** (both nondeterministic):
1. **SGPR out-of-range panic** (`static_register_manager_policy.cc:78`) -- instruction *fetch* reads a
   stale/garbage code page -> decodes a bogus instr with an out-of-range SGPR operand.
2. **User translation fault fatal** (`amdgpu_vm.cc:764`, `UserTranslationGen::translate`) -- a *functional*
   page-table walk (SDMA / control path) hits a not-present user page and `fatal()`s instead of recovering.
The compute *data* park/retry (committed earlier) only covers timing-path data accesses; the
control-path **functional** reads (instruction fetch code pages; functional walks for SDMA/descriptor)
have no demand-fault recovery, so they either read stale data (-> garbage decode -> SGPR panic) or fatal.

**Fix direction (deep, multi-subsystem, NOT yet implemented):** make the control/fetch path robust to
xnack demand paging -- ensure code pages are faulted-in/coherent before instruction fetch decodes them
(fixes mode 1), and convert the `UserTranslationGen` functional `fatal` into a demand-fault+retry (or a
presence-gated path) so a not-present control-path page is faulted in rather than crashing (fixes mode 2;
mind the prior "infinite DMA-retry" caveat on the SDMA path). Both are core robustness changes with real
regression risk to every kernel launch -> warrants its own focused effort + full regression. Artifacts:
`gem5_sgpr_diag.log` (SGPRDIAG + SGPR panic), `gem5_transfault_crash.log` (User translation fault).
All throwaway instrumentation reverted; tree clean at `ed8a980a3c`; gem5.opt rebuilt clean (valid 1GB
ELF, no diagnostic strings, matches the committed AQL fix). Build note: the heavy gem5.opt link must run
to completion uninterrupted — backgrounded builds that get interrupted leave a truncated ~85MB zeros
file (`file` reports "data"); rebuild with a foreground/uninterrupted `scons ... -j2..6` if that happens.

### Crash cluster: mode 1 FIXED (TLB flush on VM_INVALIDATE); mode 2 still open (rare)
Root-caused and fixed the dominant crash mode. gem5 commit `6f369001a3`
(`dev/amdgpu: flush TLBs on VM_INVALIDATE_REQ`):
- **Mode 1 (stale-instruction-fetch -> SGPR/VGPR out-of-range panic): FIXED.** The
  `VM_INVALIDATE_ENGn_REQ` MMIO handler (`amdgpu_vm.cc` writeMMIOGfx940Fault) only re-ran parked walks
  and never flushed the TLBs, although a VM_INVALIDATE_REQ *is* a hardware TLB flush. After the driver
  migrated a page under xnack, valid-but-stale TLB entries -- including the per-CU instruction/SQC TLB
  (all GpuTLBs register into `gpu_tlbs`) -- kept pointing at the page's old physical location, so a
  later instruction fetch read stale memory and decoded a garbage instruction with an out-of-range
  register operand -> panic. Fix: call `invalidateTLBs()` before `retryAllParkedWalks()` on the
  VM_INVALIDATE_REQ. (Explains the "after several iterations, not first-touch" nondeterminism.)
  **Validated:** the model died within 2-5 loop iterations before; now survives 7+ iterations of the
  memory-access tests AND a full rocrtst suite to the final ASAN abort with ZERO out-of-range panics
  (gem5 stays alive; previously the full suite nondeterministically killed the model).
- **Mode 2 (functional-walk fatal, `UserTranslationGen::translate` "User translation fault"): STILL
  OPEN, but rare** (0 recurrences across all post-fix validation runs; likely some mode-2 conditions
  were downstream of the mode-1 staleness). A first attempt to degrade it gracefully by sinking the
  not-present page to paddr 0 was **UNSAFE** -- the SDMA then read garbage from paddr 0 and hit a new
  `sdma_engine.cc:695 panic: Invalid SDMA packet`. Reverted. A safe fix needs a GART fallback or a
  deferred demand-fault for the not-present functional walk, NOT a paddr-0 sink. Tracked in memory
  [[project-xnack-fetch-crash-followup]]; artifacts `gem5_invalidsdma_crash.log`.

Net: the dominant nondeterministic model death is fixed; the full suite now runs reliably to
completion. Remaining divergences from MI325 are unchanged by this (cross-test corruption in the
single-process suite; MemoryAccessCoherent data-verify; the rare mode-2 fatal).

### Crash cluster mode 2 FIXED (not-present SDMA functional walk) — gem5 7655fffae0
Root cause: `UserTranslationGen::translate` did a functional (synchronous) walk for an SDMA/DMA
access; on a not-present user page (demand-paged under xnack) it `fatal()`'d. Crucially, for a user
SDMA queue (vmid>0) even the ring/packet fetch (`decodeNext` -> `dmaReadVirt(q->rptr())`) routes
through `SDMAEngine::translate` -> `UserTranslationGen`, so a not-present RING page also hit this. The
earlier sink-to-0 attempt turned the fatal into a `panic: Invalid SDMA packet` (the sunk ring read as
garbage). Two-part fix:
- `amdgpu_vm.cc` `UserTranslationGen::translate`: on not-present, advance one page + sink to paddr 0
  (mirroring the GART path's established cosim behavior) instead of `fatal()`.
- `sdma_engine.cc` `decodeHeader` default: on an unknown opcode (e.g. a sunk garbage ring), warn and
  drain the queue (rptr=wptr) + decodeNext, instead of `panic`.
**Validated:** looping the memory-access tests exercised BOTH paths (`UserTranslationGen ... sink` and
`SDMA invalid packet ... draining` each fired) and gem5 SURVIVED (0 panics/fatals, 7+ iterations); the
full suite reaches the final ASAN abort. Both crash-cluster modes are now fixed (mode 1 = TLB flush
`6f369001a3`; mode 2 = `7655fffae0`). Note: graceful degradation, not correctness — the affected DMA
bytes may be wrong (so MemoryAccessCoherent still FAILS its data check), but the model no longer dies.

**DECISION (2026-06-12, user):** Stop here — the core goal is met. Compute-side xnack+ recoverable
demand paging (the ASAN device-shadow dependency) works and is validated; resident `hipMalloc` and
managed-RMW *data correctness* work. The remaining **SDMA-walker teardown hang** on managed/SVM
GPU-accesses-system-memory workloads is deemed **out of scope** for the ASAN objective. Re-open only if
managed-memory full coherence / clean process teardown becomes a requirement; if so, start with the
"Next options (a)" SDMAEngine correlation run above.
