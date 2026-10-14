#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p /content
exec > >(tee -a /content/worker.log /dev/console) 2>&1
metadata() { curl --fail --silent --show-error --retry 3 -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1"; }
export RUN_PREFIX="$(metadata instance/attributes/run-prefix)"
export IMAGE_NAME="$(metadata instance/attributes/image-name)"
PROJECT="$(metadata project/project-id)"
NAME="$(metadata instance/name)"
ZONE="$(metadata instance/zone)"; ZONE="${ZONE##*/}"
finish() {
    result=$?
    trap - EXIT
    set +e
    python3 -c 'import json,sys,time; print(json.dumps({"exit_code":int(sys.argv[1]),"finished_unix":time.time()}))' "$result" > /content/status.json
    timeout 90 gcloud storage cp /content/worker.log /content/status.json "$RUN_PREFIX/" --quiet
    if [[ -f /content/phases.json ]]; then
        timeout 30 gcloud storage cp /content/phases.json "$RUN_PREFIX/phases.json" --quiet
    fi
    echo "SELF_DELETE $NAME $ZONE exit=$result"
    timeout 60 gcloud compute instances delete "$NAME" --zone="$ZONE" --project="$PROJECT" --quiet
    # Do not halt on delete failure: stopping clears Compute Engine's deletion deadline.
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# DLVM's first boot can still be bringing up the preinstalled NVIDIA driver.
timeout 600 bash -c 'until nvidia-smi; do sleep 10; done'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cmake build-essential git curl python3.12 python3.12-venv python3.12-dev
mkdir -p /content/package
gcloud storage cp "$RUN_PREFIX/package.tar.gz" /content/package.tar.gz --quiet
EXPECTED_SHA="$(metadata instance/attributes/package-sha256)"
printf '%s  %s\n' "$EXPECTED_SHA" /content/package.tar.gz | sha256sum --check
tar -xzf /content/package.tar.gz -C /content/package
cd /content/package/inputs
sha256sum --check SHA256SUMS
cd /content
# TRL 1.15 requires Python >=3.11; keep training packages separate from gcloud's Python.
/usr/bin/python3.12 -m venv /content/venv
PYTHON=/content/venv/bin/python
"$PYTHON" -c 'import sys; assert sys.version_info[:2] == (3, 12); print(sys.version)'
export HF_HOME=/content/hf-cache
export PIP_CACHE_DIR=/content/pip-cache
export TOKENIZERS_PARALLELISM=false
"$PYTHON" -m pip install --quiet ipython
"$PYTHON" -u /content/package/notebook.py
