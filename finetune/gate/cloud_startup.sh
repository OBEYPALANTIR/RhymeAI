#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p /content/lane
exec > >(tee -a /content/lane/worker.log /dev/console) 2>&1
metadata() { curl --fail --silent --show-error --retry 3 -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1"; }
PREFIX="$(metadata instance/attributes/run-prefix)"
PROJECT="$(metadata project/project-id)"
NAME="$(metadata instance/name)"
ZONE="$(metadata instance/zone)"; ZONE="${ZONE##*/}"
finish() {
    result=$?
    trap - EXIT
    set +e
    timeout 45 gcloud storage cp /content/lane/*.json /content/lane/*.log "$PREFIX/evidence/" --quiet
    echo "SELF_DELETE $NAME $ZONE exit=$result"
    timeout 60 gcloud compute instances delete "$NAME" --zone="$ZONE" --project="$PROJECT" --quiet
    # Keep the VM running if deletion fails so its hard DELETE deadline remains armed.
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
timeout 600 bash -c 'until nvidia-smi; do sleep 10; done'
gcloud storage cp "$PREFIX/config.json" "$PREFIX/cloud_worker.py" "$PREFIX/backend.py" "$PREFIX/notebook.py" /content/lane/ --quiet
cd /content/lane
python3 cloud_worker.py initialize
python3 cloud_worker.py watch
