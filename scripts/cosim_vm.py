#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
"""cosim_vm.py - orchestrate the layered cosim guest disk and launch the cosim.

The guest disk is a qcow2 backing chain ordered by change frequency:

    base  (OS, rare)  ->  kernel  ->  driver  ->  rocm  (nightly)

Each layer's parameters live in a JSON manifest (default: cosim-vm.json). This
tool fingerprints every layer (its config + its provisioning script + its packer
template + its parent's fingerprint) and rebuilds only the layers whose
fingerprint changed, plus all descendants (a qcow2 overlay is invalidated when
its backing changes). The ROCm layer can be sourced from a TheRock CI workflow
run URL (e.g. the Multi-Arch CI ASAN nightly) or from the radeon apt repo.

Subcommands:
    build    bring the chain up to date (rebuild changed layers + descendants)
    launch   create a per-run scratch overlay on the top layer and boot the cosim
    status   show each layer's configured params and built/stale state
    clean    remove a layer's output (and, implicitly, invalidate descendants)

Examples:
    python3 scripts/cosim_vm.py status
    python3 scripts/cosim_vm.py build
    python3 scripts/cosim_vm.py build --only rocm --force
    python3 scripts/cosim_vm.py launch -- --gem5-debug SDMAEngine
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Logical layer order, lowest (backing) first.
LAYER_ORDER = ["base", "kernel", "driver", "rocm"]


def log(msg):
    print(f"[cosim_vm] {msg}", flush=True)


def die(msg, code=1):
    print(f"[cosim_vm] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def sha256_str(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def parse_run_id(run_url: str) -> str:
    m = re.search(r"/actions/runs/(\d+)", run_url)
    if not m:
        die(f"could not parse a run id from run_url: {run_url!r}")
    return m.group(1)


class Cosim:
    def __init__(self, config_path: Path):
        self.cosim_dir = Path(__file__).resolve().parent.parent
        self.config_path = config_path
        self.manifest = json.loads(config_path.read_text())
        layers_rel = self.manifest.get(
            "layers_dir", "gem5-resources/src/x86-ubuntu-gpu-ml/layers"
        )
        self.layers_dir = (self.cosim_dir / layers_rel).resolve()
        if not self.layers_dir.is_dir():
            die(f"layers_dir not found: {self.layers_dir}")
        self.state_path = self.layers_dir / ".cosim-layers-state.json"
        self.qemu_build = self.cosim_dir / "qemu" / "build"

    # ---- layer specifications ------------------------------------------------
    def layer_spec(self, name: str) -> dict:
        """Return build metadata for a logical layer based on the manifest."""
        ld = self.layers_dir
        cfg = self.manifest.get(name, {})
        if name == "base":
            return {
                "name": "base",
                "pkr": ld / "base.pkr.hcl",
                "script": ld / "scripts" / "base-install.sh",
                "config": cfg,
                "build": ["./build-base.sh"],
                "image": ld / "disk-image-base" / "x86-ubuntu-2404-base.qcow2",
            }
        if name == "kernel":
            kver = cfg.get("version") or die("kernel.version is required")
            return {
                "name": "kernel",
                "pkr": ld / "kernel.pkr.hcl",
                "script": ld / "scripts" / "kernel-install.sh",
                "config": cfg,
                "build": ["./build-layer.sh", "kernel",
                          "-var", f"kernel_version={kver}"],
                "image": ld / "disk-image-kernel" / "kernel.qcow2",
                "vmlinux": ld / "disk-image-kernel" / f"vmlinux-{kver}",
                "kver": kver,
            }
        if name == "driver":
            dver = cfg.get("amdgpu_repo_ver") or die(
                "driver.amdgpu_repo_ver is required")
            kver = self.manifest.get("kernel", {}).get("version", "")
            build = ["./build-layer.sh", "driver",
                     "-var", f"amdgpu_repo_ver={dver}"]
            if kver:
                build += ["-var", f"kernel_version={kver}"]
            if cfg.get("amdgpu_pkg_ver"):
                build += ["-var", f"amdgpu_pkg_ver={cfg['amdgpu_pkg_ver']}"]
            return {
                "name": "driver",
                "pkr": ld / "driver.pkr.hcl",
                "script": ld / "scripts" / "driver-install.sh",
                "config": cfg,
                "build": build,
                "image": ld / "disk-image-driver" / "driver.qcow2",
            }
        if name == "rocm":
            return self._rocm_spec(cfg)
        die(f"unknown layer {name}")

    def _rocm_spec(self, cfg: dict) -> dict:
        ld = self.layers_dir
        source = cfg.get("source", "apt")
        if source == "apt":
            rver = cfg.get("version") or die("rocm.version is required for apt source")
            return {
                "name": "rocm",
                "pkr": ld / "rocm.pkr.hcl",
                "script": ld / "scripts" / "rocm-layer-install.sh",
                "config": cfg,
                "build": ["./build-layer.sh", "rocm", "-var", f"rocm_ver={rver}"],
                "image": ld / "disk-image-rocm" / "rocm.qcow2",
            }
        if source == "therock-asan":
            repo = cfg.get("therock_repo", "ROCm/TheRock")
            run_url = cfg.get("run_url")
            run_id = parse_run_id(run_url) if run_url else self._discover_asan_run(repo)
            family = cfg.get("amdgpu_family", "gfx94X-dcgpu")
            tests = "1" if cfg.get("tests", True) else "0"
            env = cfg.get("env", {})
            extra_env = "\n".join(f"{k}={v}" for k, v in env.items())
            image = ld / "disk-image-rocm-asan" / "rocm-asan.qcow2"
            driver_image = self.layer_spec("driver")["image"]
            return {
                "name": "rocm",
                "pkr": None,
                "script": ld / "build-rocm-asan.sh",
                "config": cfg,
                "host_build": True,
                "build": ["./build-rocm-asan.sh"],
                "build_env": {
                    "RUN_ID": run_id,
                    "AMDGPU_FAMILY": family,
                    "DRIVER_IMAGE": str(driver_image),
                    "OUTPUT_IMAGE": str(image),
                    "TESTS": tests,
                    "THEROCK_REPO": repo,
                    "THEROCK_REF": cfg.get("therock_ref", "main"),
                    "COMPONENTS": cfg.get("components", ""),
                    "EXTRA_ENV": extra_env,
                },
                "image": image,
                "run_id": run_id,
                "fp_extra": run_id,
            }
        die(f"unknown rocm.source: {source!r} (expected 'apt' or 'therock-asan')")

    def _discover_asan_run(self, repo: str) -> str:
        """Latest successful scheduled run of the ASAN workflow on main."""
        if getattr(self, "_asan_run_id", None):
            return self._asan_run_id
        try:
            out = subprocess.run(
                ["gh", "run", "list", "--repo", repo,
                 "--workflow", "multi_arch_ci_asan.yml",
                 "--event", "schedule", "--branch", "main", "--status", "success",
                 "--limit", "1", "--json", "databaseId,url,createdAt"],
                capture_output=True, text=True, timeout=60)
        except FileNotFoundError:
            die("gh not found; set rocm.run_url explicitly or install gh")
        if out.returncode != 0:
            die(f"gh run list failed: {out.stderr.strip()}")
        runs = json.loads(out.stdout)
        if not runs:
            die("no successful scheduled ASAN run found on main; set rocm.run_url")
        self._asan_run_id = str(runs[0]["databaseId"])
        log(f"discovered latest scheduled ASAN run: {runs[0]['url']} "
            f"({runs[0].get('createdAt', '')})")
        return self._asan_run_id

    # ---- fingerprints / state -----------------------------------------------
    def fingerprint(self, spec: dict, parent_fp: str) -> str:
        if not spec["script"].is_file():
            die(f"missing build script for layer {spec['name']}: {spec['script']}")
        parts = [json.dumps(spec["config"], sort_keys=True)]
        if spec.get("pkr"):
            if not spec["pkr"].is_file():
                die(f"missing packer template for layer {spec['name']}: {spec['pkr']}")
            parts.append(sha256_file(spec["pkr"]))
        parts.append(sha256_file(spec["script"]))
        if spec.get("fp_extra"):
            parts.append(str(spec["fp_extra"]))
        parts.append(parent_fp)
        return sha256_str("\n".join(parts))

    def load_state(self) -> dict:
        if self.state_path.is_file():
            return json.loads(self.state_path.read_text())
        return {}

    def save_state(self, state: dict):
        self.state_path.write_text(json.dumps(state, indent=2) + "\n")

    def plan(self):
        """Return (specs, fingerprints, rebuild_set) for the current manifest."""
        state = self.load_state()
        specs, fps = {}, {}
        parent_fp = ""
        rebuild = set()
        rebuilding_downstream = False
        for name in LAYER_ORDER:
            spec = self.layer_spec(name)
            fp = self.fingerprint(spec, parent_fp)
            specs[name] = spec
            fps[name] = fp
            prev = state.get(name, {})
            stale = (
                rebuilding_downstream
                or prev.get("fingerprint") != fp
                or not spec["image"].is_file()
            )
            if stale:
                rebuild.add(name)
                rebuilding_downstream = True
            parent_fp = fp
        return specs, fps, rebuild, state

    # ---- commands -----------------------------------------------------------
    def cmd_status(self, _args):
        specs, fps, rebuild, state = self.plan()
        log(f"manifest: {self.config_path}")
        log(f"layers_dir: {self.layers_dir}")
        print(f"\n{'layer':8} {'state':9} {'detail'}")
        print("-" * 70)
        for name in LAYER_ORDER:
            spec = specs[name]
            built = spec["image"].is_file()
            st = "REBUILD" if name in rebuild else ("ok" if built else "missing")
            detail = self._detail(name, spec)
            print(f"{name:8} {st:9} {detail}")
        print()
        if rebuild:
            log("stale layers (will rebuild on `build`): "
                + ", ".join(n for n in LAYER_ORDER if n in rebuild))
        else:
            log("everything up to date")

    def _detail(self, name, spec):
        cfg = spec["config"]
        if name == "base":
            return f"ubuntu={cfg.get('ubuntu', '?')}"
        if name == "kernel":
            return f"version={spec['kver']}"
        if name == "driver":
            return f"amdgpu_repo_ver={cfg.get('amdgpu_repo_ver', '?')}"
        if name == "rocm":
            if cfg.get("source") == "therock-asan":
                return f"therock-asan run_id={spec.get('run_id')} family={cfg.get('amdgpu_family')}"
            return f"apt version={cfg.get('version')}"
        return ""

    def cmd_build(self, args):
        specs, fps, rebuild, state = self.plan()
        if args.only:
            if args.only not in LAYER_ORDER:
                die(f"--only must be one of {LAYER_ORDER}")
            # Build only this layer (and its descendants if forced/stale).
            idx = LAYER_ORDER.index(args.only)
            allowed = set(LAYER_ORDER[idx:])
            rebuild = (rebuild | {args.only}) & allowed if args.force else (rebuild & allowed)
        if args.force and not args.only:
            rebuild = set(LAYER_ORDER)

        if specs["rocm"]["config"].get("source") == "therock-asan":
            self._validate_run(specs["rocm"])

        order = [n for n in LAYER_ORDER if n in rebuild]
        if not order:
            log("nothing to build; everything up to date")
            return
        log("build order: " + " -> ".join(order))
        for name in order:
            spec = specs[name]
            self._build_layer(spec)
            # Persist state for this layer immediately after success.
            entry = {"fingerprint": fps[name], "image": str(spec["image"])}
            if name == "kernel":
                entry["vmlinux"] = str(spec["vmlinux"])
                entry["kver"] = spec["kver"]
            if name == "rocm":
                entry["source"] = spec["config"].get("source", "apt")
                if "run_id" in spec:
                    entry["run_id"] = spec["run_id"]
            state[name] = entry
            self.save_state(state)
            log(f"layer '{name}' built -> {spec['image']}")
        log("build complete")

    def _validate_run(self, spec):
        run_id = spec.get("run_id")
        repo = spec["config"].get("therock_repo", "ROCm/TheRock")
        try:
            out = subprocess.run(
                ["gh", "run", "view", run_id, "--repo", repo,
                 "--json", "conclusion,workflowName,status"],
                capture_output=True, text=True, timeout=30)
            if out.returncode != 0:
                log(f"WARN: could not validate run {run_id} via gh: {out.stderr.strip()}")
                return
            info = json.loads(out.stdout)
            wf, concl, status = info.get("workflowName", "?"), info.get(
                "conclusion", "?"), info.get("status", "?")
            log(f"run {run_id}: workflow={wf!r} status={status} conclusion={concl}")
            if concl not in ("success", ""):
                log(f"WARN: run {run_id} conclusion is {concl!r} (artifacts may be incomplete)")
            if "asan" not in wf.lower():
                log(f"WARN: run {run_id} workflow {wf!r} is not an ASAN workflow")
        except FileNotFoundError:
            log("WARN: gh not found; skipping run validation")
        except Exception as e:  # noqa: BLE001
            log(f"WARN: run validation skipped: {e}")

    def _build_layer(self, spec):
        name = spec["name"]
        cmd = list(spec["build"])
        env = None
        if spec.get("host_build"):
            # Host-side build (e.g. rocm-asan): pass parameters via env, not -var.
            env = os.environ.copy()
            env.update(spec.get("build_env", {}))
        elif name != "base":
            # Packer overlay layers: pin the input image to the parent's path.
            parent = LAYER_ORDER[LAYER_ORDER.index(name) - 1]
            parent_image = self.layer_spec(parent)["image"]
            cmd += ["-var", f"input_image={parent_image}"]
        log(f"building '{name}': {' '.join(cmd)}")
        r = subprocess.run(cmd, cwd=self.layers_dir, env=env)
        if r.returncode != 0:
            die(f"layer '{name}' build failed (exit {r.returncode})")

    def cmd_launch(self, args):
        specs, fps, rebuild, state = self.plan()
        if rebuild and not args.no_build:
            log("chain is stale; building first (use --no-build to skip)")
            self.cmd_build(argparse.Namespace(only=None, force=False))
            state = self.load_state()

        top = specs["rocm"]["image"]
        if not top.is_file():
            die(f"top layer image missing: {top} (run `build` first)")
        kstate = state.get("kernel", {})
        vmlinux = Path(kstate.get("vmlinux", specs["kernel"].get("vmlinux", "")))
        if not vmlinux.is_file():
            die(f"kernel vmlinux missing: {vmlinux} (rebuild kernel layer)")

        launch = self.cosim_dir / "scripts" / "cosim_launch.sh"
        if not launch.is_file():
            die(f"cosim_launch.sh not found: {launch}")

        qemu_img = self.qemu_build / "qemu-img"
        if not qemu_img.is_file():
            die(f"qemu-img not found: {qemu_img}")

        scratch = Path(tempfile.gettempdir()) / f"cosim-scratch-{os.getpid()}.qcow2"
        log(f"creating per-run scratch overlay {scratch} on {top.name}")
        r = subprocess.run([str(qemu_img), "create", "-q", "-f", "qcow2",
                            "-b", str(top), "-F", "qcow2", str(scratch)])
        if r.returncode != 0:
            die("failed to create scratch overlay")
        try:
            cmd = [str(launch),
                   "--disk-image", str(scratch),
                   "--disk-format", "qcow2",
                   "--kernel", str(vmlinux)] + args.passthrough
            log("launching: " + " ".join(cmd))
            subprocess.run(cmd, cwd=self.cosim_dir)
        finally:
            if scratch.exists():
                scratch.unlink()
                log(f"removed scratch overlay {scratch}")

    def cmd_adopt(self, _args):
        """Record fingerprints for already-built layer images (no rebuild).

        Use after building layers manually (build-base.sh / build-layer.sh) so
        the orchestrator treats them as up to date for the current manifest.
        """
        specs, fps, _rebuild, state = self.plan()
        for name in LAYER_ORDER:
            spec = specs[name]
            if not spec["image"].is_file():
                log(f"skip '{name}' (image missing: {spec['image']})")
                continue
            entry = {"fingerprint": fps[name], "image": str(spec["image"])}
            if name == "kernel":
                entry["vmlinux"] = str(spec["vmlinux"])
                entry["kver"] = spec["kver"]
            if name == "rocm":
                entry["source"] = spec["config"].get("source", "apt")
                if "run_id" in spec:
                    entry["run_id"] = spec["run_id"]
            state[name] = entry
            log(f"adopted '{name}' -> {spec['image']}")
        self.save_state(state)
        log("adopt complete")

    def cmd_clean(self, args):
        state = self.load_state()
        targets = [args.layer] if args.layer else LAYER_ORDER
        for name in targets:
            spec = self.layer_spec(name)
            out_dir = spec["image"].parent
            if out_dir.is_dir():
                log(f"removing {out_dir}")
                subprocess.run(["rm", "-rf", str(out_dir)])
            state.pop(name, None)
        self.save_state(state)
        log("clean complete")


def main():
    p = argparse.ArgumentParser(description="Layered cosim VM orchestrator")
    p.add_argument("--config", default=None,
                   help="manifest JSON (default: <cosim-gpu>/cosim-vm.json)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="show layer build state")

    b = sub.add_parser("build", help="build/refresh the layer chain")
    b.add_argument("--only", help="only (re)build this layer (and descendants)")
    b.add_argument("--force", action="store_true",
                   help="rebuild regardless of fingerprints")

    l = sub.add_parser("launch", help="boot the cosim on a per-run scratch overlay")
    l.add_argument("--no-build", action="store_true",
                   help="do not auto-build a stale chain before launching")
    l.add_argument("passthrough", nargs=argparse.REMAINDER,
                   help="args after `--` are passed to cosim_launch.sh")

    sub.add_parser("adopt", help="record fingerprints for already-built images")

    c = sub.add_parser("clean", help="remove built layer output(s)")
    c.add_argument("--layer", help="only clean this layer (default: all)")

    args = p.parse_args()

    cosim_dir = Path(__file__).resolve().parent.parent
    config_path = Path(args.config) if args.config else cosim_dir / "cosim-vm.json"
    if not config_path.is_file():
        die(f"manifest not found: {config_path}")

    c = Cosim(config_path)
    if args.cmd == "status":
        c.cmd_status(args)
    elif args.cmd == "build":
        c.cmd_build(args)
    elif args.cmd == "launch":
        # Drop a leading "--" separator if argparse kept it.
        if args.passthrough and args.passthrough[0] == "--":
            args.passthrough = args.passthrough[1:]
        c.cmd_launch(args)
    elif args.cmd == "adopt":
        c.cmd_adopt(args)
    elif args.cmd == "clean":
        c.cmd_clean(args)


if __name__ == "__main__":
    main()
