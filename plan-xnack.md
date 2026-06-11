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
