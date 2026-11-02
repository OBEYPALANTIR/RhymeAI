#!/usr/bin/env python3
"""Package selected v6-B data for the canonical 12B trainer, without local weights."""
import argparse
import base64
from collections import Counter, defaultdict, deque
import hashlib
import io
import json
from pathlib import Path
import tarfile

from train_teacher import APP_USER, APP_MODEL, APP_END, BASE, REVISION, read_splits, sha

EXPECTED = {
    'train.jsonl': '3dc36446447f8e3fcc3c37cbd219b0b8ff79575b174cb62ecb3928cd67830227',
    'val.jsonl': '1cb746c998b70cb610d12151754a0e87eda19d152b840d1ed33112e3d4640718',
    'teacher-test.jsonl': 'fa0c6148602054d59a9bbaa74b8e2108997267f2d56c815dd20e9a60236ffe57',
}
DEPENDENCIES = ['transformers==5.18.0', 'peft==0.21.2', 'accelerate==1.15.0', 'bitsandbytes==0.50.2']


def build(inputs, records_path, out, source_commit, run_name="gemma4-12b-v6B-20261102-01", rate=None, cap=None):
    inputs, records_path, out = Path(inputs), Path(records_path), Path(out)
    if not run_name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in run_name):
        raise ValueError('Use a simple unique run name without path separators')
    for name, expected in EXPECTED.items():
        if sha(inputs / name) != expected:
            raise ValueError('Selected v6-B input changed: ' + name)
    rows = [json.loads(line) for line in records_path.read_text().splitlines()]
    out.mkdir(parents=True, exist_ok=False)
    data = out / 'data'
    data.mkdir()
    manifest = {'source': 'selected v6-B SFT; v8 DPO rejected', 'source_commit': source_commit,
                'base': BASE, 'base_revision': REVISION, 'input_sha256': EXPECTED,
                'records_sha256': sha(records_path), 'splits': {}}
    train_prompts = {r['prompt_sha256'] for r in rows if r['split'] == 'train'}
    for split, original in [('train', 'train.jsonl'), ('validation', 'val.jsonl'), ('test', 'teacher-test.jsonl')]:
        selected = [r for r in rows if r['split'] == split]
        archived = [json.loads(line) for line in (inputs / original).read_text().splitlines()]
        if split != 'test':
            actual = [(r['task'], APP_USER + r['prompt'] + APP_MODEL + r['completion'] + APP_END) for r in selected]
            lookup = defaultdict(deque)
            for key, row in zip(actual, selected):
                lookup[key].append(row)
            keys = [(r['task'], r['text']) for r in archived]
            if Counter(actual) != Counter(keys):
                raise ValueError('Raw provenance does not reproduce exact SFT bytes: ' + split)
            selected = [lookup[key].popleft() for key in keys]
        elif selected != archived:
            raise ValueError('Held-out teacher test changed')
        if split == 'validation':
            leaked = [r for r in selected if r['prompt_sha256'] in train_prompts]
            manifest['validation_leakage_disposition'] = {
                'removed_rows': len(leaked), 'prompt_sha256': sorted({r['prompt_sha256'] for r in leaked}),
                'reason': 'Preserve exact training rows; keep loss validation disjoint from training prompts.'}
            selected = [r for r in selected if r['prompt_sha256'] not in train_prompts]
        for row in selected:
            if not row.get('group'):
                row['group'] = row.get('song_id') or row['prompt_sha256']
        path = data / (split + '.jsonl')
        path.write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in selected))
        manifest['splits'][split] = {'sha256': sha(path), 'rows': len(selected)}
    (data / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    read_splits(data)
    trainer = Path(__file__).with_name('train_teacher.py')
    (out / 'train_teacher.py').write_bytes(trainer.read_bytes())
    manifest['trainer_sha256'] = sha(trainer)
    (out / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for path in sorted(out.rglob('*')):
            if path.is_file():
                archive.add(path, arcname=str(path.relative_to(out)))
    packed = buffer.getvalue()
    package_sha = hashlib.sha256(packed).hexdigest()
    (out / 'training-package.tar.gz').write_bytes(packed)
    stage = f'''import base64, hashlib, io, pathlib, tarfile
ROOT = pathlib.Path('/content/rhymeai-12b-package')
packed = base64.b64decode({base64.b64encode(packed).decode()!r})
assert hashlib.sha256(packed).hexdigest() == {package_sha!r}
if ROOT.exists():
    assert (ROOT / 'provenance.json').read_bytes() == tarfile.open(fileobj=io.BytesIO(packed)).extractfile('provenance.json').read()
else:
    ROOT.mkdir()
    with tarfile.open(fileobj=io.BytesIO(packed)) as archive:
        archive.extractall(ROOT, filter='data')
provenance = __import__('json').loads((ROOT / 'provenance.json').read_text())
assert hashlib.sha256((ROOT / 'train_teacher.py').read_bytes()).hexdigest() == provenance['trainer_sha256']
for name, binding in provenance['splits'].items():
    assert hashlib.sha256((ROOT / 'data' / (name + '.jsonl')).read_bytes()).hexdigest() == binding['sha256']
print('Package staged and verified:', ROOT)
'''
    setup = f'''import json, os, subprocess, sys, time
from google.colab import drive
# Fresh runtime only: do not import Unsloth. Colab provides PyTorch/CUDA.
assert 'unsloth' not in sys.modules
drive.mount('/content/drive', timeout_ms=240000)
RUN_NAME = {run_name!r}
PERSIST = pathlib.Path('/content/drive/MyDrive/RhymeAI Training') / RUN_NAME
PERSIST.mkdir(parents=True, exist_ok=True)
probe = PERSIST / 'persistence-probe.txt'
probe.write_text(RUN_NAME)
assert probe.read_text() == RUN_NAME
# Enter a rate freshly observed in Resources, and an authorized CU cap.
OBSERVED_CU_PER_HOUR = {repr(rate) if rate is not None else "float(input('Fresh observed compute units/hour from Resources: '))"}
AUTHORIZED_CU_CAP = {repr(cap) if cap is not None else "float(input('Authorized compute-unit cap for this run: '))"}
assert OBSERVED_CU_PER_HOUR > 0 and AUTHORIZED_CU_CAP > 0
SECONDS = min(6 * 3600, AUTHORIZED_CU_CAP * 0.9 / OBSERVED_CU_PER_HOUR * 3600)
assert SECONDS > 2400, 'Insufficient budget after checkpoint/evaluation reserve'
DEADLINE = time.time() + SECONDS
budget_path = PERSIST / 'budget.json'
if budget_path.exists():
    DEADLINE = min(DEADLINE, json.loads(budget_path.read_text())['deadline_epoch'])
    assert DEADLINE > time.time() + 2400, 'Original run budget expired; a new authorized budget window is required'
else:
    budget_path.write_text(json.dumps(dict(deadline_epoch=DEADLINE, seconds=SECONDS,
        observed_cu_per_hour=OBSERVED_CU_PER_HOUR, authorized_cap=AUTHORIZED_CU_CAP), indent=2))
# Bound setup, training and idle time on this explicitly selected fresh runtime.
import threading
from google.colab import runtime
def release_at_deadline():
    try:
        drive.flush_and_unmount()
    finally:
        runtime.unassign()
watchdog = threading.Timer(max(1, DEADLINE - time.time()), release_at_deadline)
watchdog.daemon = True
watchdog.start()
try:
    # Persist exact input/source before touching the GPU.
    import shutil
    source = PERSIST / 'source'
    if source.exists():
        assert (source / 'provenance.json').read_bytes() == (ROOT / 'provenance.json').read_bytes()
    assert (source / 'train_teacher.py').read_bytes() == (ROOT / 'train_teacher.py').read_bytes()
    for name in ['manifest.json', 'train.jsonl', 'validation.jsonl', 'test.jsonl']:
        assert (source / 'data' / name).read_bytes() == (ROOT / 'data' / name).read_bytes()
    else:
        source.mkdir()
        for name in ['train_teacher.py', 'provenance.json']:
            shutil.copy2(ROOT / name, source / name)
        shutil.copytree(ROOT / 'data', source / 'data')
    python_dir = ROOT / 'venv'
    subprocess.run([sys.executable, '-m', 'venv', '--system-site-packages', '--without-pip', str(python_dir)], check=True)
    PYTHON = str(python_dir / 'bin/python')
    subprocess.run([PYTHON, '-m', 'pip', 'install', '--disable-pip-version-check', {', '.join(repr(d) for d in DEPENDENCIES)}], check=True)
except BaseException:
    release_at_deadline()
    raise
'''
    helper = '''def run_training(extra):
    import signal
    command = [PYTHON, str(source / 'train_teacher.py'), '--data', str(source / 'data'),
               '--out', str(PERSIST / 'run'), '--deadline', str(DEADLINE - 120),
               '--skip-generation'] + extra
    # Separate process group keeps the watchdog confined to this owned trainer.
    log = PERSIST / ('resume.log' if '--resume' in extra else 'smoke.log')
    with log.open('a') as handle:
        process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=max(1, DEADLINE - time.time()))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise RuntimeError('Owned trainer exceeded deadline; inspect last durable checkpoint')
    print(log.read_text()[-10000:])
    assert code == 0, 'Trainer failed; inspect durable log/status'
'''
    smoke = helper + '''assert not (PERSIST / 'run').exists(), 'Existing run: resume explicitly, preserve its checkpoints'
run_training(['--smoke-steps', '10'])
smoke = json.loads((PERSIST / 'run/smoke.json').read_text())
assert smoke['passed'] and smoke['global_step'] == 10 and smoke['scheduler_horizon_steps'] > 10
print('Inspect supervised-row-0.txt and token-audit.json before full run.')
print(smoke)
'''
    full = helper + '''smoke = json.loads((PERSIST / 'run/smoke.json').read_text())
assert smoke['passed']
# On reconnection, set RESUME_CHECKPOINT to the latest fully written checkpoint
# with trainer_state.json + optimizer.pt + scheduler.pt + rng_state.pth.
RESUME_CHECKPOINT = smoke['checkpoint']
for name in ['trainer_state.json', 'optimizer.pt', 'scheduler.pt', 'rng_state.pth']:
    assert (pathlib.Path(RESUME_CHECKPOINT) / name).is_file(), 'Incomplete checkpoint: ' + name
run_training(['--resume', RESUME_CHECKPOINT])
print((PERSIST / 'run/status.json').read_text())
# Save/flush first, then release only this owned runtime.
try:
    drive.flush_and_unmount()
finally:
    watchdog.cancel()
    runtime.unassign()
'''
    cells = [{'cell_type': 'markdown', 'metadata': {}, 'source': ['# Private RhymeAI Gemma 4 12B training\n',
        'Select a fresh A100 runtime. GPU compatibility and training are NOT RUN.\n',
        'Use selected v6-B SFT data, canonical pinned 12B QLoRA trainer, 10-step smoke then explicit checkpoint resume.\n',
        'Enter observed CU rate and authorized cap in setup. Inspect decoded supervision before full run.\n',
        'This notebook saves an adapter; GGUF export, frozen quality gates, stock-12B regression guard and macOS inference remain required.\n']}]
    for text in [stage, setup, smoke, full]:
        compile(text, '<colab-cell>', 'exec')
        cells.append({'cell_type': 'code', 'metadata': {}, 'execution_count': None, 'outputs': [], 'source': text.splitlines(True)})
    notebook = {'nbformat': 4, 'nbformat_minor': 0, 'metadata': {'accelerator': 'GPU', 'colab': {'gpuType': 'A100'},
                'kernelspec': {'name': 'python3', 'display_name': 'Python 3'}}, 'cells': cells}
    path = out / 'rhymeai-gemma4-12b-v6B.ipynb'
    path.write_text(json.dumps(notebook, indent=1) + '\n')
    return {'notebook': str(path), 'notebook_sha256': sha(path), 'package_sha256': package_sha,
            'splits': manifest['splits'], 'gpu': 'NOT RUN'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--records', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--run-name', required=True)
    parser.add_argument('--units-per-hour', type=float)
    parser.add_argument('--cu-cap', type=float)
    args = parser.parse_args()
    print(json.dumps(build(args.inputs, args.records, args.out, args.source_commit, args.run_name, args.units_per_hour, args.cu_cap), indent=2))
