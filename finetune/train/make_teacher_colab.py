#!/usr/bin/env python3
"""Package the private dataset and pinned trainer into a standalone Colab notebook."""

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import tarfile


def code(source, cell_id):
    return {"cell_type": "code", "metadata": {"id": cell_id, "cellView": "form"}, "execution_count": None,
            "outputs": [], "source": source.splitlines(keepends=True)}


def build(data, output, run_name, observed_rate=None):
    if observed_rate is not None and not 0 < observed_rate <= 60:
        raise ValueError("Observed rate must be between 0 and 60 compute units/hour")
    files = {"train_teacher.py": Path(__file__).with_name("train_teacher.py").read_bytes()}
    for name in ("train", "validation", "test"):
        files["data/" + name + ".jsonl"] = (data / (name + ".jsonl")).read_bytes()
    files["data/manifest.json"] = (data / "manifest.json").read_bytes()
    memory = io.BytesIO()
    with tarfile.open(fileobj=memory, mode="w:gz") as archive:
        for name, value in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(value)
            archive.addfile(info, io.BytesIO(value))
    package = memory.getvalue()
    package_sha = hashlib.sha256(package).hexdigest()
    # No model weights, credentials, or unrelated files enter this notebook.
    stage = f'''# @title Stage verified training package
import base64, hashlib, io, json, os, pathlib, shutil, subprocess, tarfile, time
import threading
from google.colab import runtime
CONNECTED_AT = time.time()
RELEASE_AT = CONNECTED_AT + 20 * 60
def release_at_deadline():
    while time.time() < RELEASE_AT:
        time.sleep(min(10, max(0, RELEASE_AT - time.time())))
    runtime.unassign()
threading.Thread(target=release_at_deadline, daemon=True).start()
RUN_NAME = {run_name!r}
PACKAGE_SHA256 = {package_sha!r}
PAYLOAD = {base64.b64encode(package).decode()!r}
package = base64.b64decode(PAYLOAD)
assert hashlib.sha256(package).hexdigest() == PACKAGE_SHA256
ROOT = pathlib.Path('/content') / RUN_NAME
ROOT.mkdir(exist_ok=False)
with tarfile.open(fileobj=io.BytesIO(package), mode='r:gz') as archive:
    expected = {set(files)!r}
    assert set(archive.getnames()) == expected
    for member in archive.getmembers():
        assert member.isfile() and member.name in expected
        target = ROOT / member.name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.extractfile(member).read())
assert shutil.disk_usage('/content').free >= 48_000_000_000, 'Need 48 GB free runtime disk'
subprocess.run(['nvidia-smi'], check=True)
print('STAGED', RUN_NAME, PACKAGE_SHA256)
print('Review the Resources panel rate before running the next cell. No weights downloaded yet.')
'''
    run = '''# @title Run bounded teacher pilot
# Read Colab's current Resources panel, then enter that rate here.
RATE = float(input('Observed compute units per hour (Resources panel): '))
assert 0 < RATE <= 60, 'Unexpected rate; inspect before proceeding'
CAP_UNITS = 200
RESERVE_UNITS = 20
DEADLINE = CONNECTED_AT + min(6 * 3600, (CAP_UNITS - RESERVE_UNITS) / RATE * 3600)
assert DEADLINE - time.time() > 3600, 'Insufficient time remaining for this attempt'

from google.colab import drive
import sys, traceback
PERSIST = None
log_path = None

def checked(command):
    remaining = DEADLINE - time.time() - 300
    if remaining <= 0:
        raise TimeoutError('Controller deadline reached')
    try:
        with log_path.open('a') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=remaining)
    finally:
        # Give subprocesses a local file descriptor; DriveFS can invalidate
        # inherited descriptors even while new path-based writes still work.
        shutil.copy2(log_path, PERSIST / 'controller.log')

try:
    drive.mount('/content/drive', timeout_ms=240000)
    proposed = pathlib.Path('/content/drive/MyDrive/RhymeAI Training') / RUN_NAME
    proposed.mkdir(parents=True, exist_ok=False)
    PERSIST = proposed
    probe = PERSIST / 'persistence-probe.txt'
    probe.write_text(RUN_NAME)
    assert probe.read_text() == RUN_NAME
    RELEASE_AT = DEADLINE
    budget = {'cap_units': CAP_UNITS, 'reserve_units': RESERVE_UNITS,
              'observed_units_per_hour': RATE, 'connected_epoch': CONNECTED_AT,
              'deadline_epoch': DEADLINE, 'package_sha256': PACKAGE_SHA256,
              'note': 'Time bound from observed rate; not a provider-side spending limit.'}
    (PERSIST / 'budget.json').write_text(json.dumps(budget, indent=2))
    shutil.copytree(ROOT, PERSIST / 'source')
    log_path = ROOT / 'controller.log'
    print('PERSISTENT_OUTPUT', str(PERSIST), flush=True)
    print('BUDGET', json.dumps(budget), flush=True)
    environment = ROOT / 'venv'
    # Colab disables ensurepip; inherit its existing pip without bootstrapping it.
    checked([sys.executable, '-m', 'venv', '--system-site-packages', '--without-pip', str(environment)])
    python = str(environment / 'bin/python')
    checked([python, '-m', 'pip', 'install', '--disable-pip-version-check',
             'transformers==5.18.0', 'peft==0.21.2', 'accelerate==1.15.0',
             'bitsandbytes==0.50.2'])
    with (ROOT / 'pip-freeze.txt').open('w') as freeze:
        subprocess.run([python, '-m', 'pip', 'freeze'], stdout=freeze, check=True)
    shutil.copy2(ROOT / 'pip-freeze.txt', PERSIST / 'pip-freeze.txt')
    checked([python, str(ROOT / 'train_teacher.py'), '--data', str(ROOT / 'data'),
             '--out', str(PERSIST / 'run'), '--deadline', str(DEADLINE - 180)])
    print('RUN_STATUS', (PERSIST / 'run/status.json').read_text(), flush=True)
except BaseException as error:
    if PERSIST is not None:
        (PERSIST / 'controller-error.txt').write_text(traceback.format_exc())
    print('FAILED', type(error).__name__, str(error), flush=True)
    if log_path is not None and log_path.exists():
        print('LOG_TAIL', log_path.read_text()[-7000:], flush=True)
    raise
finally:
    # Flush the mounted Drive before ending this owned runtime. A hard watchdog
    # also releases it at the deadline if a dependency or trainer stalls.
    try:
        if PERSIST is not None:
            (PERSIST / 'controller-finished.json').write_text(json.dumps({'epoch': time.time()}))
        drive.flush_and_unmount()
        print('DRIVE_FLUSHED; releasing runtime', flush=True)
    finally:
        runtime.unassign()
'''
    if observed_rate is not None:
        run = run.replace("float(input('Observed compute units per hour (Resources panel): '))",
                          repr(observed_rate))
    notebook = {"nbformat": 4, "nbformat_minor": 0,
                "metadata": {"colab": {"name": run_name, "gpuType": "A100", "machine_shape": "hm"}, "accelerator": "GPU",
                             "gpuClass": "premium", "kernelspec": {"name": "python3", "display_name": "Python 3"}},
                "cells": [{"cell_type": "markdown", "metadata": {"id": "overview"},
                           "source": ["# RhymeAI 12B teacher candidate\n",
                                      "Private pilot: pinned Gemma 4 12B QLoRA, one epoch, separate contexts, saved checkpoints.\n",
                                      "Select A100 if available. Run staging first and inspect Resources. Then run training.\n",
                                      "Maximum 200 compute units planned from the observed hourly rate; 20-unit reserve and 6-hour ceiling.\n",
                                      "The runtime releases itself after Drive flush. Training does not accept this model as a teacher.\n"]},
                          code(stage, "stage"), code(run, "train")]}
    output.write_text(json.dumps(notebook, indent=1) + "\n")
    return {"notebook": str(output), "package_sha256": package_sha,
            "notebook_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "package_bytes": len(package), "run_name": run_name}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run-name", required=True)
    parser.add_argument("--units-per-hour", type=float, help="Rate just verified in Colab Resources")
    args = parser.parse_args()
    print(json.dumps(build(args.data, args.out, args.run_name, args.units_per_hour), indent=2))
