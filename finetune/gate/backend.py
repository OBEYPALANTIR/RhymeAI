"""Bind numerical execution identity; unknown or mixed backends cannot be paired."""
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

HOST_PROBE = Path(__file__).with_name("evidence") / "host-llama-probe-20261015.json"
BACKEND_REQUIRED = "A verified backend and llama.cpp build binding is required; regenerate legacy captures"


def version_build(output):
    match = re.search(r"build (\d+), commit ([0-9a-f]+)", output)
    if not match:
        raise ValueError("Unrecognized llama-server version")
    return f"b{match[1]}-{match[2]}"


def read_binding(out, role):
    """Infer legacy Metal identity without changing the saved binding or inventing a GPU observation."""
    out = Path(out)
    binding = json.loads((out / f"binding-{role}.json").read_text())
    if "backend" not in binding:
        try:
            props_path = out / "evidence" / f"props-{role}.json"
            provenance_path = out / "provenance.json"
            probe = json.loads(HOST_PROBE.read_text())
            props = json.loads(props_path.read_text())
            commit = json.loads(provenance_path.read_text())["source_head"]
            launch = probe["gate_commits"][commit]
            commands = sorted((out / "evidence").glob(f"server-{role}-*-command.json"))
            if (props["build_info"] != probe["build_info"] or props["build_info"] != version_build(probe["version_output"])
                    or not re.search(r"^\s*MTL\d+: .+", probe["list_devices_output"], re.M)
                    or launch["n_gpu_layers"] != 99 or not commands):
                raise ValueError("Legacy host evidence does not match this run")
            for path in commands:
                command = json.loads(path.read_text())
                if (command[0] != probe["binary_path"] or command.count("--n-gpu-layers") != 1 or "-ngl" in command
                        or command[command.index("--n-gpu-layers") + 1] != "99"):
                    raise ValueError("Legacy launch does not match the probed binary and GPU flags")
            inferred = [{"path": f"finetune/gate/evidence/{HOST_PROBE.name}", "scope": "repository",
                         "sha256": hashlib.sha256(HOST_PROBE.read_bytes()).hexdigest()},
                        *[{"path": str(path.relative_to(out)), "scope": "run",
                           "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                          for path in (props_path, provenance_path, *commands)],
                        {"path": "finetune/gate/generate.py", "commit": commit, "n_gpu_layers": 99,
                         "sha256": launch["source_sha256"]}]
            binding["backend"] = {"kind": "metal", "build_info": props["build_info"],
                                  "binary_sha256": probe["binary_sha256"], "legacy": True, "inferred_from": inferred}
        except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
            raise ValueError(BACKEND_REQUIRED) from error
    require_backend(binding.get("backend"))
    return binding


def tunnel_port(url):
    parsed = urlsplit(url)
    if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username or parsed.password):
        raise ValueError("server-url must be an HTTP SSH tunnel at 127.0.0.1:<port>")
    return parsed.port


def server_backend(props, log, binary_sha256):
    offload = re.search(r"offloaded (\d+)/(\d+) layers to GPU", log)
    if not props.get("build_info"):
        raise ValueError("llama.cpp build is missing from /props")
    if offload and int(offload[1]) > 0:
        if "CUDA0" in log:
            kind = "cuda"
        elif "Metal" in log:
            kind = "metal"
        else:
            raise ValueError("Unrecognized GPU backend")
    elif "CPU" in log and (not offload or int(offload[1]) == 0):
        kind = "cpu"
    else:
        raise ValueError("No observed inference backend")
    return {"kind": kind, "build_info": props["build_info"], "binary_sha256": binary_sha256}


def require_backend(backend):
    if (not isinstance(backend, dict) or backend.get("kind") not in ("cpu", "metal", "cuda")
            or not backend.get("build_info") or not isinstance(backend.get("binary_sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", backend["binary_sha256"])):
        raise ValueError(BACKEND_REQUIRED)
    if backend.get("legacy"):
        evidence = backend.get("inferred_from")
        if (backend["legacy"] is not True or backend["kind"] != "metal" or not isinstance(evidence, list)
                or len(evidence) < 3 or any(not isinstance(item, dict) or not item.get("path")
                    or not isinstance(item.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
                    for item in evidence)):
            raise ValueError(BACKEND_REQUIRED)
    return backend


def require_same_backend(bindings):
    backends = [require_backend(binding.get("backend")) for binding in bindings.values()]
    if any(any(backend[key] != backends[0][key] for key in ("kind", "build_info", "binary_sha256"))
           for backend in backends[1:]):
        raise ValueError("Candidate and incumbent backends/builds differ; regenerate both arms on the same backend")


def verify_remote(proof, props, model_sha256, model_bytes):
    if (not proof or proof.get("model_sha256") != model_sha256 or proof.get("model_bytes") != model_bytes
            or proof.get("gcs_readback_sha256") != model_sha256 or not proof.get("gcs_generation")):
        raise ValueError("A verified remote model SHA-256 matching the bound GGUF is required")
    backend = require_backend(proof.get("backend"))
    if backend.get("legacy"):
        raise ValueError("Remote runs require a fresh observed backend")
    if (not proof.get("verified_at") or not proof.get("pid") or not proof.get("instance_id")
            or not proof.get("model_path") or not proof.get("model_alias")
            or props.get("model_path") != proof["model_path"]
            or props.get("model_alias") != proof["model_alias"]
            or props.get("build_info") != backend["build_info"]):
        raise ValueError("Remote hash proof does not identify the live /props model and build")
    if props.get("total_slots") != 1 or props.get("default_generation_settings", {}).get("n_ctx") != 2048:
        raise ValueError("Remote server must have one slot and a 2048-token context")
    return backend
