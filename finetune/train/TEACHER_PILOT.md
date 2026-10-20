# Gemma 4 12B teacher candidate pilot

This isolated pilot trains a text LoRA adapter against pinned
`google/gemma-4-12B-it` revision
`707f0a3b8a3c7ad586ed01e27eafbad8a27dd0f7`. It does not replace either
mobile model or accept the result as a teacher for distillation.

The input is the previously recovered, private synthetic training package.
`teacher_data.py` checks the two archived source hashes, rejects malformed
outputs, and rebuilds the split by normalized lyric context or synonym target.
Exact prompts also join groups. The old train/validation boundary is discarded
because it contained overlapping contexts. Structural filtering does not prove
that an example is a good lyric or synonym.

From the repository root, using a new output directory:

```sh
python3 finetune/train/teacher_data.py \
  --archive /absolute/path/prior-training-package.tar.gz \
  --out .agents/scratch/teacher-data-v1
python3 -m unittest discover -s finetune/train -p test_teacher_data.py -v
python3 finetune/train/make_teacher_colab.py \
  --data .agents/scratch/teacher-data-v1 \
  --out .agents/scratch/teacher-pilot.ipynb \
  --run-name gemma12b-teacher-UNIQUE
```

Keep the generated notebook private: it embeds the dataset. Use an A100 Colab
runtime where available. Run staging, read the current compute-unit rate in
Resources, then start training with that rate. `--units-per-hour RATE` can embed
a rate just verified for the selected runtime to avoid an interactive input.
Recheck the rate if the GPU changes. Do not reuse a run name or overwrite an
existing run folder.

The notebook checks 48 GB of runtime disk space and writes a persistence probe
under `MyDrive/RhymeAI Training/<run-name>`. It installs pinned Transformers,
PEFT, Accelerate and bitsandbytes in a runtime-local virtual environment that
uses Colab's existing PyTorch. It records the resolved package versions.
Base weights stay on Colab's temporary disk. Source, data, logs, checkpoints,
adapter and evaluation output are written to the private Drive folder.

Training uses NF4 QLoRA, text projection adapters only, rank 16, learning rate
2e-5, effective batch 16, and one epoch. Training and generation use the
app's own Gemma 4 envelope, not the 12B chat template: one `<bos>`, then
`<|turn>user\n{prompt}<turn|>\n<|turn>model\n`, with no system turn, no
thought channel and no trimming of the prompt, exactly as
`GGUFModelService.gemmaPrompt` renders it on device. Only complete assistant
answers and their `<turn|>` terminators contribute to loss. The recorded
2026-10-04 preflight evidence predates this envelope change and documents the
template-based prefix of that run. Every row is checked for token
boundary integrity; overlong examples fail rather than silently truncating.
Prompt and padding labels are masked. Validation loss comes from a separate
96-prompt balanced validation subset.

The first ten optimizer steps must change adapter weights. Checkpoints are
saved at step 10 and every 100 steps thereafter. Progress includes projected
completion time and allocated GPU memory. If the run is projected to exceed
its deadline, training stops with a partial checkpoint. There is no automatic
resume: inspect a partial checkpoint and its remaining budget before planning
another attempt.

The deadline is the earlier of six hours or 180 compute units at the observed
hourly rate, leaving 20 units below the 200-unit planning budget. This is a
time-based bound, not a provider-side spending limit. Staging has a 20-minute
watchdog; the longer deadline activates after the persistence probe. The
controller releases its runtime after completion or failure, attempts to flush
Drive, and has an independent deadline thread. Verify actual balance and Drive
readback afterward; a failed flush does not establish durable storage.

Before training, stock 12B generates 48 responses across 24 held-out prompts
and two seeds. After training, the saved adapter is reloaded and uses the same
prompts and seeds. `comparison.json` records formatting only; the responses
still require blind review for naturalness, instruction compliance, meaning,
rhyme and synonym accuracy. `teacher_accepted` remains false. Do not generate
student-training targets from this candidate until quality improves without
material regressions. Neither this pilot nor a lower validation loss proves
Mac inference, GGUF export, application integration or shipping readiness.
