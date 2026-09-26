# Model evaluation

How to reproduce:

```
dev llama                                   # build llama-server once
eval/run-models.sh ~/Library/Application\ Support/Aure/Models/*.gguf
# Other architectures (Python venv under eval/.venv):
eval/.venv/bin/python eval/compare_seq2seq.py "grammarly/coedit-large:Fix grammatical errors in this sentence: " ...
eval/.venv/bin/python eval/compare_gector.py gotutiyan/gector-roberta-base-5k verb-form-vocab.txt
```

Test set: `eval/golden/*.jsonl`, 50 cases (31 with errors, 19 correct sentences that must stay unchanged).
It covers Slack-style and email-style text, confused words (your/you're, its/it's, their/there/they're,
whose/who's), agreement, pronoun case, word choice and Canadian spelling. This is still small; the goal
is 150+ (issue #11).

"Errors fixed" means an exact match with an acceptable answer (after ignoring a trailing period and
first-letter case). Hardware: Intel i7-8850H, 16 GB, CPU only (no GPU). Apple Silicon is several
times faster.

## Results (2026-09-26, full Aure pipeline, plain-text output)

| model | size | errors fixed | clean kept | p50 | p95 |
|---|---|---|---|---|---|
| **Qwen3 4B** | 2.50 GB | **90% (28/31)** | 95% (18/19) | 1.6 s | 7.9 s |
| Qwen3.5 4B | 3.01 GB | 87% (27/31) | 95% (18/19) | 2.0 s | 13.9 s |
| Qwen3 1.7B | 1.28 GB | 84% (26/31) | 89% (17/19) | 0.7 s | 3.3 s |
| Qwen3.5 2B | 1.40 GB | 68% (21/31) | 100% (19/19) | 0.9 s | 5.6 s |
| Qwen3 0.6B | 0.48 GB | 45% (14/31) | 79% (15/19) | 0.4 s | 1.3 s |

Other architectures (same cases, own scripts):

| model | type | errors fixed | clean kept | p50 | RAM |
|---|---|---|---|---|---|
| GRMR-V3 Qwen3 1.7B | grammar fine-tune | 67% | 100% | 0.5 s | ~1.1 GB |
| grammarly/coedit-large | T5 (770M) | 61% | 58% | 1.5 s | ~3 GB fp32 |
| vennify/t5-base-grammar-correction | T5 (220M) | 51% | 84% | 0.4 s | ~1 GB fp32 |
| pszemraj/flan-t5-large-grammar-synthesis | T5 (770M) | 48% | 63% | 1.5 s | ~3 GB fp32 |
| GECToR RoBERTa-base (gotutiyan) | token tagging | 38% | 84% | 0.1 s | ~0.5 GB |

Findings:
- The T5 and GECToR models are fast but miss the confused-word errors this app cares about most
  ("Your going" is fixed by none of them correctly). They also rewrite correct text: dropping emoji,
  changing "@maria", "deploy" → "deployment", "5pm" → "5 pm". Not good enough for the default.
- Asking for plain corrected text (instead of JSON with an edit list) improved every LLM
  (Qwen3 4B: 81% → 90%; Qwen3 1.7B: 77% → 84%). Aure computes the edits itself with a word diff.
- Qwen3 4B is the most accurate; Qwen3 1.7B is the best choice when speed or memory matters.
- Still missed by every model: "Who's laptop" → "Whose laptop", "borrow me" → "lend me", and
  "Me and my team" (all fix the verb but keep "Me and my team").

## Defaults

- Recommended on every Mac with 16 GB or more: **Qwen3 4B**.
- 8 GB Macs: Qwen3 1.7B.
- Qwen3 0.6B stays in the catalog only as a "fastest, basic" option.
