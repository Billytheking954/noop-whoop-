#!/usr/bin/env python3
"""Collect repeated process-cold launch evidence from a disposable seeded simulator.

No simulator is erased and no database is reset. This is not hardware performance,
radio, battery, first-paint or physical HealthKit validation. Host networking stays enabled.
"""
import argparse
import json
import pathlib
import plistlib
import statistics
import subprocess
import time


def command(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True).stdout.strip()


def collect(udid, bundle, output):
    output.mkdir(parents=True, exist_ok=True)
    source = command("git", "rev-parse", "HEAD")
    device = json.loads(command("xcrun", "simctl", "list", "devices", "-j"))
    samples = []
    prefix = "noop.diagnostics.coldRootLoad."
    for appearance in ("light", "dark"):
        command("xcrun", "simctl", "ui", udid, "appearance", appearance)
        for index in range(3):
            command("xcrun", "simctl", "terminate", udid, bundle, check=False)
            started = time.monotonic()
            launched = command("xcrun", "simctl", "launch", udid, bundle, "--demo-seed", "--simulator-validation")
            pid = int(launched.rsplit(":", 1)[-1].strip())
            data = pathlib.Path(command("xcrun", "simctl", "get_app_container", udid, bundle, "data"))
            prefs_path = data / "Library/Preferences" / (bundle + ".plist")
            # Preferences are read after termination, when cfprefsd has flushed them.
            time.sleep(15)
            command("xcrun", "simctl", "io", udid, "screenshot", str(output / f"repeat-{appearance}-{index}.png"))
            command("xcrun", "simctl", "terminate", udid, bundle)
            time.sleep(1)
            prefs = plistlib.loads(prefs_path.read_bytes())
            timings = {k.removeprefix(prefix): v for k, v in prefs.items() if k.startswith(prefix)}
            sample = {"appearance": appearance, "index": index, "timings": timings,
                      "seed_reference_epoch": prefs.get("noop.simulator.seedReferenceEpoch"),
                      "observation_window_seconds": time.monotonic() - started}
            samples.append(sample)
            (output / "launch-samples.json").write_text(json.dumps(samples, indent=2) + "\n")
            assert timings.get("processIdentifier") == pid, "Stale preferences must not masquerade as this launch"
            assert prefs.get("noop.simulator.offlineValidatedPID") == pid, "Simulated offline URL loading must be verified in this process"
            assert timings.get("cacheLoaded") is True, sample
            assert timings.get("cachedDays", 0) >= 120, sample
            assert timings.get("todayDataLoadSeconds", 0) > 0, sample
    summary = {}
    for key in sorted(set().union(*(s["timings"] for s in samples))):
        if key not in ("seconds", "todayDataLoadSeconds") and not key.startswith(("phase.", "milestone.", "count.")):
            continue
        values = [s["timings"][key] for s in samples if key in s["timings"]]
        if len(values) == len(samples) and all(type(v) in (int, float) for v in values):
            summary[key] = {"min": min(values), "median": statistics.median(values),
                            "max": max(values), "pstdev": statistics.pstdev(values)}
    (output / "summary.json").write_text(json.dumps({
        "source_sha": source, "device_inventory": device, "udid": udid,
        "environment": "GitHub-hosted macOS / iOS Simulator / DEBUG / 400 synthetic days / URLProtocol offline injection",
        "launches": samples, "summary": summary,
        "limitations": "Process restarts with an existing OS/filesystem cache. Host networking enabled; no strap or new import. seconds, todayDataLoadSeconds and milestone.* share the ColdLaunchTrace.begin origin; do not add them. phase.* is the first interval (possibly interrupted); count.* counts starts, not completed calculations. View score observation is not GPU presentation or proof all cards populated. Not first paint, physical iPhone performance, BLE, battery or physiological accuracy."
    }, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid")
    parser.add_argument("bundle")
    parser.add_argument("output", type=pathlib.Path)
    options = parser.parse_args()
    collect(options.udid, options.bundle, options.output)
