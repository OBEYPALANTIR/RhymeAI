# Selected v6-B data on Gemma 4 12B

`make_student_colab.py` packages the selected v6-B SFT examples for the existing
`train_teacher.py` 12B path. It does not use the rejected v8 DPO data or change
mobile model catalogs. The model revision, native turn envelope, response-only
loss, NF4 QLoRA, rank 16, learning rate 2e-5, effective batch 16 and one-epoch
12B recipe are inherited from the canonical teacher pilot. In pinned
Transformers 5.18, fractional `warmup_steps=0.03` expresses the warmup ratio;
`warmup_ratio` is no longer a supported argument.

Build from the private archived v6-B inputs and their full provenance records:

```sh
python3 finetune/train/make_student_colab.py \
  --inputs /private/v6-B/upload/inputs \
  --records /private/package-v6-B/records.jsonl \
  --source-commit COMMIT \
  --run-name gemma4-12b-UNIQUE \
  --out /private/new-output-directory
```

The generator verifies the three selected input hashes and reproduces every
training example byte for byte, in its original order, including repeated rows.
The original validation contains two synonym prompts also present in training;
only those two validation rows are excluded from the derived loss-validation
set. The manifest records their hashes and counts. The resulting counts are
5,285 training, 707 validation and 378 unchanged teacher-test examples. This
validation loss is not directly identical to the original v6 validation loss.
Missing group fields use the existing song ID, or prompt hash if no song ID is
available; the canonical group and exact-prompt disjointness checks still apply.

Open the private notebook in a fresh A100 Colab runtime. The generator fixes a unique run name; enter a freshly observed Resources CU/hour
rate and an authorized CU cap when setup asks. The optional `--units-per-hour`
and `--cu-cap` flags embed values verified immediately before launch. All source,
data, logs and checkpoints persist under that run in private Drive. Source and
input hashes, resolved dependency versions and batch size must match on resume.
The 90% CU allowance and six-hour ceiling are time bounds, not provider-enforced
billing limits. A runtime deadline timer also bounds setup and idle time; the
original deadline survives reconnection. A new budget window requires explicit
new authorization. Do not run this notebook in another task's runtime.

Run the ten-step smoke cell first. Inspect `supervised-row-0.txt`, token counts,
finite loss, adapter weight-change proof, and the saved checkpoint before the
full cell. The smoke uses the full one-epoch scheduler horizon. Full training
uses Trainer's explicit checkpoint resume, including optimizer, scheduler,
RNG state and data position; it does not extend a ten-step scheduler. A resume
onto another GPU class with a different microbatch is rejected. On reconnect,
select the latest complete checkpoint explicitly; never overwrite a prior run.
The notebook releases its owned runtime after the full cell flushes Drive.
Read back final files through Drive before claiming durable delivery.

The adapter remains a candidate. Before adoption, export with the existing
12B GGUF path and verify tensor/token/native prompt parity. Reuse the existing
frozen quality gates and unchanged held-out song sets, compare with the shipped
v6-B E2B and v2.1 E4B baselines, and add stock pinned 12B as a regression guard
for lyric craft. Use separate DEV selection; do not tune against frozen results.
Require real macOS llama.cpp inference, latency/memory, and author-review flows.
No GPU smoke, optimizer/resume execution, export, quality comparison or native
macOS runtime acceptance is established by local package/tokenizer checks.
