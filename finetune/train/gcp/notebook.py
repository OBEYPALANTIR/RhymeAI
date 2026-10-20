#!/usr/bin/env python3
"""Execute frozen notebook cells; adapt only storage, setup and runtime lifecycle."""
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import time

NOTEBOOK_SHA = "2f3a900ad5531716991955fc73aa52107d9016d78f088b98fc7c96e95887dcab"
ROOT = Path("/content")
PACKAGE = ROOT / "package"
DELIVERY = ROOT / "delivery"
PHASES = []


def sha256(path):
    with Path(path).open("rb") as handle:
        digest = hashlib.sha256()
        for block in iter(lambda: handle.read(8 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def command(*args):
    subprocess.run(list(map(str, args)), check=True)


def upload(path, uri):
    command("gcloud", "storage", "cp", path, uri, "--quiet")
    # Verify actual object bytes, rather than treating metadata as SHA-256 proof.
    process = subprocess.Popen(["gcloud", "storage", "cat", uri], stdout=subprocess.PIPE)
    digest = hashlib.sha256()
    for block in iter(lambda: process.stdout.read(8 << 20), b""):
        digest.update(block)
    if process.wait() or digest.hexdigest() != sha256(path):
        raise RuntimeError(f"GCS readback SHA-256 failed: {uri}")


def remote_record(uri):
    result = subprocess.run(["gcloud", "storage", "cat", uri], text=True, capture_output=True)
    if result.returncode:
        if "matched no objects" in result.stderr or "not found" in result.stderr.lower():
            return None
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def bundle(path, uri, restore=False):
    """Cache immutable directories with one verified tar, preserving shared-library links."""
    archive = ROOT / (path.name + ".tar")
    record = remote_record(uri + ".json")
    if restore:
        if record is None:
            return False
        command("gcloud", "storage", "cp", uri + ".tar", archive, "--quiet")
        if sha256(archive) != record["sha256"]:
            raise RuntimeError("cache/checkpoint checksum mismatch: " + uri)
        path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as handle:
            handle.extractall(path.parent, filter="data")
        archive.unlink()
        print("CACHE_RESTORED", uri, flush=True)
        return True
    if record is not None:
        return
    with tarfile.open(archive, "w") as handle:
        handle.add(path, arcname=path.name)
    upload(archive, uri + ".tar")
    marker = archive.with_suffix(".json")
    marker.write_text(json.dumps({"sha256": sha256(archive), "bytes": archive.stat().st_size}))
    upload(marker, uri + ".json")
    archive.unlink()


def cell_source(notebook, index):
    return "".join(notebook["cells"][index]["source"])


def run_cell(shell, source, phase):
    start = time.monotonic()
    print("PHASE_START", phase, flush=True)
    result = shell.run_cell(source)
    error = result.error_before_exec or result.error_in_exec
    PHASES.append({"phase": phase, "seconds": round(time.monotonic() - start, 3), "ok": error is None})
    (ROOT / "phases.json").write_text(json.dumps(PHASES, indent=2))
    print("PHASE_END", json.dumps(PHASES[-1]), flush=True)
    if error:
        raise RuntimeError("notebook phase failed: " + phase) from error


def main():
    from IPython.core.interactiveshell import InteractiveShell

    prefix = os.environ["RUN_PREFIX"]
    cache = prefix.split("/runs/")[0] + "/cache"
    notebook_path = PACKAGE / "recipe.ipynb"
    if sha256(notebook_path) != NOTEBOOK_SHA:
        raise RuntimeError("notebook changed; refusing to execute a different recipe")
    notebook = json.loads(notebook_path.read_text())
    shell = InteractiveShell.instance()
    ns = shell.user_ns
    run_cell(shell, cell_source(notebook, 1), "config")
    # Retain the notebook's paths and local-copy branches, with no Colab imports.
    ns.update(DRIVE_DIR=str(PACKAGE), OUT_DRIVE=str(DELIVERY),
              ensure_drive=lambda: None, RELEASE_RUNTIME_AT_END=False)
    DELIVERY.mkdir(exist_ok=True)
    run_cell(shell, cell_source(notebook, 3).replace(
        "%pip install -U -q unsloth", "%pip install -q -r /content/package/requirements.txt"), "dependencies")
    for line in (PACKAGE / "requirements.txt").read_text().splitlines():
        if "==" in line:
            name, version = line.split("==")
            assert importlib.metadata.version(name).split("+")[0] == version, name
    command(sys.executable, "-m", "pip", "freeze", "--all")
    # Round 2 used 8x2; the notebook's small-card fallback would silently change it on L4.
    gpu_check = cell_source(notebook, 5).replace(
        "(8, 2) if VRAM_GB >= 35 else (2, 8)", "(8, 2)")
    run_cell(shell, gpu_check, "gpu")
    assert ns["BATCH_SIZE"] == 8 and ns["GRAD_ACCUM"] == 2
    gpu = ns["torch"].cuda.get_device_name(0)
    assert "A100" in gpu or "L4" in gpu
    architecture = "sm" + "".join(map(str, ns["torch"].cuda.get_device_capability(0)))
    assert architecture in ("sm80", "sm89")
    run_cell(shell, cell_source(notebook, 9), "inputs")
    base = Path(ns["BASE_LOCAL"])
    base_cache = cache + "/base-" + ns["BASE_REVISION"]
    bundle(base, base_cache, restore=True)
    run_cell(shell, cell_source(notebook, 11), "envelope")
    # The entire training function and recipe remain the supplied notebook's code.
    run_cell(shell, cell_source(notebook, 13), "define-training")
    original_save = ns["SaveEpochToDrive"].on_save

    def save_epoch(self, args, state, control, **kwargs):
        original_save(self, args, state, control, **kwargs)
        epoch = round(state.epoch)
        bundle(DELIVERY / "checkpoints" / f"epoch-{epoch}", prefix + f"/checkpoints/epoch-{epoch}")

    ns["SaveEpochToDrive"].on_save = save_epoch
    download, call, train = cell_source(notebook, 15).partition("metrics = train_one(")
    assert call
    run_cell(shell, download, "base-download")
    bundle(base, base_cache)
    run_cell(shell, call + train, "train")
    for epoch, step in ((1, 329), (2, 658)):
        state = DELIVERY / "checkpoints" / f"epoch-{epoch}" / "trainer_state.json"
        data = json.loads(state.read_text())
        assert data["global_step"] == step
        (Path(ns["REPORTS"]) / f"trainer-state-epoch-{epoch}.json").write_text(json.dumps(data, indent=2))
    llama = Path(ns["LLAMA_DIR"])
    build_cache = cache + "/llama-" + ns["LLAMA_CPP_COMMIT"] + "-" + os.environ["IMAGE_NAME"] + "-" + architecture
    bundle(llama, build_cache, restore=True)
    if llama.exists():
        actual = subprocess.check_output(["git", "-C", str(llama), "rev-parse", "HEAD"], text=True).strip()
        assert actual == ns["LLAMA_CPP_COMMIT"]
    run_cell(shell, cell_source(notebook, 17), "cuda-build")
    bundle(llama, build_cache)
    models = ROOT / "rhymeai/models"
    gguf_cache = cache + "/bf16-" + ns["BASE_GGUF_SHA256"]
    bundle(models, gguf_cache, restore=True)
    run_cell(shell, cell_source(notebook, 19), "export-and-check")
    bundle(models, gguf_cache)
    # Keep the original save/copy/hash checks, replacing only Colab's flush call.
    save = cell_source(notebook, 21)
    old = "    from google.colab import drive\n    drive.flush_and_unmount()"
    assert save.count(old) == 1
    run_cell(shell, save.replace(old, "    os.sync()"), "local-save")
    record = json.loads((DELIVERY / "SAVED_OK").read_text())
    for name in record["products_sha256"]:
        upload(DELIVERY / name, prefix + "/products/" + name)
    record.update(run_id=prefix.rsplit("/", 1)[1], notebook_sha256=NOTEBOOK_SHA,
                  destination=prefix, phases=PHASES)
    (ROOT / "SAVED_OK").write_text(json.dumps(record, indent=2))
    # The completion marker is published last, after remote SHA-256 readback.
    upload(ROOT / "SAVED_OK", prefix + "/SAVED_OK")


if __name__ == "__main__":
    main()
