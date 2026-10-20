#!/usr/bin/env bash
# Best effort only: Compute Engine may give a Spot shutdown at most 30 seconds.
set -u
metadata() { curl --max-time 3 --fail --silent -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1"; }
PREFIX="$(metadata instance/attributes/run-prefix)" || exit 1
PREEMPTED="$(metadata instance/preempted)"
python3 -c 'import json,sys,time; print(json.dumps({"preempted":sys.argv[1],"shutdown_unix":time.time(),"resume":"Rerun the same package with a new run-id; cached weights/builds are reused. Training restarts from seed 3407."}))' "$PREEMPTED" > /content/shutdown.json
timeout 20 gcloud storage cp /content/shutdown.json /content/worker.log "$PREFIX/" --quiet
