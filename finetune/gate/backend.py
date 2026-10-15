"""Bind numerical execution identity; unknown or mixed backends cannot be paired."""
import re
from urllib.parse import urlsplit


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
            or not backend.get("build_info") or not re.fullmatch(r"[0-9a-f]{64}", backend.get("binary_sha256", ""))):
        raise ValueError("A verified backend and llama.cpp build binding is required; regenerate legacy captures")
    return backend


def require_same_backend(bindings):
    backends = [require_backend(binding.get("backend")) for binding in bindings.values()]
    if any(backend != backends[0] for backend in backends[1:]):
        raise ValueError("Candidate and incumbent backends/builds differ; regenerate both arms on the same backend")


def verify_remote(proof, props, model_sha256, model_bytes):
    if not proof or proof.get("model_sha256") != model_sha256 or proof.get("model_bytes") != model_bytes:
        raise ValueError("A verified remote model SHA-256 matching the bound GGUF is required")
    backend = require_backend(proof.get("backend"))
    if (not proof.get("verified_at") or not proof.get("pid") or not proof.get("instance_id")
            or not proof.get("model_path") or not proof.get("model_alias")
            or props.get("model_path") != proof["model_path"]
            or props.get("model_alias") != proof["model_alias"]
            or props.get("build_info") != backend["build_info"]):
        raise ValueError("Remote hash proof does not identify the live /props model and build")
    if props.get("total_slots") != 1 or props.get("default_generation_settings", {}).get("n_ctx") != 2048:
        raise ValueError("Remote server must have one slot and a 2048-token context")
    return backend
