---
name: rhymeai-parity
description: "How RhymeAI keeps Android, iOS and the Python eval builder in lockstep: where the mirrored prompt, rhyme-list and complexity logic lives, the shared fixtures that pin equality, and how to prove parity before a PR. Use for any change to prompts, rhyme candidates, complexity hints, section parsing, chorus handling, or the pronunciation assets; also for parity, lockstep, mirror, fixture, drift."
---

# RhymeAI parity

The two apps build the same prompts with the same deterministic rhyme logic, and the Python eval
mirrors both so scorecards measure what the apps send. A change that reaches one side and not
the others silently changes what the student is scored on, or what the teacher data trains.

## Mirrored logic (change all three together)

| Concern | Android | iOS | Eval |
|---|---|---|---|
| Suggestion prompt | `android/.../service/AIService.kt` (local and cloud builders) | `Writers Block/Writers Block/Services/AIService.swift` | `finetune/eval/prompts.py` |
| Rhyme candidates, level lists, line filter (`RhymeLineFilter`) | `android/.../util/RhymeConstraint.kt` | `Writers Block/Writers Block/Services/RhymeConstraint.swift` | `finetune/eval/scoring.py` |
| Complexity labels and hints | `android/.../data/model/RhymeScheme.kt` | `Writers Block/Writers Block/Models/RhymeModels.swift` | `prompts.py` `RHYME_COMPLEXITIES` |
| Pronunciation / syllables | `ProsodyAnalyzer` + bundled dictionary | `ProsodyAnalyzer` + bundled dictionary | `scoring.syllable_count_word`, `cmudict-rhymeai.tsv` |

`PARITY.md` at the repo root records the rules and the known, accepted divergences (for example,
with Whole Song Context off iOS sends the cursor's stanza untrimmed while Android applies the
lyric window, and the on-device rhyme hint wording still differs). Read its "Next-line suggestion
prompt" section before changing any row above, and update it when you add or remove a divergence.

## Fixtures that pin equality

- `shared/fixtures/complexity-end-words-v1.json`: anchors × levels → expected lists; read by the
  Android and Python tests. Regenerate with `cd finetune && python3 -m eval.complexity_end_words_fixture`.
- `shared/fixtures/local-lyric-window-v1.json`: cursor-anchored lyric window.
- `finetune/eval/native-contract-cases-v1.json`: native prompt contract cases.
- Pronunciation assets: regenerate with `node scripts/generate-pronunciation-assets.mjs`, then
  review both platform outputs.

When a fixture changes, change it through its generator, not by hand, and commit the generator
run's output in the same commit.

## Proving parity

1. Strings that must be byte-identical (hints, rule sentences, list line format): pin them in
   `SuggestionPromptGuidanceTest.kt`, `SuggestionPromptGuidanceTests.swift` and
   `finetune/eval/test_*.py`; the test fails if one side drifts.
2. Lists and windows: assert against the shared fixture on both sides.
3. Prompt-level: build the same case on each side and compare the rendered prompt text
   (the eval's `run_eval.prepare_case` is the reference renderer).
4. For the teacher pipeline outside the repo, `prompt_equivalence.py` must prove byte equality
   against the pinned `prompts.py` before data is generated.

## Why the eval is the reference

The scorecard (43 cases + the held-out teacher test split) is built from `prompts.py`. If the
apps and the eval disagree, scorecard numbers stop predicting app behaviour. Fix the eval in the
same PR as the app change, never after.
