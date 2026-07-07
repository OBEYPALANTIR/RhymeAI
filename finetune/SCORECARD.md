# RhymeAI Gemma fine-tune v1 — before/after scorecard

Same 43-case eval (finetune/eval), same sampler contract (temp 0.8, top-k 40,
top-p 0.95, ctx 2048), scored on the quantized GGUFs. Baselines are the shipped
unsloth UD-Q4_K_XL models; tuned models are our Q4_K_M exports (quant delta is
included in the comparison).

| Task (metric)                      | E2B stock | E2B tuned | E4B stock | E4B tuned |
|------------------------------------|-----------|-----------|-----------|-----------|
| Suggestions — format pass          | 4%        | **96%**   | 4%        | **83%**   |
| Suggestions — rhyme hit            | 60%       | **92%**   | 82%       | 84%       |
| Passage rewrite — format pass      | 0%        | **100%**  | 33%       | **83%**   |
| Single-word rewrite — format pass  | 56%       | 22%*      | 11%       | **78%**   |
| Harder-rhyme = perfect rhyme       | 0/3       | 2/2       | 2/3       | 2/3       |
| Synonyms — format pass             | 0%        | 50%       | 0%        | 0%**      |

*  E2B single-word regression: empty answers / stray ">" prefix — under-trained
   task (531/5099 examples). The app's retry + fallback word maps cover it at
   runtime. v2 fix: top up rewrite_word data 3-4x, consider lower sampling temp
   for one-word tasks.
** E4B synonyms fail raw scoring only on within-list duplicates; the app's
   parser dedupes before display. v2 fix: more synonym examples + dedup-aware
   generation sampling.

Marker leakage (`_response>` etc.) is eliminated on the winning paths; the
tuned models natively speak the app's raw Gemma template (gemma-4 tokenizes it
as plain text — discovered during training, see train_lora.py comments).

Training: Colab L4, QLoRA r=16/alpha=16, 2 epochs over 4,947 verified examples.
E2B final train loss 0.253 / val 1.232; E4B train loss 0.124.
Artifacts: finetune/train/out/gguf/gemma-4-{E2B,E4B}-it-rhymeai-Q4_K_M.gguf
Reports: finetune/tuned-{E2B,E4B}.json vs finetune/baseline-{E2B,E4B}.json
