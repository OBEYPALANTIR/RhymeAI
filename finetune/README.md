# finetune/ — On-Device Model Evaluation Harness

The desktop evaluator is staged to replay captured local-model requests from the
iOS and Android production prompt builders. Each export carries the semantic request,
rendered prompt bytes, model and source hashes, tokenizer flags, ordered
sampler chain, seed provenance, termination policy, cache state, and runtime
provenance. Python copies of native prompt strings are not accepted as parity
evidence.

Python 3 stdlib only; model replay additionally requires `llama-server` at
`/opt/homebrew/bin/llama-server`.

Native producer changes are owned by the platform workstreams. Until both
producers land and generate paired exports, this evaluator is a model-free
contract and scoring gate; hand-authored records are not acceptance evidence.

## Layout

- `eval/native-contract-v1.schema.json` defines the single camelCase export
  shared by both native platforms. Its embedded record is illustrative and is
  rejected by exact replay.
- `eval/native_contract.py` validates contracts, verifies prompt hashes,
  rejects unknown sampler settings, and pairs platforms by `caseId` and the
  semantic `request`. Native prompt wording may differ across platforms.
- `eval/native-contract-cases-v1.json` is the shared case manifest for both
  native producer tests. It fixes case IDs and logical requests while each
  platform preserves its own prompt bytes and seed policy. Unexecuted iOS
  `contractExport` records truthfully leave a `randomPerRequest` seed null.
- `eval/run_eval.py` streams each captured rendered prompt through
  `llama-server`, applying the exported UTF-8-byte or UTF-16-code-unit response
  boundary at desktop stream-chunk boundaries.
- `eval/scoring.py` validates format, pronunciation/rhyme behavior, lexical
  spelling, control-marker leakage, duplicates, unchanged rewrites, and
  canonical rejected candidates.
- `eval/heldout-cases-v1.json` is the unseen rejection, inflection, part of
  speech, and contextual-substitution regression set. Human semantic ratings
  remain reported as unverified until people rate the outputs.
- `data/adversarial-training-cases-v1.json` contains separate training cases.
  `data/build_adversarial.py` accepts only native-exported prompts and refuses
  case IDs or semantic requests that overlap the held-out set.
- `eval/prompts.py` and `eval/cases.py` remain available for legacy baselines
  and synthetic data generation. Their generated prompts do not prove current
  native production parity.

## Native export contract

Both platform test targets emit the same required fields as JSON, a JSON array,
or one record per line in JSONL:

```text
schemaVersion, platform, sourceSha, modelSha256, caseId, requestKind
request.controls, request.localContext
prompt.userText, prompt.renderedText, prompt hashes, tokenizer metadata/flags
generation.engine, contextLength, sampler chain/seed, termination, cache
runtime target/OS/build/evidence kind/captured time
```

Task names are `suggestions`, `rewrite_passage`, `rewrite_word`, and
`synonyms`. Exact replay rejects placeholder provenance, missing seeds from
executed native runs, and sampler algorithms or fields it cannot reproduce.
A native producer test
must also prove that its exported prompt bytes equal the output of the builder
used for inference.

The response-length unit is part of the contract. iOS currently uses UTF-8
bytes and Android uses UTF-16 code units. Both native implementations append a
complete delivered piece before stopping at the limit, so the final value can
cross the limit by one native piece. The desktop evaluator mirrors that rule
for each server content chunk and records the prior and final lengths. Its
report labels the run `controlledReplay` because desktop stream chunks do not
reproduce native token boundaries, engine behavior, or cache state.

## Run a contract replay

```sh
python3 finetune/eval/run_eval.py \
  --model /path/to/accepted-model.gguf \
  --contracts /path/to/ios-contracts.json /path/to/android-contracts.json \
  --replay-seed 3407 \
  --case-manifest finetune/eval/native-contract-cases-v1.json \
  --out /path/to/report.json
```

The runner verifies the GGUF SHA-256 against every selected record, requires
paired iOS and Android case IDs with matching semantic requests, starts one
bounded `llama-server`, and writes model output plus format, lexical,
pronunciation, contextual-fixture, latency, and termination evidence. It stops
the server on exit and writes the server log beside the report.
The required replay seed controls only the desktop `controlledReplay`; reports
preserve each native seed policy/value separately and never claim the desktop
seed reproduces a native random draw.

## Build the adversarial training rows

After both native test targets export the separate `train_adv_*` case IDs:

```sh
python3 finetune/data/build_adversarial.py \
  --contracts /path/to/ios-contracts.json /path/to/android-contracts.json \
  --out finetune/data/out/adversarial-v1.jsonl
```

The generated rows use each platform's own native `prompt.userText` and include
source, model, and prompt hashes. The builder validates every positive
completion and rechecks that training and held-out semantic requests remain
disjoint.

## Checks without a model

```sh
PYTHONPYCACHEPREFIX=/tmp/rhymeai-pycache \
  python3 -m unittest finetune.eval.test_model_contract -v
python3 finetune/eval/native_contract.py \
  --manifest finetune/eval/native-contract-cases-v1.json \
  --require-pairs /path/to/ios-contracts.json /path/to/android-contracts.jsonl
python3 -m json.tool finetune/eval/native-contract-v1.schema.json >/dev/null
python3 -m json.tool finetune/eval/heldout-cases-v1.json >/dev/null
python3 -m json.tool finetune/data/adversarial-training-cases-v1.json >/dev/null
```

The pronunciation and lexical scorers consume the shared assets in
`shared/pronunciation/`. Dictionary membership establishes spelling validity;
it does not establish part-of-speech or semantic fit, which are scored
separately.
