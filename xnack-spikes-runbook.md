# xnack+ Live Spike Runbook

Spikes to run on a booted cosim before committing Phase 4. Each has an exact command and the
concrete artifact to capture. Boot with `./scripts/cosim_launch.sh` (gem5 in the `gem5-cosim`
docker container + QEMU; guest auto-logs in as root on the serial console and runs
`cosim-gpu-setup.service`).

Capture locations:
- gem5 log: `docker logs gem5-cosim 2>&1 | tee /tmp/gem5.log`
- guest console: the QEMU serial terminal (auto-login root).

---

## S2 — Is the agent reported as `gfx942:xnack+`?

Goal: confirm the disk's `HSA_XNACK=1` + the `mi300_discovery` blob make the stock runtime/KFD
advertise xnack+. Decides whether Phase 1 suffices or the discovery blob must be patched (S3).

In the guest:
```bash
rocminfo | grep -iE "Name:|gfx|xnack|svm"          # look for "gfx942:xnack+"
cat /sys/class/kfd/kfd/topology/nodes/*/properties | grep -iE "capability|simd_count"
echo "HSA_XNACK=$HSA_XNACK"
```
Capture: the agent Name string and the `capability` hex value.
- PASS: Name shows `gfx942:xnack+`.
- FAIL: shows `gfx942` or `:xnack-` → discovery blob lacks the xnack/SVM capability bit → do S3
  (patch `mi300_discovery` / KFD capability) before Phase 1 is usable.

---

## Retry-arming check — does the driver set `VM_CONTEXT1_CNTL` bit 7?

Goal: `AMDGPUDevice::raiseVmFault` only fires recoverable faults if retry is armed
(`retryFaultEnabled`). If the stripped driver init never sets it, Phase 4 can't trigger.

The Phase 3 `contextCntl` capture already runs on the GRBM write path; add a temporary log to make
it visible (throwaway, do not commit):
```cpp
// amdgpu_vm.cc writeMMIOGfx940, in the VM_CONTEXTn_CNTL capture block:
warn("CNTL ctx%d = %#x (retry bit7=%d)", offset - MI300X_VM_CONTEXT0_CNTL,
     pkt->getLE<uint32_t>(), (int)bits(pkt->getLE<uint32_t>(), 7, 7));
```
Run any GPU workload, then:
```bash
docker logs gem5-cosim 2>&1 | grep "CNTL ctx"
```
Capture: whether any context shows `retry bit7=1`.
- PASS: at least one user context (ctx >= 1) has bit7=1.
- FAIL: never set → investigate driver init (HSA_XNACK propagation, ip_block_mask, KFD svm setup)
  before Phase 4. Possibly the xnack mode isn't actually active (ties to S2).

---

## S6 — Does gem5 execute a real `gfx942:xnack+` code object?

Goal: confirm the `_ec` early-clobber opcodes and reserved `s[104:105]` don't trip the gem5
decoder. Use a trivial kernel with pre-resident memory (no faults).

On a host with ROCm (or in the guest), build both variants:
```bash
hipcc --offload-arch=gfx942:xnack+ -o /tmp/vadd_xnack vadd.cpp
hipcc --offload-arch=gfx942:xnack- -o /tmp/vadd_noxnack vadd.cpp
llvm-objdump -d /tmp/vadd_xnack | grep -iE "_ec|s10[45]" | head   # confirm xnack codegen present
```
Run `vadd_xnack` under cosim (memory via `hipMalloc`, pre-resident).
Capture: completes correctly vs. gem5 "unknown/illegal instruction" in the log.
- PASS: correct result.
- FAIL: collect the offending opcode from the gem5 log → may need a decoder addition.

---

## S7 — Hostcall round-trip (needed for ASAN reporting)

Goal: ASAN reports via `__ockl_sanitizer_report` → hostcall; confirm the mechanism works in cosim.
Cheapest probe is device `printf`:
```cpp
__global__ void k() { printf("hostcall from lane %d\n", (int)threadIdx.x); }
```
Run under cosim; check the host/guest sees the printf output.
- PASS: printf text appears → hostcall ring + host handler work.
- FAIL: note the failing stage (buffer setup vs doorbell vs demand-paged buffer — the last is
  unblocked only after Phase 4).

---

## S5 — Park feasibility (the gating spike for Phase 4 / risk R1)

Goal: prove the CU/coalescer tolerate an arbitrarily delayed translation response (i.e. a parked
walk) without deadlock or timeout — WITHOUT needing real fault recovery. We inject an artificial
delay into one translation and confirm the kernel still completes correctly.

Throwaway patch (do NOT commit) in `pagetable_walker.cc`, around `Walker::walkerResponse`:
```cpp
// S5 spike: delay the first N translation responses by D ticks to emulate a
// parked walk, proving the CU tolerates long-latency translations.
static int s5_delayed = 0;
void
Walker::walkerResponse(WalkerState *state, VegaTlbEntry& entry, PacketPtr pkt)
{
    if (s5_delayed < 4) {                 // delay only the first few
        s5_delayed++;
        Tick d = 100000;                  // ~100ns at 1ps; try 1e6, 1e8 too
        auto *ev = new EventFunctionWrapper(
            [this, state, entry, pkt]() mutable {
                tlb->walkerResponse(entry, pkt);
                delete state;
            }, name()+".s5delay", true);
        schedule(*ev, curTick() + d);
        return;
    }
    tlb->walkerResponse(entry, pkt);
    delete state;
}
```
Run a known-good workload (e.g. `square`/`vadd`) under cosim with increasing `d`
(1e5, 1e6, 1e8 ticks).
Capture: does the kernel still produce correct results at large delay?
- PASS (correct at large delay): parking is safe → Phase 4 translation-layer park is viable;
  implement per `xnack-phase4-draft.md`.
- FAIL (hang / wrong result / assert): the coalescer/CU has a latency assumption → translation-
  layer park won't work as-is; fall back to wavefront-level replay (larger rework) and revise the
  plan before coding Phase 4.

---

## Order
Run S2 + retry-arming first (cheap, and they gate whether Phase 4 can fire at all), then S5 (the
go/no-go for the Phase 4 approach), then S6/S7 (ASAN execution + reporting prerequisites). Record
results back into `plan-xnack.md` and re-scope Phase 4 accordingly.
