#!/usr/bin/env python3
"""Run the frozen round-2 notebook on one bounded GPU VM; collect verified outputs."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import time

PROJECT = "rhymeai-training"
REGION = "us-central1"
IMAGE = "common-cu129-ubuntu-2404-nvidia-580-v20261001"
NOTEBOOK_SHA = "2f3a900ad5531716991955fc73aa52107d9016d78f088b98fc7c96e95887dcab"
# Ordered capacity fallback; all prices include the GPU, CPU and RAM.
TARGETS = (
    {"machine": "a2-ultragpu-1g", "accelerator": "nvidia-a100-80gb", "hours": 2,
     "region": REGION, "provisioning_model": "SPOT",
     "spot_usd_hour": 3.038823151, "on_demand_usd_hour": 5.06879789},
    {"machine": "g2-standard-12", "accelerator": "nvidia-l4", "hours": 4,
     "region": REGION, "provisioning_model": "SPOT",
     "spot_usd_hour": 0.598648, "on_demand_usd_hour": 1.000416287},
)
# G2 prices = 12 CPU + 48 GiB RAM + 1 L4; public Billing catalog, 2026-10-14.
L4_PRICES = {
    "us-central1": (0.598648, 1.000416287),
    "us-east1": (0.598648, 1.000416287),
    "us-east4": (0.532016, 0.997140504),
    "us-west1": (0.598648, 1.000416287),
    "us-west4": (0.674384, 1.126768820),
}
HERE = Path(__file__).resolve().parent


def sha256(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def gcloud(*args, check=True):
    result = subprocess.run(["gcloud", *map(str, args), f"--project={PROJECT}", "--quiet"],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result


def cloud_json(*args):
    return json.loads(gcloud(*args, "--format=json").stdout)


def external_output(path):
    mount = Path("/Volumes/Untitled")
    path = Path(path).expanduser().resolve()
    if not mount.is_mount() or mount.stat().st_dev == Path("/").stat().st_dev:
        raise ValueError("/Volumes/Untitled must be the mounted external drive")
    if not path.is_relative_to(mount / "models" / "rhymeai"):
        raise ValueError("outputs must be under /Volumes/Untitled/models/rhymeai/")
    if shutil.disk_usage(mount).free < 12_000_000_000:
        raise ValueError("need at least 12 GB free on the external drive")
    path.mkdir(parents=True, exist_ok=True)
    return path


def safe_name(name):
    if Path(name).name != name or name in ("", ".", ".."):
        raise ValueError(f"unsafe product name: {name!r}")
    return name


def run_budget(target, max_hours=None, spent_usd=0):
    if max_hours is not None and not 0 < max_hours <= 4:
        raise ValueError("max-hours must be finite and in (0, 4]")
    hours = min(target["hours"], max_hours if max_hours is not None else target["hours"])
    bound = spent_usd + hours * target["on_demand_usd_hour"] + 3
    if not 0 < hours <= 4 or not 0 <= spent_usd < 15 or bound > 15:
        raise ValueError("runtime plus prior spend exceeds the $15 envelope")
    return {**target, "max_seconds": int(hours * 3600), "task_cap_usd": 15,
            "prior_spend_usd": spent_usd, "conservative_bound_usd": bound,
            "other_usage_reserve_usd": 3, "rate_date": "2026-10-14"}


def capacity_targets(extended_l4=False):
    if not extended_l4:
        return TARGETS
    # Explicit opt-in after central Spot stockouts; never silently switch billing modes.
    regions = ("us-east1", "us-east4", "us-west1", "us-west4")
    return [{**TARGETS[1], "region": region, "provisioning_model": mode,
             "spot_usd_hour": L4_PRICES[region][0], "on_demand_usd_hour": L4_PRICES[region][1]}
            for mode, search_regions in (("SPOT", regions), ("STANDARD", (REGION,) + regions))
            for region in search_regions]


def capacity_candidates(accelerators, targets=TARGETS):
    return [(target, zone) for target in targets
            for zone in sorted({a["zone"].split("/")[-1] for a in accelerators
                                if a["name"] == target["accelerator"]
                                and a["zone"].split("/")[-1].startswith(target["region"] + "-")})]


def inventory(evidence, label):
    state = {kind: cloud_json("compute", kind, "list") for kind in ("instances", "disks")}
    write_json(evidence / f"{label}.json", state)
    return state


def event(evidence, kind, **values):
    row = {"time": dt.datetime.now(dt.timezone.utc).isoformat(), "event": kind, **values}
    with (evidence / "lifecycle.jsonl").open("a") as handle:
        handle.write(json.dumps(row) + "\n")
    print(json.dumps(row), flush=True)


def collect(bucket, run_id, output, evidence):
    # Training can outlive a drive connection; recheck before any model download.
    output = external_output(output)
    prefix = f"{bucket}/runs/{run_id}"
    for name in ("worker.log", "phases.json", "status.json", "shutdown.json"):
        result = gcloud("storage", "cp", prefix + "/" + name, evidence / name, check=False)
        if result.returncode and not any(s in result.stderr.lower() for s in ("matched no objects", "not found")):
            raise RuntimeError(result.stderr)
    # No bulk sync to the Mac: only marker-listed products enter the external drive.
    result = gcloud("storage", "cat", prefix + "/SAVED_OK", check=False)
    if result.returncode:
        shutdown = evidence / "shutdown.json"
        detail = shutdown.read_text() if shutdown.exists() else "shutdown notice unavailable; inspect operations.json"
        raise RuntimeError("Run incomplete: no SAVED_OK. " + detail +
                           " Relaunch the same package with a new run-id after checking remaining spend.")
    marker = json.loads(result.stdout)
    if marker["run_id"] != run_id:
        raise ValueError("SAVED_OK belongs to a different run")
    for name, digest in marker["products_sha256"].items():
        target = output / safe_name(name)
        partial = target.with_name(target.name + ".download")
        if target.is_symlink() or partial.is_symlink():
            raise ValueError("refuse a symlink product or download path")
        if target.exists():
            if sha256(target) == digest:
                continue
            raise ValueError(f"existing output has different bytes; preserved: {target}")
        gcloud("storage", "cp", prefix + "/products/" + name, partial)
        if sha256(partial) != digest:
            raise ValueError(f"download checksum mismatch: {name}")
        partial.rename(target)
    write_json(output / "SAVED_OK", marker)
    write_json(evidence / "download-verification.json", {
        "run_id": run_id, "destination": str(output),
        "products_sha256": {name: sha256(output / name) for name in marker["products_sha256"]}})
    return marker


def package_inputs(package, staging):
    notebook = package / "notebooks/1-rhymeai-e2b-v5.ipynb"
    if sha256(notebook) != NOTEBOOK_SHA:
        raise ValueError("this adapter requires the frozen round-2 v5 notebook (see README)")
    inputs = package / "upload/inputs"
    entries = []
    for line in (inputs / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        name = safe_name(name.lstrip("*"))
        if sha256(inputs / name) != digest:
            raise ValueError(f"package checksum mismatch: {name}")
        entries.append((inputs / name, "inputs/" + name))
    entries += [(inputs / "SHA256SUMS", "inputs/SHA256SUMS"), (notebook, "recipe.ipynb")]
    entries += [(HERE / name, name) for name in ("notebook.py", "requirements.txt")]
    archive = staging / "package.tar.gz"
    with tarfile.open(archive, "w:gz") as handle:
        for source, name in entries:
            handle.add(source, arcname=name)
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("run", "collect"))
    parser.add_argument("--package", type=Path, help="existing rhymeai-colab-package-v5 directory")
    parser.add_argument("--run-id", required=True, help="new unique name, e.g. e2b-20261014-01")
    parser.add_argument("--output", required=True, help="new directory on /Volumes/Untitled/models/rhymeai")
    parser.add_argument("--evidence", type=Path, required=True, help="small local logs, never weights")
    parser.add_argument("--max-hours", type=float, help="lower the per-GPU cap (A100: 2h; L4: 4h)")
    parser.add_argument("--spent-usd", type=float, default=0, help="prior task usage, including failed runs")
    parser.add_argument("--extended-l4", action="store_true",
                        help="after central stockouts: other US Spot L4 regions, then on-demand L4 (explicit authorization required)")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,40}[a-z0-9]", args.run_id):
        parser.error("run-id must be 2-42 lowercase letters/digits/hyphens")
    if args.max_hours is not None and not 0 < args.max_hours <= 4:
        parser.error("max-hours must be greater than zero and at most 4")
    targets = capacity_targets(args.extended_l4)
    budgets = [run_budget(target, args.max_hours, args.spent_usd) for target in targets]
    if args.action == "run" and args.package is None:
        parser.error("run requires --package")
    output = external_output(args.output)
    evidence = args.evidence.expanduser().resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    number = cloud_json("projects", "describe", PROJECT)["projectNumber"]
    bucket = f"gs://{PROJECT}-{number}-finetune"
    if args.action == "collect":
        collect(bucket, args.run_id, output, evidence)
        return
    initial = inventory(evidence, "before")
    if initial["instances"] or initial["disks"]:
        raise RuntimeError("project is not empty; refuse overlap with another run")
    buckets = cloud_json("storage", "buckets", "list")
    bucket_name = bucket.removeprefix("gs://")
    if not any(b.get("name") == bucket_name for b in buckets):
        gcloud("storage", "buckets", "create", bucket, "--location=" + REGION,
               "--uniform-bucket-level-access", "--public-access-prevention")
    policy = cloud_json("storage", "buckets", "describe", bucket)
    write_json(evidence / "bucket.json", policy)
    # Ownership was established by the project-scoped list or successful creation.
    if (policy.get("public_access_prevention") != "enforced"
            or not policy.get("uniform_bucket_level_access")
            or policy.get("location", "").lower() != REGION):
        raise RuntimeError("bucket must be project-owned, private, uniform access and in us-central1")
    prior = gcloud("storage", "ls", bucket + "/runs/" + args.run_id + "/", check=False)
    if prior.returncode == 0:
        raise RuntimeError("run-id already exists; use collect or a new run-id")
    if "matched no objects" not in prior.stderr and "not found" not in prior.stderr.lower():
        raise RuntimeError(prior.stderr)
    staging = output / ".staging"
    staging.mkdir(exist_ok=True)
    archive = package_inputs(args.package.expanduser().resolve(), staging)
    package_sha = sha256(archive)
    prefix = f"{bucket}/runs/{args.run_id}"
    gcloud("storage", "cp", archive, prefix + "/package.tar.gz")
    # An independent readback verifies SHA-256; all package copies remain external.
    readback = staging / "readback.tar.gz"
    gcloud("storage", "cp", prefix + "/package.tar.gz", readback)
    if sha256(readback) != package_sha:
        raise RuntimeError("GCS package readback SHA-256 mismatch")
    readback.unlink()
    write_json(evidence / "package.json", {"sha256": package_sha, "notebook_sha256": NOTEBOOK_SHA,
        "source_sha256": {p.name: sha256(p) for p in HERE.iterdir() if p.is_file()}})
    write_json(evidence / "budget.json", budgets)
    accelerators = cloud_json("compute", "accelerator-types", "list")
    candidates = capacity_candidates(accelerators, targets)
    write_json(evidence / "capacity-candidates.json", candidates)
    name = "rhymeai-" + args.run_id
    created = None
    attempted = []
    try:
        for target, zone in candidates:
            budget = run_budget(target, args.max_hours, args.spent_usd)
            max_seconds = budget["max_seconds"]
            attempted.append(zone)
            event(evidence, "create-request", name=name, zone=zone, machine=target["machine"],
                  provisioning_model=target["provisioning_model"])
            result = gcloud("compute", "instances", "create", name, "--zone=" + zone,
                "--machine-type=" + target["machine"], "--provisioning-model=" + target["provisioning_model"],
                "--instance-termination-action=DELETE", f"--max-run-duration={max_seconds}s",
                "--maintenance-policy=TERMINATE", "--no-restart-on-failure",
                "--image=" + IMAGE, "--image-project=deeplearning-platform-release",
                "--boot-disk-size=200GB", "--boot-disk-type=pd-balanced", "--boot-disk-auto-delete",
                f"--service-account={number}-compute@developer.gserviceaccount.com",
                "--scopes=https://www.googleapis.com/auth/cloud-platform",
                "--labels=purpose=rhymeai-finetune,run=" + args.run_id,
                f"--metadata=run-prefix={prefix},package-sha256={package_sha},image-name={IMAGE},install-nvidia-driver=True",
                f"--metadata-from-file=startup-script={HERE / 'startup.sh'},shutdown-script={HERE / 'shutdown.sh'}",
                "--format=json", check=False)
            (evidence / f"create-{target['provisioning_model'].lower()}-{target['machine']}-{zone}.log").write_text(result.stdout + result.stderr)
            if result.returncode == 0:
                created = json.loads(result.stdout)[0]
                write_json(evidence / "instance.json", created)
                event(evidence, "created", name=name, zone=zone, id=created["id"],
                      creation_timestamp=created["creationTimestamp"], machine=target["machine"],
                      provisioning_model=target["provisioning_model"])
                break
            # Only a confirmed capacity rejection may move to the next zone.
            remaining = inventory(evidence, "after-create-failure")
            if remaining["instances"] or remaining["disks"]:
                raise RuntimeError("creation failed but resources remain; cleanup required")
            if not any(code in result.stderr for code in (
                    "ZONE_RESOURCE_POOL_EXHAUSTED", "does not have enough resources", "QUOTA_EXCEEDED")):
                raise RuntimeError(result.stderr)
            event(evidence, "zone-unavailable", zone=zone, machine=target["machine"],
                  provisioning_model=target["provisioning_model"], error=result.stderr.strip())
        if created is None:
            raise RuntimeError("GPU unavailable in every requested region and provisioning mode; no quota/billing configuration changed")
        deadline = time.monotonic() + max_seconds + 300
        while time.monotonic() < deadline:
            current = cloud_json("compute", "instances", "list", "--filter=name=" + name)
            if not current:
                event(evidence, "deleted", name=name, zone=zone)
                break
            serial = gcloud("compute", "instances", "get-serial-port-output", name,
                            "--zone=" + zone, check=False)
            if serial.returncode == 0:
                (evidence / "serial.log").write_text(serial.stdout)
            time.sleep(30)
        else:
            raise RuntimeError("VM exceeded expected deletion deadline")
    finally:
        # Scope deletions to this run, including resources left by an interrupted insert.
        if attempted:
            own = cloud_json("compute", "instances", "list", "--filter=name=" + name)
            for instance in own:
                gcloud("compute", "instances", "delete", name, "--zone=" + instance["zone"].split("/")[-1])
                event(evidence, "controller-deleted", name=name)
            disks = cloud_json("compute", "disks", "list", "--filter=name=" + name)
            for disk in disks:
                if disk.get("users"):
                    raise RuntimeError("run disk is still attached; refuse blind deletion")
                gcloud("compute", "disks", "delete", disk["name"], "--zone=" + disk["zone"].split("/")[-1])
        final = inventory(evidence, "after")
        if final["instances"] or final["disks"]:
            raise RuntimeError("cleanup incomplete; see after.json")
        if created:
            rate = target["spot_usd_hour"] if target["provisioning_model"] == "SPOT" else target["on_demand_usd_hour"]
            elapsed = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(
                created["creationTimestamp"].replace("Z", "+00:00"))).total_seconds()
            write_json(evidence / "cost.json", {"runtime_upper_bound_seconds": elapsed,
                "machine": target["machine"], "region": target["region"],
                "provisioning_model": target["provisioning_model"], "list_usd_hour": rate,
                "compute_usd_upper_bound": max(60, elapsed) / 3600 * rate,
                "basis": "creation to observed deletion; includes provisioning and polling delay",
                "prior_spend_usd": args.spent_usd, "other_usage_reserve_usd": 3,
                "billing_invoice": "not yet available"})
        operations = cloud_json("compute", "operations", "list", "--filter=targetLink:" + name)
        write_json(evidence / "operations.json", operations)
    if created:
        collect(bucket, args.run_id, output, evidence)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"controller received signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    main()
