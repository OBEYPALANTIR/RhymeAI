#!/usr/bin/env python3
"""VM-only cache restore, model selection and idle deletion for the cloud lane."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.request
import uuid

from backend import server_backend
from notebook import bundle, remote_record, sha256

ROOT = Path("/content/lane")
BINARY = Path("/content/llama.cpp/build/bin/llama-server")


def metadata(key):
    request = urllib.request.Request("http://metadata.google.internal/computeMetadata/v1/" + key,
                                     headers={"Metadata-Flavor": "Google"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read().decode()


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def props():
    with urllib.request.urlopen("http://127.0.0.1:8080/props", timeout=10) as response:
        return json.load(response)


def initialize(config):
    if not bundle(Path("/content/llama.cpp"), config["build_cache"], restore=True):
        raise RuntimeError("Pinned CUDA cache is missing; refusing an unpinned build")
    commit = subprocess.check_output(["git", "-C", "/content/llama.cpp", "rev-parse", "HEAD"], text=True).strip()
    if commit != config["llama_cpp_commit"]:
        raise ValueError("Cached llama.cpp commit differs from the pinned build")
    cache = Path("/content/llama.cpp/build/CMakeCache.txt").read_text()
    if "GGML_CUDA:BOOL=ON" not in cache or "CMAKE_CUDA_ARCHITECTURES:UNINITIALIZED=89" not in cache:
        # CMake may normalize the architecture's cache type on a second configure.
        if "GGML_CUDA:BOOL=ON" not in cache or "CMAKE_CUDA_ARCHITECTURES:STRING=89" not in cache:
            raise ValueError("Cached build is not CUDA sm89")
    gpu = subprocess.check_output(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"], text=True).strip()
    if "L4" not in gpu:
        raise ValueError("Cloud inference lane requires the quota-approved L4")
    write_json(ROOT / "ready.json", {"llama_cpp_commit": commit, "binary_sha256": sha256(BINARY),
               "cache_sha256": remote_record(config["build_cache"] + ".json")["sha256"], "gpu": gpu})
    (ROOT / "activity").touch()


def select(config, digest):
    record = config["models"][digest]
    model = Path("/content/models") / (digest + ".gguf")
    model.parent.mkdir(exist_ok=True)
    if not model.exists():
        temporary = model.with_suffix(".download")
        subprocess.run(["gcloud", "storage", "cp", record["uri"], str(temporary), "--quiet"], check=True, stdout=sys.stderr)
        if sha256(temporary) != digest or temporary.stat().st_size != record["bytes"]:
            raise ValueError("VM downloaded model SHA-256 differs from the bound GGUF")
        temporary.rename(model)
        model.chmod(0o444)
    if sha256(model) != digest or model.stat().st_size != record["bytes"]:
        raise ValueError("VM model SHA-256 differs from the bound GGUF")
    launch_path = ROOT / "launch.json"
    previous = json.loads(launch_path.read_text()) if launch_path.exists() else None
    # Reload even an identical model so each arm starts with an empty server cache.
    if previous and Path(f"/proc/{previous['pid']}/exe").exists():
        if Path(f"/proc/{previous['pid']}/exe").resolve() != BINARY:
            raise ValueError("Server PID no longer belongs to this lane")
        os.kill(previous["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 30
        while Path(f"/proc/{previous['pid']}/exe").exists():
            if time.monotonic() > deadline:
                raise TimeoutError("Previous server did not exit; refusing a second server")
            time.sleep(.2)
    alias = digest + "-" + uuid.uuid4().hex
    log = ROOT / f"server-{time.time_ns()}.log"
    command = [str(BINARY), "-m", str(model), "--alias", alias, "--ctx-size", "2048", "--parallel", "1",
               "--host", "127.0.0.1", "--port", "8080", "--n-gpu-layers", "99", "--no-webui", "--log-verbosity", "4"]
    with log.open("w") as handle:
        server = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
    write_json(launch_path, {"pid": server.pid, "command": command, "log": str(log)})
    try:
        deadline = time.monotonic() + 300
        while True:
            if server.poll() is not None:
                raise RuntimeError("llama-server failed; inspect VM server log")
            try:
                live = props()
                if live.get("model_alias") == alias:
                    break
            except OSError:
                pass
            if time.monotonic() > deadline:
                server.terminate()
                raise TimeoutError("Remote llama-server startup deadline")
            time.sleep(1)
        ready = json.loads((ROOT / "ready.json").read_text())
        backend = server_backend(live, log.read_text(), sha256(BINARY))
        if backend["kind"] != "cuda" or backend["binary_sha256"] != ready["binary_sha256"]:
            raise ValueError("Remote server did not use the pinned CUDA backend")
        backend.update({k: ready[k] for k in ("llama_cpp_commit", "cache_sha256", "gpu")})
        current = {"model_sha256": digest, "model_bytes": model.stat().st_size, "model_path": str(model),
                   "model_alias": alias, "pid": server.pid, "backend": backend, "command": command, "log": str(log),
                   "instance_id": metadata("instance/id")}
    except BaseException:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=30)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        raise
    live = props()
    if (live.get("model_alias") != current["model_alias"] or live.get("model_path") != str(model)
            or live.get("build_info") != current["backend"]["build_info"]):
        raise ValueError("Running server no longer matches its VM model proof")
    current["verified_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_json(ROOT / "current.json", current)
    (ROOT / "activity").touch()
    return current


def watch(config):
    while True:
        times = [p.stat().st_mtime for p in ROOT.glob("server-*.log")]
        times.append((ROOT / "activity").stat().st_mtime)
        if time.time() - max(times) > config["idle_seconds"]:
            write_json(ROOT / "idle-exit.json", {"reason": "idle timeout", "unix": time.time()})
            return
        time.sleep(15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("initialize", "select", "watch"))
    parser.add_argument("digest", nargs="?")
    args = parser.parse_args()
    config = json.loads((ROOT / "config.json").read_text())
    if args.action == "watch":
        watch(config)
        return
    with (ROOT / "worker.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "initialize":
            initialize(config)
        else:
            print(json.dumps(select(config, args.digest)), flush=True)


if __name__ == "__main__":
    main()
