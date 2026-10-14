# Scripted round-2 E2B training on Google Cloud

This path runs the existing, frozen v5 round-2 notebook headlessly on **one
Spot A100 80GB, or a Spot L4 when A100 capacity is unavailable**, using `gcloud` from the Mac. No Colab session, browser,
Drive connector, Hugging Face upload, service-account key, app change, or
catalog change is involved. The notebook and training data stay outside Git.

The 2026-10-14 smoke attempt stopped at the capacity gate: A100 80GB was
stocked out in `us-central1-a/c`, then L4 (`g2-standard-12`) was stocked out
in `us-central1-a/b/c`. All five requests returned
`ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS`. No VM started; final instance
and disk lists were empty. Package SHA readback and six local checks passed.
GPU training, loss comparison, GGUF exports, cache hits, and guest deletion
remain **NOT RUN**. Do not treat this implementation as a completed reproduction.

## Prerequisites

- Existing authenticated `gcloud`, Python 3.11+, and project `rhymeai-training`.
- Existing billing and quotas: one GPU globally, one Spot A100 80GB and one Spot L4 in
  `us-central1`. The scripts never request quota or change billing/IAM.
- The existing Compute Engine default service account must be able to read/write
  the bucket and delete its VM. This project already grants it Editor; this
  implementation does not add that permission or create an identity.
- `/Volumes/Untitled` mounted, with at least 12 GB free. Downloads are rejected
  outside `/Volumes/Untitled/models/rhymeai/`, including paths resolving through
  a symlink to the internal disk. Existing different output bytes are preserved.
- Original package `~/.agents/artifacts/2026-10-14/rhymeai-colab-package-v5/`.

On this Mac the SDK's Python 3.14 environment fails loading `gcloud storage`
with `ssl.PROTOCOL_TLSv1`. Select the already-installed Python 3.12 for the
command; no SDK replacement is necessary:

```sh
export CLOUDSDK_PYTHON="$HOME/.local/share/uv/python/cpython-3.12.13-macos-aarch64-none/bin/python3.12"
gcloud auth list --filter=status:ACTIVE
gcloud storage buckets list --project=rhymeai-training
```

If inspecting Cloud Quotas, include `--billing-project=rhymeai-training`.
The default client project can hit a shared daily limit.

## Launch and collect

From the repository root, use a fresh run ID and output directory:

```sh
python3 finetune/train/gcp/run.py run \
  --package "$HOME/.agents/artifacts/2026-10-14/rhymeai-colab-package-v5" \
  --run-id e2b-20261014-03 \
  --output /Volumes/Untitled/models/rhymeai/students-v5-gcp-20261014/E2B \
  --evidence "$HOME/.agents/artifacts/2026-10-14/rhymeai-gcp-smoke/run-03" \
  --spent-usd 0.01
```

Keep the command running. It creates a project-number-scoped bucket in
`us-central1` if missing, with uniform access and public access prevention.
It hashes the notebook and input files, uploads a small tar package, downloads
it back to external storage, and verifies SHA-256 before requesting a VM.

The controller refuses a project with existing VMs or disks, discovers zones
offering the A100 80GB, and tries them sequentially, followed by every eligible
L4 zone. Only confirmed capacity or quota rejection moves to the next candidate.
The default command stays in us-central1 on Spot pricing.
At most one VM is created; it does not automatically retry a preempted run.

After central Spot capacity is exhausted, an explicitly authorized broader
search can use `--extended-l4` with a new run ID. That mode tries L4 Spot in
`us-east1`, `us-east4`, `us-west1`, then `us-west4`; if all reject the request,
it tries on-demand L4 in `us-central1` followed by those same four regions.
It discovers and tries every eligible zone within each region. It uses the
same `g2-standard-12`, recipe, four-hour DELETE deadline and $15 budget check.
Existing regional L4 quotas are required; the runner does not request them.
The GCS bucket stays in us-central1, so cross-region transfers can add charges.

```sh
python3 finetune/train/gcp/run.py run --extended-l4 \
  --package "$HOME/.agents/artifacts/2026-10-14/rhymeai-colab-package-v5" \
  --run-id e2b-20261014-04 \
  --output /Volumes/Untitled/models/rhymeai/students-v5-gcp-20261014/E2B-run04 \
  --evidence "$HOME/.agents/artifacts/2026-10-14/rhymeai-gcp-smoke/run-04" \
  --spent-usd 0.01
```

For that mode `--provisioning-model` changes to `STANDARD` only after every
additional Spot candidate has failed. On-demand is never selected without
`--extended-l4`; the quoted Spot rate is not used for its cost calculation.

The VM uses `a2-ultragpu-1g` (12 vCPU, 170 GiB RAM) or `g2-standard-12`
(12 vCPU, 48 GiB RAM), the dated Deep Learning VM image
`common-cu129-ubuntu-2404-nvidia-580-v20261001`, a 200 GB auto-delete
balanced boot disk (G2 does not support `pd-standard`), and these settings:

```text
--provisioning-model=SPOT
--instance-termination-action=DELETE
--max-run-duration=7200s
--maintenance-policy=TERMINATE
--no-restart-on-failure
```

The A100 deadline is 7200 seconds; the L4 deadline is 14400 seconds.
`--max-hours` can lower either limit but cannot raise it. Pass cumulative
previous task usage in `--spent-usd`, including failed runs; the controller
rejects a new run if its worst-case runtime plus prior spend and a $3 reserve
exceed $15. The first two stockout attempts used no GPU time, so the example
reserves $0.01 for their small GCS transfers and operations. Startup
traps success and failure, uploads logs/status, and requests its own deletion.
The controller also cleans up this run's resources in `finally`. The platform
deadline continues to apply if the Mac disconnects or the guest fails.
If the guest's delete request fails, it leaves the platform deadline active;
it does not halt the VM, because stopping clears the scheduled termination
timestamp. See [Google's runtime-limit behavior](https://docs.cloud.google.com/compute/docs/instances/limit-vm-runtime).

The controller downloads only products listed in the remote `SAVED_OK`, checks
every SHA-256, and writes `download-verification.json` after full destination
readback. The marker is published only after each product has been uploaded
and independently streamed back from GCS for SHA-256 verification.

If the Mac disconnects after the VM saved its results, rerun only collection:

```sh
python3 finetune/train/gcp/run.py collect \
  --run-id e2b-20261014-03 \
  --output /Volumes/Untitled/models/rhymeai/students-v5-gcp-20261014/E2B \
  --evidence "$HOME/.agents/artifacts/2026-10-14/rhymeai-gcp-smoke/run-03"
```

## What is reused

The adapter requires notebook SHA-256
`2f3a900ad5531716991955fc73aa52107d9016d78f088b98fc7c96e95887dcab`.
It executes its configuration, input verification, GPU check, envelope check,
training function, training call, CUDA build, both exports, and save checks.
The only adaptations are local paths, GCS transport, dependency installation,
epoch-copy persistence, preservation of round 2's 8 x 2 batch on L4, and removal
of the Colab flush/release calls. The notebook otherwise selects 2 x 8 on GPUs
below 35 GB; retaining 8 x 2 avoids silently changing the reproduction recipe.

The training function is executed unchanged. Both epoch adapters are copied
and SHA-verified by the notebook's existing callback before GCS persistence.
Startup creates an isolated Python 3.12 environment from Ubuntu 24.04's system
Python and installs its development headers for runtime CUDA helper compilation.
The Ubuntu 22.04 DLVM's Python 3.10 cannot install round 2's pinned
TRL 1.15.0, which requires Python 3.11 or newer; that failed bootstrap is
retained in run-04 evidence. The failed VM saved its logs and deleted itself.
The seven top-level training dependencies are pinned to versions recorded in
round 2; the VM prints the resolved transitive environment with `pip freeze`.

Recipe: `unsloth/gemma-4-E2B-it` at
`d36bdd3855c82a6a1a23f7c459b749f5724ae75d`, BF16 LoRA, rank/alpha 16,
dropout 0, learning rate .0002, cosine decay, 3% warmup, AdamW 8-bit,
weight decay .001, batch 8 x accumulation 2, sequence limit 2048,
seed 3407, two epochs, no packing, response-only masking.

The notebook checks tokenizer SHA, all 275 row-zero prompt token IDs, one BOS,
no thought channel, no truncation, and the supervised completion boundary.
Its export uses pinned BF16 weights and llama.cpp b9949 commit
`049326a00025d00b08cc188ed716b681e984a3f8`, retaining the raw-config converter
workaround, both Q4_K_M exports, shared-KV tensor checks, and `gguf_check.py`.

Private GCS caches store the pinned HF base, pinned BF16 GGUF, and the CUDA
llama.cpp checkout/build. Each cache is a SHA-verified tar preserving symlinks;
the build key includes commit, dated VM image and the actual GPU architecture
(`sm80` on A100, `sm89` on L4). The notebook's existing CMake call targets that
architecture, so an L4 run cannot restore an A100-only binary.
Cache markers are written last. Later runs restore verified caches; the
notebook's build cell skips compilation when its binaries already exist.

## Preemption and failures

There is no automatic paid retry. A Spot shutdown attempts to save
`shutdown.json` (including the metadata `preempted` value) and the current log.
The platform's shutdown window is best effort, so the controller also retains
Compute Engine operations, serial output, and observed deletion. Missing
`SAVED_OK` is always failure, never evidence of a successful run.

To resume the work after preemption, inspect the logs and launch the **same
package with a new run ID** after confirming the project is empty. This starts
training again from seed 3407; it does not claim mid-epoch continuation.
Completed epoch checkpoints remain in GCS for recovery/inspection. Verified
base/build caches are reused. Count previous VM time toward the task's spend
cap before authorizing any new run.

To terminate an owned run early, delete its exact VM and verify cleanup:

```sh
gcloud compute instances delete rhymeai-e2b-20261014-03 \
  --zone=us-central1-a --project=rhymeai-training
gcloud compute instances list --project=rhymeai-training --format=json
gcloud compute disks list --project=rhymeai-training --format=json
```

Use the actual zone in `instance.json`. Do not delete unrelated resources.
An unavailable zone is recorded in `create-<mode>-<machine>-<zone>.log` and `lifecycle.jsonl`.
If every requested candidate rejects the request, stop; no quota or billing configuration changes
are an authorized fallback.

## Evidence and costs

The local evidence directory contains package hashes, bucket settings, the
created instance, lifecycle events, serial/worker logs, phase timings, Compute
Engine operations, cost calculation, download readback, and before/after
instance/disk inventories. Model files and staging packages stay external.

At the published `us-central1` prices checked on 2026-10-14:

- Spot `a2-ultragpu-1g`: $3.038823151/hour, including GPU, CPU, RAM and bundled
  Local SSD; Spot `g2-standard-12`: $0.598648/hour.
  [Spot prices](https://cloud.google.com/spot-vms/pricing)
- On-demand reference: $5.06879789/hour. Two hours plus a $3 reserve for boot
  disk, public IPv4, GCS operations/storage and export downloads is $13.14,
  before prior task spend. L4's on-demand reference is about $1.0004163/hour;
  four hours plus the same reserve is $7.00 before prior spend.
  Both bounds are below $15 with the example's $0.01 prior-spend reserve.
  [VM prices](https://cloud.google.com/products/compute/pricing/accelerator-optimized)
- Regional Standard GCS: $0.000027397/GiB-hour (about $0.02/GiB-month), plus
  operations and internet egress. [Storage prices](https://cloud.google.com/storage/pricing)

The extended L4 mode uses these regional list rates from the public
[Cloud Billing catalog](https://cloud.google.com/billing/v1/how-tos/catalog-api),
effective 2026-10-14. Each total is 12 CPU hours + 48 GiB RAM hours + one L4 hour:

| Region | Spot USD/hour | On-demand USD/hour |
| --- | ---: | ---: |
| us-central1, us-east1, us-west1 | 0.598648 | 1.000416287 |
| us-east4 | 0.532016 | 0.997140504 |
| us-west4 | 0.674384 | 1.126768820 |

Four hours at the largest on-demand rate plus the $3 reserve and $0.01 prior
spend is $7.5171. The aggregate task cap remains $15, not $15 per attempt.

`cost.json` uses observed creation-to-deletion time multiplied by the selected
region's Spot or on-demand list
price; provisioning and the polling interval make this a conservative runtime
estimate, **not a billing invoice**. Report boot disk, IP, download and retained
storage separately. Refresh prices before later runs; the monthly budget alert
does not enforce a spend limit. `--spent-usd` must include usage from earlier
invocations; this is an explicit task budget, not an account-wide billing cap.

Empty instance/disk lists prove no compute or persistent disks remain. The
requested GCS cache and outputs remain private and incur storage charges;
they cannot truthfully be described as zero ongoing billing.

## Local checks

```sh
python3 -m unittest discover -s finetune/train/gcp -p 'test_*.py' -v
python3 finetune/train/gcp/run.py --help
bash -n finetune/train/gcp/startup.sh finetune/train/gcp/shutdown.sh
```

These checks cover package integrity, path boundaries, capacity order and
runtime/spend limits. They do not establish GPU training,
preemption, cache-hit behavior, or export correctness; those require the
recorded cloud smoke run.
