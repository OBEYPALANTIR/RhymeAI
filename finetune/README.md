# finetune/ — On-Device Model Evaluation Harness

Desktop evaluation harness for the app's on-device Gemma models. It replays
the Android app's **exact** local-model prompts against a GGUF via llama.cpp
(`llama-server`) and scores the raw outputs programmatically. This is the
before/after quality gate for LoRA fine-tunes: run it on the base model to get
a baseline, run it again on the tuned model, and compare the reports.

Python 3 stdlib only — no pip dependencies.

## Layout

- `eval/prompts.py` — byte-identical ports of the Kotlin prompt builders
  (`buildLocalPrompt`, `buildLocalRewritePrompt`, `buildLocalSynonymsPrompt`,
  section directives, and the rhyme-constraint construction from
  `AIService.kt`), plus the app's on-device turn envelope (`app_prompt`,
  ported from `GGUFModelService.swift`).
- `eval/scoring.py` — CMU-dictionary phonetics ported from
  `ProsodyAnalyzer.kt` / `RhymeConstraint.kt` (rime extraction, perfect-rhyme
  check, candidate end-words, syllable counting) plus output-format validators
  mirroring the app's cleaning rules.
- `eval/cases.py` — 43 eval cases across all four local-model tasks
  (constrained/unconstrained suggestions across sections and complexities,
  passage rewrites x3 actions, single-word rewrites x3 actions including
  rejected-word retries, synonyms). All lyric contexts are original
  placeholder lyrics.
- `eval/run_eval.py` — the CLI runner.
- `eval/native-contract-v1.schema.json` + `eval/native-contract-cases-v1.json`
  — the native-contract-v1 export shape and the frozen case manifest the
  Android producers (`NativePromptContractExportTest`,
  `LocalModelInstrumentedTest`) read. `eval/native_contract.py` validates the
  exported JSON/JSONL: exact key sets, prompt hashes, sampler chain, seed and
  evidence policy, and agreement with the manifest (and with the other
  platform when `--require-pairs` is passed).

## Running a baseline

llama.cpp must be installed (`brew install llama.cpp`; the harness expects
`/opt/homebrew/bin/llama-server`). The app's GGUFs live under
`artifacts/gemma-local-models/`.

```sh
cd /Users/tylermanring/Desktop/RhymeAI

# E2B baseline
python3 finetune/eval/run_eval.py \
  --model artifacts/gemma-local-models/gemma-4-E2B-it-UD-Q4_K_XL.gguf \
  --out finetune/baseline-E2B.json

# E4B baseline
python3 finetune/eval/run_eval.py \
  --model artifacts/gemma-local-models/gemma-4-E4B-it-UD-Q4_K_XL.gguf \
  --out finetune/baseline-E4B.json

# Smoke test on the first 5 cases only
python3 finetune/eval/run_eval.py \
  --model artifacts/gemma-local-models/gemma-4-E2B-it-UD-Q4_K_XL.gguf \
  --cases 5 --out /tmp/smoke.json
```

The runner starts `llama-server` itself (ctx 2048; temp 0.8, top-k 40,
top-p 0.95 — the mobile sampler contract), POSTs each request to `/completion`
(which applies **no** chat template) as the inner prompt wrapped in the app's
on-device envelope — `--envelope gemma4` by default, as the app sends the
shipped E2B/E4B models; `--envelope legacy` for imported Gemma 1-3n GGUFs and
to reproduce pre-Gemma-4 baselines. The text carries no `<bos>`: llama-server
adds one to a raw prompt when the GGUF sets `add_bos_token`, as llama.cpp
does in the app. It warns when the served chat template uses other turn
markers than the chosen envelope. It then scores each
response, writes the JSON report, and prints a per-task summary: format-pass
rates, rhyme-compliance tiers (perfect end-word from the candidate list /
rhymes-with-target / miss), average latency, and average output tokens. The
server is killed on exit; its log is written next to the report.

Sanity checks that don't need a model:

```sh
cd finetune
python3 -m eval.prompts   # prints one fully templated prompt per task
python3 -m eval.cases     # case counts + id uniqueness
python3 finetune/eval/run_eval.py --help   # (from repo root)
```

### Validating an Android native-contract export

`eval/native_contract.py` accepts only records produced by the instrumented
stage (`runtime.evidenceKind = "contractExport"`, a real RFC 3339
`capturedAt`, the manifest's `modelSha256`, a producer commit that descends
from the manifest's `baseSourceSha`). The JVM stage alone writes
`evidenceKind = "contractInput"` with a current-catalog model hash and is
rejected by design; it is the input to the instrumented stage, not evidence.

Prerequisites (all existing tooling; nothing here downloads a model):

- A GGUF whose SHA-256 equals `modelSha256` in
  `eval/native-contract-cases-v1.json` (`059e7328…`, the E2B build the catalog
  shipped before commit `2c67e15` moved E2B to v2; `GemmaDownloadsTest` keeps it
  as `previousSha`). The current catalog E2B (`GemmaDownloads.kt`,
  `902e5d83…`) does **not** match; an export from it fails
  `model SHA differs from manifest` until the manifest is re-frozen, which is
  an owner decision. Check the file first:
  `shasum -a 256 /path/to/model.gguf`.
- An empty, booted, disposable emulator in `ANDROID_SERIAL` (see the
  local-model smoke in the root `README.md`); the debug app and its
  `androidTest` APK installed on it, as `scripts/android-local-model-smoke.sh`
  does. The export records the hash you pass in step 1, not the pushed file's
  hash, so the `shasum` check above is what binds them.
- The validator runs `git` against this checkout, so run step 1 and step 3 in
  the same checkout and do not amend or rebase its `HEAD` in between.

```sh
# 1. JVM stage: render the 12 manifest cases through the production prompt
#    builders (android/app/build/native-contract-v1/android-input.jsonl).
cd android
RHYME_NATIVE_MODEL_SHA256=059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626 \
  ./gradlew :app:testDebugUnitTest \
  --tests 'com.rhymeai.app.service.NativePromptContractExportTest.exportsSharedManifestThroughProductionBuilders'

# 2. Instrumented stage: load the GGUF, format every case with the model's own
#    chat template, stamp evidenceKind=contractExport and the capture time.
adb -s "$ANDROID_SERIAL" push /path/to/model.gguf /data/local/tmp/rhymeai-model.gguf
adb -s "$ANDROID_SERIAL" push app/build/native-contract-v1/android-input.jsonl /data/local/tmp/android-input.jsonl
adb -s "$ANDROID_SERIAL" shell chmod 644 /data/local/tmp/rhymeai-model.gguf /data/local/tmp/android-input.jsonl
adb -s "$ANDROID_SERIAL" shell am instrument -w \
  -e class 'com.rhymeai.app.LocalModelInstrumentedTest#localGgufModelLoadsAndGeneratesText' \
  -e localModelPath /data/local/tmp/rhymeai-model.gguf \
  -e nativeContractInputPath /data/local/tmp/android-input.jsonl \
  -e nativeContractCapturedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -e nativeContractTarget "$ANDROID_SERIAL" \
  com.rhymeai.app.test/androidx.test.runner.AndroidJUnitRunner
# Output defaults to the app cache (nativeContractOutputPath overrides it):
adb -s "$ANDROID_SERIAL" exec-out run-as com.rhymeai.app cat cache/android-native-contract.jsonl \
  > app/build/native-contract-v1/android-native-contract.jsonl
cd ..

# 3. Validate against the frozen manifest (from repo root).
python3 finetune/eval/native_contract.py \
  --manifest finetune/eval/native-contract-cases-v1.json \
  android/app/build/native-contract-v1/android-native-contract.jsonl
```

`--require-pairs` additionally demands a matching iOS export per case; no iOS
producer exists yet, so leave it off for Android-only runs. Without
`nativeContractCapturedAt` the export carries `capturedAt = "not-recorded"`
and is rejected.

## ⚠️ Parity contract

`eval/prompts.py` mirrors
`android/app/src/main/kotlin/com/rhymeai/app/service/AIService.kt` (and the
enum strings in `data/model/RewriteAction.kt`, `SongSection.kt`,
`RhymeScheme.kt`) **byte for byte**. The whole point of this harness is that
the model sees exactly what the app sends. If any prompt string, section
directive, constraint sentence, or the Gemma turn template changes in the
Android (or iOS-parity) code, `eval/prompts.py` must be updated in the same
commit — otherwise baseline and post-finetune numbers measure the wrong thing.
Do not "improve" the prompts here.

Scoring parity: `eval/scoring.py` ports only what scoring needs from
`ProsodyAnalyzer.kt` / `RhymeConstraint.kt`, backed by the same shared assets
(`shared/pronunciation/cmudict-rhymeai.tsv`,
`shared/pronunciation/word-frequency.txt`). Frequency ties may order rhyme
candidates slightly differently than Kotlin's hash-map iteration, which can
affect the tail of the 12-word candidate list on rare ties — everything else
is deterministic and identical.
