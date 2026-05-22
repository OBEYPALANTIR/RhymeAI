# RhymeAI Pronunciation Data

`cmudict-rhymeai.tsv` is generated from the public CMU Pronouncing Dictionary package maintained at:

https://github.com/words/cmu-pronouncing-dictionary

Regenerate the shared web/Android asset and the iOS resource copy with:

```sh
node scripts/generate-pronunciation-assets.mjs
```

The generated TSV groups alternate pronunciations under one normalized word:

```text
word<TAB>ARPABET variant|ARPABET variant
```
