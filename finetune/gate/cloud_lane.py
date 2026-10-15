#!/usr/bin/env python3
"""One bounded L4 inference lane; model bytes stay on the external drive/GCS/VM."""
import argparse
import datetime as dt
import fcntl
import json
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time
from contextlib import contextmanager

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gate.backend import tunnel_port
from gate.build import sha256, write_json
from train.gcp.run import (IMAGE, L4_PRICES, PROJECT, capacity_candidates, cloud_json, event, gcloud, inventory)

HERE = Path(__file__).resolve().parent
LLAMA_COMMIT = "049326a00025d00b08cc188ed716b681e984a3f8"


@contextmanager
def lane_lock(state_path):
    with state_path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def read_state(path):
    state = json.loads(Path(path).read_text())
    if not re.fullmatch(r"rhymeai-gate-[a-z0-9-]{1,40}", state["name"]):
        raise ValueError("Invalid lane instance name")
    return state


def live_instance(state):
    current = cloud_json("compute", "instances", "describe", state["name"], "--zone=" + state["zone"])
    if current["id"] != state["instance"]["id"] or current.get("labels", {}).get("run") != state["run_id"]:
        raise ValueError("Lane state no longer owns this instance")
    return current


def ssh(state, command, check=True):
    return gcloud("compute", "ssh", state["name"], "--zone=" + state["zone"], "--command=" + command,
                  "--ssh-flag=-oBatchMode=yes", "--ssh-flag=-oConnectTimeout=10", check=check)


def select_model(state_path, model):
    state = read_state(state_path)
    live_instance(state)
    digest = sha256(model)
    if digest not in state["models"]:
        raise ValueError("GGUF not uploaded by this lane; start a lane with both requested models")
    result = ssh(state, "sudo python3 /content/lane/cloud_worker.py select " + shlex.quote(digest))
    proof = json.loads(result.stdout)
    if proof.get("instance_id") != state["instance"]["id"]:
        raise ValueError("Remote model proof came from a different VM")
    write_json(Path(state["evidence"]) / f"remote-model-{time.time_ns()}.json", proof)
    return proof


def upload_model(path, bucket, evidence):
    path = path.expanduser().resolve(strict=True)
    mount = Path("/Volumes/Untitled")
    if not mount.is_mount() or not path.is_relative_to(mount) or path.stat().st_dev == Path("/").stat().st_dev:
        raise ValueError("Model uploads must read the mounted external drive")
    digest = sha256(path)
    uri = f"{bucket}/gate-models/{digest}.gguf"
    found = gcloud("storage", "objects", "describe", uri, "--format=json", check=False)
    if found.returncode:
        if not any(s in found.stderr.lower() for s in ("not found", "matched no objects", "404")):
            raise RuntimeError(found.stderr)
        gcloud("storage", "cp", path, uri)
    obj = cloud_json("storage", "objects", "describe", uri)
    if int(obj["size"]) != path.stat().st_size:
        raise ValueError("GCS model size mismatch; object was not overwritten")
    # The VM hashes the actual readback before serving; pin the object against replacement.
    record = {"uri": uri + "#" + str(obj["generation"]), "bytes": path.stat().st_size,
              "local_path": str(path), "sha256": digest, "gcs_generation": str(obj["generation"]),
              "sha256_readback": "required on VM before serving", "reused": found.returncode == 0}
    write_json(evidence / f"upload-{digest}.json", record)
    return record


def budget(hours, spent, model_bytes):
    reserve = 1 + model_bytes / 1e9 * .2
    bound = spent + hours * max(price[1] for price in L4_PRICES.values()) + reserve
    if not 0 < hours <= 6 or not 0 <= spent < 10 or not bound <= 10:
        raise ValueError("Duration, prior spend and transfer/storage reserve exceed the $10 task cap")
    return {"max_seconds": int(hours * 3600), "prior_spend_usd": spent, "task_cap_usd": 10,
            "other_usage_reserve_usd": reserve, "conservative_bound_usd": bound, "rate_date": "2026-10-14"}


def start(args):
    evidence = args.state.resolve().parent
    evidence.mkdir(parents=True, exist_ok=True)
    if args.state.exists() or not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", args.run_id or ""):
        raise ValueError("Use a new state file and a new lowercase run-id (1-40 characters)")
    models = list(dict.fromkeys(p.resolve(strict=True) for p in args.model))
    limits = budget(args.max_hours, args.spent_usd, sum(p.stat().st_size for p in models))
    if not 5 <= args.idle_minutes <= 60:
        raise ValueError("idle-minutes must be in [5, 60]")
    initial = inventory(evidence, "before")
    if initial["instances"] or initial["disks"]:
        raise RuntimeError("Project has existing instances/disks; refuse overlap")
    number = cloud_json("projects", "describe", PROJECT)["projectNumber"]
    bucket = f"gs://{PROJECT}-{number}-finetune"
    policy = cloud_json("storage", "buckets", "describe", bucket)
    if policy.get("public_access_prevention") != "enforced" or not policy.get("uniform_bucket_level_access"):
        raise ValueError("Existing training bucket must enforce private uniform access")
    prefix = bucket + "/gate-runs/" + args.run_id
    prior = gcloud("storage", "ls", prefix + "/", check=False)
    if prior.returncode == 0:
        raise ValueError("run-id already exists in GCS")
    if not any(s in prior.stderr.lower() for s in ("matched no objects", "not found")):
        raise RuntimeError(prior.stderr)
    cache = bucket + "/cache/llama-" + LLAMA_COMMIT + "-" + IMAGE + "-sm89"
    cloud_json("storage", "objects", "describe", cache + ".json")
    uploaded = [upload_model(p, bucket, evidence) for p in models]
    state = {"name": "rhymeai-gate-" + args.run_id, "run_id": args.run_id, "evidence": str(evidence),
             "prefix": prefix, "models": {r["sha256"]: r for r in uploaded}, "budget": limits,
             "build_cache": cache, "llama_cpp_commit": LLAMA_COMMIT, "idle_seconds": args.idle_minutes * 60,
             "created_at": dt.datetime.now(dt.timezone.utc).isoformat(), "attempted_zones": []}
    state["source_sha256"] = {p.name: sha256(p) for p in
                              (HERE / "cloud_lane.py", HERE / "cloud_worker.py", HERE / "backend.py", HERE / "cloud_startup.sh")}
    write_json(args.state, state)
    write_json(evidence / "config.json", state)
    write_json(evidence / "budget.json", limits)
    for file in (evidence / "config.json", HERE / "cloud_worker.py", HERE / "backend.py", HERE.parent / "train/gcp/notebook.py"):
        gcloud("storage", "cp", file, prefix + "/" + file.name)
    targets = [{"machine": "g2-standard-12", "accelerator": "nvidia-l4", "region": region,
                "provisioning_model": mode} for mode in ("SPOT", "STANDARD") for region in L4_PRICES]
    candidates = capacity_candidates(cloud_json("compute", "accelerator-types", "list"), targets)
    try:
        for target, zone in candidates:
            state["attempted_zones"].append(zone)
            write_json(args.state, state)
            event(evidence, "create-request", zone=zone, **target)
            result = gcloud("compute", "instances", "create", state["name"], "--zone=" + zone,
                "--machine-type=g2-standard-12", "--provisioning-model=" + target["provisioning_model"],
                "--instance-termination-action=DELETE", f"--max-run-duration={limits['max_seconds']}s",
                "--maintenance-policy=TERMINATE", "--no-restart-on-failure",
                "--image=" + IMAGE, "--image-project=deeplearning-platform-release",
                "--boot-disk-size=100GB", "--boot-disk-type=pd-balanced", "--boot-disk-auto-delete",
                f"--service-account={number}-compute@developer.gserviceaccount.com", "--scopes=cloud-platform",
                "--labels=purpose=rhymeai-gate,run=" + args.run_id,
                f"--metadata=run-prefix={prefix},install-nvidia-driver=True",
                f"--metadata-from-file=startup-script={HERE / 'cloud_startup.sh'}", "--format=json", check=False)
            (evidence / f"create-{target['provisioning_model']}-{zone}.log").write_text(result.stdout + result.stderr)
            if result.returncode == 0:
                state.update(instance=json.loads(result.stdout)[0], zone=zone, target=target)
                write_json(args.state, state)
                event(evidence, "created", id=state["instance"]["id"], zone=zone, **target)
                break
            remaining = inventory(evidence, "after-create-failure")
            if remaining["instances"] or remaining["disks"]:
                raise RuntimeError("Creation failed with resources left; stopping and cleaning this run")
            if not any(s in result.stderr for s in ("ZONE_RESOURCE_POOL_EXHAUSTED", "does not have enough resources", "QUOTA_EXCEEDED")):
                raise RuntimeError(result.stderr)
        else:
            raise RuntimeError("No L4 capacity in the quota regions")
        deadline = time.monotonic() + min(1200, limits["max_seconds"])
        while time.monotonic() < deadline:
            ready = ssh(state, "cat /content/lane/ready.json", check=False)
            (evidence / "startup-probe.log").write_text(ready.stdout + ready.stderr)
            if ready.returncode == 0:
                write_json(evidence / "ready.json", json.loads(ready.stdout))
                event(evidence, "ready", name=state["name"])
                print(f"Ready: {args.state}. Open cloud_lane.py tunnel, then run with --server-url and --cloud-lane.")
                return
            if not cloud_json("compute", "instances", "list", "--filter=name=" + state["name"]):
                raise RuntimeError("VM deleted before readiness; inspect startup evidence")
            time.sleep(10)
        raise TimeoutError("VM startup deadline")
    except BaseException:
        stop(args.state)
        raise


def stop(state_path):
    state = read_state(state_path)
    evidence = Path(state["evidence"])
    own = cloud_json("compute", "instances", "list", "--filter=name=" + state["name"])
    for vm in own:
        if (vm.get("labels", {}).get("run") != state["run_id"]
                or ("instance" in state and vm["id"] != state["instance"]["id"])):
            raise ValueError("Refusing to delete a VM without this run's ownership label")
        zone = vm["zone"].split("/")[-1]
        serial = gcloud("compute", "instances", "get-serial-port-output", state["name"], "--zone=" + zone, check=False)
        (evidence / "serial.log").write_text(serial.stdout + serial.stderr)
        gcloud("compute", "instances", "delete", state["name"], "--zone=" + zone, "--delete-disks=all")
        event(evidence, "controller-deleted", name=state["name"], zone=zone)
    for disk in cloud_json("compute", "disks", "list", "--filter=name=" + state["name"]):
        zone = disk["zone"].split("/")[-1]
        disk_created = dt.datetime.fromisoformat(disk["creationTimestamp"].replace("Z", "+00:00"))
        if disk.get("users") or zone not in state["attempted_zones"] or disk_created < dt.datetime.fromisoformat(state["created_at"]):
            raise ValueError("Refusing deletion of an attached or unowned disk")
        gcloud("compute", "disks", "delete", disk["name"], "--zone=" + zone)
    final = inventory(evidence, "after")
    if final["instances"] or final["disks"]:
        raise RuntimeError("Inventories are not empty; preserve other work and investigate after.json")
    if "instance" in state and "stopped_at" not in state:
        now = dt.datetime.now(dt.timezone.utc)
        elapsed = (now - dt.datetime.fromisoformat(state["instance"]["creationTimestamp"].replace("Z", "+00:00"))).total_seconds()
        target = state["target"]
        rate = L4_PRICES[target["region"]][target["provisioning_model"] == "STANDARD"]
        write_json(evidence / "cost.json", {"compute_usd_upper_bound": max(60, elapsed) / 3600 * rate,
                   "runtime_upper_bound_seconds": elapsed, "list_usd_hour": rate, **target, **state["budget"],
                   "basis": "creation to observed deletion; billing invoice not yet available"})
        state["stopped_at"] = now.isoformat()
        write_json(state_path, state)
    event(evidence, "empty-inventories", instances=0, disks=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "tunnel", "select", "stop"))
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--model", type=Path, action="append", default=[])
    parser.add_argument("--run-id")
    parser.add_argument("--max-hours", type=float, default=6)
    parser.add_argument("--spent-usd", type=float, default=0)
    parser.add_argument("--idle-minutes", type=int, default=20)
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    if args.action == "start":
        if not args.model:
            parser.error("start requires at least one --model")
        start(args)
    elif args.action == "stop":
        stop(args.state)
    elif args.action == "select":
        if len(args.model) != 1:
            parser.error("select requires exactly one --model")
        with lane_lock(args.state):
            print(json.dumps(select_model(args.state, args.model[0]), indent=2))
    else:
        tunnel_port(f"http://127.0.0.1:{args.port}")
        state = read_state(args.state)
        live_instance(state)
        command = ["gcloud", "compute", "ssh", state["name"], "--project=" + PROJECT, "--zone=" + state["zone"],
                   "--quiet", "--", "-N", "-L", f"127.0.0.1:{args.port}:127.0.0.1:8080",
                   "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        write_json(Path(state["evidence"]) / "tunnel-command.json", command)
        subprocess.run(command, check=True)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"controller received signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    main()
