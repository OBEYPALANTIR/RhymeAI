"""Run the promoted Kotlin replay against exactly one owned llama-server."""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import time
import urllib.request
from contextlib import contextmanager
from pathlib import Path

from .build import DEV_VERSION, HERE, REPO, read_jsonl, sha256, text_hash, write_json
from .backend import require_backend, require_same_backend, server_backend, tunnel_port, verify_remote
from eval.prompts import GEMMA4, app_prompt

INCUMBENT = Path("/Volumes/Untitled/models/rhymeai/students-v21-20261006/E2B/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf")
INCUMBENTS = {"E2B": INCUMBENT,
              "E4B": INCUMBENT.parent.parent / "E4B/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf"}
# The app catalog's shipped GGUFs (GemmaDownloads.kt): v2.1 E2B and v2.1 E4B.
SHIPPED_INCUMBENT_SHA256 = {
    "4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5",
    "6d6b7890655943a3dba1a4212f6668537503a9e085f55fbdeeb40265c5e91944",
}
SAMPLER = {"temperature": .7, "top_k": 40, "top_p": .95, "min_p": .05, "typical_p": 1.,
           "repeat_last_n": 64, "repeat_penalty": 1., "frequency_penalty": 0., "presence_penalty": 0.,
           "dry_multiplier": 0., "xtc_probability": 0., "xtc_threshold": .1, "mirostat": 0,
           "n_predict": -1, "ignore_eos": False, "stop": ["<turn|>"],
           "samplers": ["penalties", "dry", "top_n_sigma", "top_k", "typ_p", "top_p", "min_p", "xtc", "temperature"]}


def model_size(path):
    from gguf import GGUFReader
    reader = GGUFReader(path)
    keys = ("general.architecture", "gemma4.block_count", "gemma4.embedding_length")
    shape = tuple(reader.get_field(k).contents() if reader.get_field(k) else None for k in keys)
    sizes = {("gemma4", 35, 1536): "E2B", ("gemma4", 42, 2560): "E4B"}
    if shape not in sizes:
        raise ValueError(f"Unsupported GGUF size/shape {shape}: {path}")
    return sizes[shape]


def select_incumbent(candidate, incumbent=None):
    size = model_size(candidate)
    incumbent = incumbent if incumbent is not None else INCUMBENTS[size]
    if model_size(incumbent) != size:
        raise ValueError(f"Incumbent must have the same GGUF size as the {size} candidate")
    return incumbent


def logic_guard():
    if subprocess.run(["pgrep", "-x", "Logic Pro"], capture_output=True).returncode != 1:
        raise RuntimeError("Logic Pro is running or pgrep failed; defer heavy work and ask the coordinator")


def post(port, route, value):
    request = urllib.request.Request(f"http://127.0.0.1:{port}/{route}", data=json.dumps(value).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def gradle(out, phase, model="", port="", seed_offset=0):
    logic_guard()
    evidence = out / "evidence"
    evidence.mkdir(exist_ok=True)
    env = dict(os.environ, RHYMEAI_GATE_INPUT=str(out), RHYMEAI_GATE_REPO=str(REPO),
               RHYMEAI_GATE_PHASE=phase, RHYMEAI_GATE_MODEL=model, RHYMEAI_GATE_PORT=str(port),
               RHYMEAI_GATE_SEED_OFFSET=str(seed_offset))
    if "JAVA_HOME" not in env:
        jbr = Path("/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home")
        if jbr.exists():
            env["JAVA_HOME"] = str(jbr)
    env.setdefault("ANDROID_HOME", str(Path.home() / "Library/Android/sdk"))
    test = {"parity": "promptParity", "replay": "replaySavedCaptures", "generate": "generateAndReplay"}[phase]
    command = ["./gradlew", "--offline", "--no-daemon", "--max-workers=2", ":app:testDebugUnitTest", "--rerun",
               "--tests", f"com.rhymeai.app.service.LocalModelGateTest.{test}"]
    stamp = time.time_ns()
    log = evidence / f"gradle-{phase}-{model}-{stamp}.log"
    with log.open("w") as handle:
        result = subprocess.run(command, cwd=REPO / "android", env=env, stdout=handle, stderr=subprocess.STDOUT)
    shutil.copytree(REPO / "android/app/build/test-results/testDebugUnitTest", evidence / f"junit-{phase}-{model}-{stamp}")
    if result.returncode:
        raise RuntimeError(f"Kotlin gate failed; see {log}")


def freeze_prompts(out):
    gradle(out, "parity")
    exported = {r["id"]: r for r in read_jsonl(out / "parity.jsonl")}
    rows = json.loads((out / "inputs.json").read_text())
    if len(exported) != len(rows):
        raise ValueError("Incomplete Kotlin prompt export")
    for row in rows:
        row.update({k: v for k, v in exported[row["id"]].items() if k != "frozen_byte_parity"})
        row["wrapped_prompt"] = app_prompt(row["prompt"], GEMMA4)
        row["wrapped_prompt_sha256"] = text_hash(row["wrapped_prompt"])
    target = out / "prompts.json"
    if target.exists() and json.loads(target.read_text()) != rows:
        raise ValueError("Kotlin prompt bytes changed; frozen benchmark cannot be silently updated")
    write_json(target, rows)
    manifest = json.loads((out / "benchmark.json").read_text())
    frozen = json.loads((HERE / "frozen.json").read_text())
    if manifest["version"] != DEV_VERSION and sha256(target) != frozen["prompts_sha256"]:
        raise ValueError("Prompt builders no longer match the frozen v1 benchmark; do not silently refresh it")
    gradle(out, "parity")
    if not all(r["frozen_byte_parity"] for r in read_jsonl(out / "parity.jsonl")):
        raise ValueError("Kotlin byte parity was not proved")
    if manifest["version"] == DEV_VERSION:
        manifest["prompts_sha256"] = sha256(target)
        write_json(out / "benchmark.json", manifest)


def source_binding():
    paths = [REPO / "android/app/src/main/kotlin/com/rhymeai/app/service/AIService.kt",
             REPO / "android/app/src/main/kotlin/com/rhymeai/app/service/LocalModelService.kt",
             REPO / "android/app/src/test/kotlin/com/rhymeai/app/service/LocalModelGateTest.kt",
             REPO / "shared/pronunciation/cmudict-rhymeai.tsv", REPO / "shared/pronunciation/word-frequency.txt"]
    paths.extend(sorted((REPO / "android/app/src/main/kotlin/com/rhymeai/app/util").glob("*.kt")))
    return {str(p.relative_to(REPO)): sha256(p) for p in paths}


def generate(out, model, path, seed_offset=0, *, server_url=None, remote_proof=None):
    if server_url and not remote_proof:
        raise ValueError("A verified remote model SHA-256 is required before starting a run")
    path = Path(path).resolve(strict=True)
    binding = {"model_path": str(path), "model_sha256": sha256(path), "model_bytes": path.stat().st_size,
               "prompts_sha256": sha256(out / "prompts.json"), "sampler": SAMPLER, "source": source_binding(),
               "sampler_seed_offset": seed_offset}
    if model == "incumbent" and binding["model_sha256"] not in SHIPPED_INCUMBENT_SHA256:
        raise ValueError("Incumbent must be a shipped catalog GGUF (v2.1 E2B or E4B)")
    target = out / f"binding-{model}.json"
    existing = json.loads(target.read_text()) if target.exists() else None
    if existing and {k: v for k, v in existing.items() if k not in ("backend", "remote_model_sha256")} != binding:
        raise ValueError("Refusing to mix runs with different source, sampler, prompts or model")
    if existing is None:
        if any((out / f"{kind}-{model}.jsonl").exists() for kind in ("raw", "replay")):
            raise ValueError("Existing captures have no original binding; refusing to reuse them")
    expected = len(json.loads((out / "prompts.json").read_text())) * 3
    replay = out / f"replay-{model}.jsonl"
    complete = replay.exists() and len(read_jsonl(replay)) == expected
    other = out / f"binding-{'incumbent' if model == 'candidate' else 'candidate'}.json"

    def bind():
        require_backend(binding.get("backend"))
        if existing is not None and existing != binding:
            raise ValueError("Refusing to mix backend/build or remote model bindings; regenerate captures")
        if other.exists():
            require_same_backend({model: binding, "other": json.loads(other.read_text())})
        write_json(target, binding)
        write_json(out / "sampler.json", SAMPLER)

    if not server_url and complete:
        binding["backend"] = require_backend((existing or {}).get("backend"))
        bind()
        return binding
    evidence = out / "evidence"
    evidence.mkdir(exist_ok=True)
    if server_url:
        port = tunnel_port(server_url)
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/props", timeout=10) as response:
            props = json.load(response)
        binding["backend"] = verify_remote(remote_proof, props, binding["model_sha256"], binding["model_bytes"])
        binding["remote_model_sha256"] = remote_proof["model_sha256"]
        bind()
        write_json(evidence / f"remote-{model}-{time.time_ns()}.json", remote_proof)
        write_json(evidence / f"props-{model}.json", props)
        if not complete:
            generate_from_server(out, model, port, seed_offset)
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/props", timeout=10) as response:
            verify_remote(remote_proof, json.load(response), binding["model_sha256"], binding["model_bytes"])
    else:
        with local_server(out, model, path) as (port, props, backend):
            binding["backend"] = backend
            bind()
            generate_from_server(out, model, port, seed_offset)
    rows = read_jsonl(replay)
    if len(rows) != expected or len({(r["id"], r["seed"]) for r in rows}) != expected:
        raise ValueError("Incomplete or duplicate generation rows")
    return binding


def generate_from_server(out, model, port, seed_offset):
    audits = []
    for row in json.loads((out / "prompts.json").read_text()):
        applied = post(port, "apply-template", {"messages": [{"role": "user", "content": row["prompt"]}],
                       "add_generation_prompt": True, "chat_template_kwargs": {"enable_thinking": False}})["prompt"]
        if applied != row["wrapped_prompt"]:
            raise ValueError(f"GGUF template mismatch: {row['id']}")
        tokens = post(port, "tokenize", {"content": applied, "add_special": True, "parse_special": True})["tokens"]
        if tokens[0] != 2 or tokens.count(2) != 1 or len(tokens) >= 2048:
            raise ValueError(f"BOS/context mismatch: {row['id']}")
        audits.append({"id": row["id"], "template_byte_parity": True, "tokens": len(tokens), "sha256": text_hash(applied)})
    write_json(out / "evidence" / f"envelope-{model}.json", audits)
    gradle(out, "generate", model, port, seed_offset)


@contextmanager
def local_server(out, model, path):
    logic_guard()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    binary = shutil.which("llama-server")
    if not binary:
        raise FileNotFoundError("Install llama.cpp; model downloads are not performed by this runner")
    command = [binary, "-m", str(path), "--ctx-size", "2048", "--parallel", "1", "--host", "127.0.0.1",
               "--port", str(port), "--n-gpu-layers", "99", "--no-webui", "--log-verbosity", "4"]
    evidence = out / "evidence"
    evidence.mkdir(exist_ok=True)
    stamp = time.time_ns()
    write_json(evidence / f"server-{model}-{stamp}-command.json", command)
    with (evidence / f"server-{model}-{stamp}.log").open("w") as log:
        server = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 300
            while True:
                if server.poll() is not None:
                    raise RuntimeError("llama-server exited; inspect its saved log")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3) as response:
                        if response.status == 200:
                            break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    raise TimeoutError("llama-server startup deadline")
                time.sleep(1)
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/props", timeout=10) as response:
                props = json.load(response)
                write_json(evidence / f"props-{model}.json", props)
            backend = server_backend(props, Path(log.name).read_text(), sha256(binary))
            yield port, props, backend
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
            write_json(evidence / f"server-{model}-{stamp}-exit.json", {"pid": server.pid, "returncode": server.returncode})
