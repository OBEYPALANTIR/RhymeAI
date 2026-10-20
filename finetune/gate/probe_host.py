"""Record host evidence for legacy captures; never load a model or start a server."""
import argparse
import ast
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .backend import version_build
from .build import REPO, sha256, text_hash


def gate_launch(source):
    layers = []
    for node in ast.walk(ast.parse(source)):
        if (isinstance(node, ast.Assign) and isinstance(node.value, ast.List)
                and any(isinstance(target, ast.Name) and target.id == "command" for target in node.targets)):
            args = [arg.value if isinstance(arg, ast.Constant) else None for arg in node.value.elts]
            if "--n-gpu-layers" in args:
                layers.append(args[args.index("--n-gpu-layers") + 1:][:1])
    if layers != [["99"]]:
        raise ValueError("Legacy gate did not request 99 GPU layers")
    return {"source_sha256": text_hash(source), "n_gpu_layers": 99}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("/opt/homebrew/bin/llama-server"))
    parser.add_argument("--commit", action="append", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.absolute()
    version = subprocess.check_output([str(binary), "--version"], stderr=subprocess.STDOUT, text=True, timeout=30)
    devices = subprocess.check_output([str(binary), "--list-devices"], stderr=subprocess.STDOUT, text=True, timeout=30)
    commits = {}
    for ref in args.commit:
        commit = subprocess.check_output(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=REPO, text=True).strip()
        source = subprocess.check_output(["git", "show", f"{commit}:finetune/gate/generate.py"], cwd=REPO, text=True)
        commits[commit] = gate_launch(source)
    probe = {"observed_at": datetime.now(timezone.utc).isoformat(), "binary_path": str(binary),
             "binary_realpath": str(binary.resolve(strict=True)), "binary_sha256": sha256(binary),
             "binary_mtime_ns": binary.stat().st_mtime_ns, "version_output": version, "list_devices_output": devices,
             "build_info": version_build(version), "gate_commits": commits,
             "limitation": "Host evidence infers legacy Metal use; verbosity-3 capture logs did not observe GPU offload."}
    with args.out.open("x") as target:
        target.write(json.dumps(probe, indent=2) + "\n")
    print(f"{args.out}: {probe['build_info']}; binary SHA-256 {probe['binary_sha256']}")


if __name__ == "__main__":
    main()
