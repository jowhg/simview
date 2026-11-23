#!/usr/bin/env python3
"""Benchmark one simulator viewer (DeviceHub or simview) under the same workloads.

For each scenario (idle, anim, scroll) it runs two passes on the same workload:
  1. CPU/RAM pass: per-process CPU time consumed during the window, grouped (viewer, video
     pipeline, CoreDevice, CoreSimulator rendering, WindowServer, simulators), plus the
     viewer's phys_footprint.
  2. FPS pass: simbench.app counts the distinct frames the viewer's window shows each second.
The two passes are separate so the screen capture never pollutes the CPU numbers.

Usage: bench.py <label> <viewer-pid> <out.json> --active UDID [UDID...] [--title T] [--duration 20]
"""
import argparse
import json
import os
import re
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROCSTAT = os.path.join(HERE, "procstat")
SIMBENCH = os.path.join(HERE, "simbench.app")
DTUHIDTEST = os.path.join(ROOT, "dtuhidtest")

GROUPS = [
    ("video pipeline", re.compile(r"VTEncoderXPCService|VTDecoderXPCService|SimStreamProcessorService|avconferenced")),
    ("CoreDevice", re.compile(r"CoreDeviceService|remotepairingd|DeviceFS")),
    ("sim rendering", re.compile(r"SimRenderServer|SimMetalHost|SimAudioProcessorService")),
    ("simulators", re.compile(r"\.simruntime/|launchd_sim|CoreSimulator/Devices/|Platforms/iphoneos/usr/libexec")),
]
TOOLING = re.compile(r"procstat|simbench|dtuhidtest|simctl|python|/bash$|/zsh$|/sleep$|/perl$")
ANIM_APPS = ["com.apple.Preferences", "com.apple.mobileslideshow", "com.apple.Maps", "com.apple.mobilecal"]


def snapshot():
    procs = {}
    for line in subprocess.run([PROCSTAT], capture_output=True, text=True).stdout.splitlines():
        pid, cpu, foot, path = line.split("\t", 3)
        procs[int(pid)] = (int(cpu), int(foot), path)
    # WindowServer belongs to another user: proc_pid_rusage is denied, ps still reports its CPU time.
    out = subprocess.run(["ps", "-A", "-o", "pid=,time=,comm="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "WindowServer" in line:
            pid, t = line.split()[:2]
            m, s = t.split(":")[-2:]
            h = t.split(":")[0] if t.count(":") == 2 else "0"
            procs[int(pid)] = (int((int(h) * 3600 + int(m) * 60 + float(s)) * 1e9), -1, "WindowServer")
    return procs


def group_of(pid, path, viewer_pid):
    if pid == viewer_pid:
        return "viewer"
    if path == "WindowServer":
        return "WindowServer"
    for name, rx in GROUPS:
        if rx.search(path):
            return name
    return None if TOOLING.search(path) else "other"


def cpu_by_group(before, after, viewer_pid, seconds):
    totals = {}
    for pid, (cpu1, _, path) in after.items():
        if pid not in before or cpu1 < 0 or before[pid][0] < 0:
            continue
        g = group_of(pid, path, viewer_pid)
        if g:
            totals[g] = totals.get(g, 0) + (cpu1 - before[pid][0])
    # percent of one core, averaged over the window
    return {g: round(ns / 1e9 / seconds * 100, 1) for g, ns in sorted(totals.items())}


def simctl(*args):
    subprocess.run(["xcrun", "simctl", *args], capture_output=True)


def prepare(scenario, udids):
    for u in udids:
        simctl("terminate", u, "com.apple.Preferences")
        if scenario == "scroll":
            simctl("launch", u, "com.apple.Preferences")
        else:
            subprocess.run([DTUHIDTEST, u, "home"], capture_output=True)
    time.sleep(4)


def start_workload(scenario, udids, seconds):
    if scenario == "idle":
        return []
    if scenario == "scroll":
        return [subprocess.Popen([DTUHIDTEST, u, "scroll", str(seconds)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for u in udids]
    # anim: bring a different app to the front every 1.5 s on each active simulator
    script = "; ".join(
        f"xcrun simctl launch {u} {app} >/dev/null 2>&1 &" for u in udids for app in ["$a"]
    )
    loop = f'end=$((SECONDS+{seconds})); while [ $SECONDS -lt $end ]; do for a in {" ".join(ANIM_APPS)}; do {script} sleep 1.5; done; done'
    return [subprocess.Popen(["/bin/bash", "-c", loop], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]


def stop(workers):
    for w in workers:
        try:
            w.wait(timeout=10)
        except subprocess.TimeoutExpired:
            w.kill()


def run(args):
    results = {"label": args.label, "viewer_pid": args.viewer_pid, "duration": args.duration, "scenarios": {}}
    for scenario in args.scenarios.split(","):
        print(f"[{args.label}] {scenario}: CPU/RAM pass", flush=True)
        prepare(scenario, args.active)
        before = snapshot()
        t0 = time.time()
        workers = start_workload(scenario, args.active, args.duration)
        time.sleep(args.duration)
        after = snapshot()
        elapsed = time.time() - t0
        stop(workers)
        cpu = cpu_by_group(before, after, args.viewer_pid, elapsed)
        viewer_foot = after.get(args.viewer_pid, (0, 0, ""))[1]

        print(f"[{args.label}] {scenario}: FPS pass", flush=True)
        prepare(scenario, args.active)
        fps_path = os.path.join(HERE, f"fps-{args.label}-{scenario}.json")
        if os.path.exists(fps_path):
            os.remove(fps_path)
        bench = ["open", "-W", "-n", SIMBENCH, "--args", str(args.viewer_pid), str(args.duration), fps_path]
        if args.title:
            bench.append(args.title)
        capture = subprocess.Popen(bench)
        time.sleep(1.5)  # let the capture start before the workload
        workers = start_workload(scenario, args.active, args.duration)
        capture.wait(timeout=args.duration + 30)
        stop(workers)
        fps = json.load(open(fps_path)) if os.path.exists(fps_path) else {"error": "no fps output"}

        results["scenarios"][scenario] = {
            "cpu_percent_by_group": cpu,
            "viewer_footprint_mb": round(viewer_foot / 1048576),
            "fps": fps,
        }
        print(json.dumps(results["scenarios"][scenario]["cpu_percent_by_group"]), "| viewer",
              results["scenarios"][scenario]["viewer_footprint_mb"], "MB | fps",
              fps.get("mean", fps.get("error")), flush=True)
    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("label")
    p.add_argument("viewer_pid", type=int)
    p.add_argument("out")
    p.add_argument("--active", nargs="+", required=True)
    p.add_argument("--title")
    p.add_argument("--duration", type=int, default=20)
    p.add_argument("--scenarios", default="idle,anim,scroll")
    run(p.parse_args())
