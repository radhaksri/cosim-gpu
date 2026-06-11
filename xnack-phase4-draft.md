# Phase 4 Draft — Translation-layer park-and-retry (xnack+)

Status: **design draft** (not yet implemented). Depends on Phase 3 (committed) compiling and on
spike S5 (park/re-walk feasibility). This document fixes the exact insertion points, data
structures, and code shape so implementation is mechanical once the Phase 3 build is green.

## Goal

When a gfx942 GPU translation finds no valid PTE *and* the driver has armed retry faults, instead
of the current "sink to paddr 0" hack: raise a recoverable VM fault to the guest (Phase 3
`raiseVmFault`), **park** the page-table walk, and **re-run** it after the driver installs the PTE
and issues a VM invalidate. The waiting wavefront simply sees a long-latency translation (it sits
on `vmcnt`), so no compute-pipeline replay is needed — this is the key simplification (compiler
guarantees the access is restartable; see plan-xnack.md §3).

## Where it plugs in (verified file:line)

1. **Fault site / park** — `arch/amdgpu/vega/pagetable_walker.cc:213-234`
   (`WalkerState::startWalk`, the cosim `timingFault != NoFault || !entry.pte.v` branch). Today it
   fabricates a sink entry and calls `walker->walkerResponse(...)`. Phase 4 replaces this.

2. **Retry trigger** — the driver's `VM_INVALIDATE_ENG*_REQ` write. Hook in
   `amdgpu_vm.cc::writeMMIOGfx940` (REQ offset `MI300X` base `0x0883`, strided per engine), which
   already runs on the GRBM write path. On REQ write → re-run parked walks.

3. **Re-walk delivery** — reuse `Walker::walkerResponse` (`pagetable_walker.cc:545`) →
   `GpuTLB::walkerResponse` (`tlb.cc:456`) unchanged; a successful re-walk delivers the normal
   translation response and the wavefront resumes.

4. **PWC flush** — `Walker::invalidatePWC()` (`pagetable_walker.cc:514`), already exists, currently
   never called; call it before re-walking so the stale "not present" PTE isn't re-served from the
   page-walk cache (also flush the cosim PTE in `sendTiming`'s PWC insert path,
   `pagetable_walker.cc:463-465`).

## Data structures (Walker)

```cpp
// pagetable_walker.hh — Walker
std::list<WalkerState *> parkedStates;     // walks awaiting driver PTE fix
void parkState(WalkerState *s);
void retryParkedWalks();                    // called on VM_INVALIDATE REQ

// WalkerState — remember enough to re-issue the walk from scratch
Addr   walkBase   = 0;   // page-table base passed to initState
Addr   origVaddr  = 0;   // original faulting VA (entry.vaddr is mutated mid-walk)
int    retryCount = 0;   // safety cap
```

`initState` already receives `(mode, baseAddr, vaddr)` — store `walkBase=baseAddr`,
`origVaddr=vaddr` there. `mode` is already a member.

## Code sketch

### Park at the fault site (replaces `pagetable_walker.cc:213-222` sink)
```cpp
if (timingFault != NoFault || !entry.pte.v) {
    AMDGPUDevice *dev = walker->gpuVM ? walker->gpuVM->getDevice() : nullptr;
    Addr vaddr  = tlbPkt->req->getVaddr();
    uint16_t vmid = walker->gpuVM ? walker->gpuVM->vmidForBase(walker->walkBaseOf(this)) : 0;
    uint32_t pasid = dev ? dev->getProcessPasid() : 0x8000;
    bool write = (mode == BaseMMU::Write);

    if (dev && dev->raiseVmFault(vmid, pasid, vaddr, write)) {
        DPRINTF(GPUPTWalker, "Parking walk for vaddr %#lx (vmid %d) "
                "pending driver PTE fix\n", vaddr, vmid);
        walker->parkState(this);   // do NOT respond; keep state alive
        return;                    // return out of startWalk
    }
    // Fallback (retry not armed): keep legacy sink behaviour below.
    ... existing sink ...
}
```
Note: `endWalk()` (`:392`) already removed the state from `currStates` and freed `read`; parking
just retains the pointer. Do **not** `delete` it (the normal path's `walkerResponse` would).

### Retry on invalidate (Walker)
```cpp
void Walker::retryParkedWalks() {
    if (parkedStates.empty()) return;
    invalidatePWC();
    std::list<WalkerState*> ready;
    ready.swap(parkedStates);
    for (auto *s : ready) {
        if (++s->retryCount > kMaxFaultRetries) {   // safety cap, e.g. 8
            warn("xnack: walk for vaddr %#lx still faulting after %d retries; "
                 "sinking", s->origVaddr, s->retryCount);
            s->sinkAndRespond();                    // legacy fallback
            continue;
        }
        s->initState(s->mode, s->walkBase, s->origVaddr); // resets to PDE2
        currStates.push_back(s);
        s->startWalk();                              // re-reads PTEs (now valid)
    }
}
```

### Invalidate hook (amdgpu_vm.cc::writeMMIOGfx940, before the switch)
```cpp
if (offset >= MI300X_VM_INVALIDATE_ENG0_REQ &&
    offset <  MI300X_VM_INVALIDATE_ENG0_REQ + kInvalidateEngineStride*18) {
    // driver asked for a TLB invalidate -> PTEs may now be present; retry.
    for (auto *t : gpu_tlbs) t->getWalker()->retryParkedWalks();
    invalidateTLBs();   // existing
    return;
}
```
(Add `#define MI300X_VM_INVALIDATE_ENG0_REQ 0x0883` per S4. ENG ACK reads already return 1 at
`amdgpu_vm.cc:155-159`, satisfying the driver's poll.)

## The one real design gap: vmid / pasid at the fault site

The walker knows the page-table `base` and `vaddr` but **not** the VMID or PASID. Options:

- **(Recommended) reverse-map + tracked pasid.** Add `AMDGPUVM::vmidForBase(Addr base)` that scans
  `vmContexts[]` for a matching `ptBase` (and falls back to context0). Track the process PASID on
  the device from the PM4 `MAP_PROCESS` packet (the IH cookie already hardcodes `0x8000` — replace
  with the tracked value). Pragmatic for the single-process cosim and matches existing assumptions.
- **(Most accurate) thread it through `GpuTranslationState`.** Carry vmid/pasid from the CU/dispatch
  into the translation request so the walker reads them directly. More invasive; defer unless the
  reverse-map proves ambiguous.

Also wire device access: the walker has `gpuVM` but not `AMDGPUDevice*`. Add
`AMDGPUVM::getDevice()` (it already holds `gpuDevice`) so the walker can reach `raiseVmFault`.

## Safety / correctness

- **Retry cap** (`kMaxFaultRetries`) prevents an infinite park/retry loop if the driver never
  installs the PTE; on exhaustion, fall back to the legacy sink and `warn`.
- **PWC + TLB flush before re-walk** so the stale not-present entry isn't reused.
- **Reentrancy:** `retryParkedWalks()` runs inside the REQ MMIO write handler; in cosim the re-walk
  reads PTEs synchronously from VRAM shmem (`sendTiming` inline `recvTimingResp`,
  `pagetable_walker.cc:443-468`) and may call `walkerResponse`→CU within that stack. Validate this
  is safe under `atomic_noncaching` (it should be; the MMIO path is already synchronous). If not,
  schedule the re-walk on an event at `curTick()` instead.
- **PTE coherence (Phase 5 overlap):** the re-walk reads PTEs from `vramShmemPtr`; this only works
  if the driver's PTE install landed there. Confirm in S8/Phase 5 (the driver uses SDMA or HDP
  writes to VRAM, which the cosim maps to the same shmem).

## Risks
- **R1 (timing-model park):** parking a `WalkerState` indefinitely — ensure nothing in the
  coalescer/CU times out on the outstanding translation. This is exactly what spike **S5** must
  prove before committing this code.
- **R-vmid:** reverse-map could be ambiguous if multiple contexts share a base; mitigate by also
  matching the active dispatch's VMID if threaded.
- **Reentrancy** (above).

## Implementation order (once Phase 3 build is green + S5 done)
1. `AMDGPUVM::getDevice()` + `vmidForBase()`; device `getProcessPasid()` (from MAP_PROCESS).
2. `WalkerState` fields (`walkBase`, `origVaddr`, `retryCount`) + store in `initState`.
3. `Walker::parkState/retryParkedWalks` + `kMaxFaultRetries`.
4. Replace the sink at `pagetable_walker.cc:213` with the park logic.
5. Invalidate-REQ hook in `writeMMIOGfx940` + `MI300X_VM_INVALIDATE_ENG0_REQ` define.
6. Gate: a kernel touching an initially-unmapped page completes via
   fault→IH→driver-fix→invalidate→retry (needs booted cosim).
