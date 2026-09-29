# Model evaluation

How to reproduce:

```
dev llama                                   # build llama-server once
eval/run-models.sh ~/Library/Application\ Support/Aure/Models/*.gguf
# A model served by Ollama instead of llama-server:
swift run --package-path Packages/AureKit aure-eval --ollama qwen3:4b --set eval/golden
# Other architectures (Python venv under eval/.venv):
eval/.venv/bin/python eval/compare_seq2seq.py "grammarly/coedit-large:Fix grammatical errors in this sentence: " ...
eval/.venv/bin/python eval/compare_gector.py gotutiyan/gector-roberta-base-5k verb-form-vocab.txt
```

Test set: `eval/golden/*.jsonl`, 50 cases (31 with errors, 19 correct sentences that must stay unchanged).
It covers Slack-style and email-style text, confused words (your/you're, its/it's, their/there/they're,
whose/who's), agreement, pronoun case, word choice and Canadian spelling. This is still small; the goal
is 150+ (issue #11).

Language sets: `eval/languages/en_GB.jsonl` (British spelling that must stay unchanged) and
`eval/languages/pt_BR.jsonl` (Brazilian Portuguese). They are kept apart from the golden set so the
results below stay comparable; run them with `--set eval/languages`. No model results are recorded yet.

### Language detection (2026-09-29, stand-in run, not on a Mac)

`eval/languages/detection.jsonl`: 70 invented texts (Brazilian Portuguese with and without accents,
slang and English loanwords; US, UK and Canadian English; neutral English that must keep the preferred
variant; text too short to judge). On a Mac, `DialectDetectorTests.detectionCorpus` runs the real
detector over it.

Without a Mac, `eval/detect_proxy.mjs` runs the same decision logic with open-source stand-ins: franc
for Apple's language recognizer and Hunspell dictionaries for the system spell checker.

| group | top language guess | with 0.6 cut on franc scores |
|---|---|---|
| pt_BR | 25/25 | 22/25 |
| en_US | 11/11 | 8/11 |
| en_GB | 12/12 | 8/12 |
| en_CA | 5/5 | 3/5 |
| neutral English keeps preferred variant | 9/9 | 9/9 |
| short text keeps fallback | 8/8 | 8/8 |
| **total** | **70/70** | 55/70 |

About 0.2 ms per text. Every miss in the second column came from the language step falling back, not
from the spelling vote: franc's scores are distances, not probabilities, so the 0.6 cut is
much stricter for franc than for Apple's recognizer. Its results only show how much depends on that
threshold; check it with the Mac test. In Hunspell, the UK dictionary rejects -ize ("organize"), which
separates UK from Canadian text. If Apple's UK dictionary accepts -ize, UK and Canadian text that differ
only there tie, and the preferred variant wins.

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

## Published prompts and confidence filtering (2026-09-26, Qwen3 4B)

Compared Aure's prompt with two published prompts (`aure-eval --prompt ...`):
- `grammarlyAPIO`: the instruction Grammarly researchers optimized for GPT-4o
  (Chernodub et al., RANLP 2025, arXiv:2508.09378): "match the original phrasing … minimizing the
  number of differing words … If the text is already correct, leave it unchanged."
- `minimalTaxonomy`: the minimal-edit prompt with the 25 ERRANT error types, optimized for Qwen3-8B
  (Karpo & Chernodub, arXiv:2609.10810; MIT, github.com/katerynkarpo/llm-en-gec).

Confidence: with `logprobs`, llama-server reports the probability of each generated token and its
top alternatives. For every edit, Aure takes 1 − P(model keeps the original text at that point).
It costs no extra model call.

Sets: golden (50 cases, everyday writing) and BEA-2019 dev sample (150 learner-essay sentences,
100 with errors; build with `eval/make_bea_set.py`, not committed because of the Cambridge licence).
BEA is scored per edit with `eval/edit_f05.py` (precision, recall, F0.5, like the GEC papers).

| Prompt | Golden fixed / clean kept | BEA precision | BEA recall | BEA F0.5 | BEA clean kept |
|---|---|---|---|---|---|
| aure | 90% / 95% | 0.53 | 0.26 | 0.44 | 88% |
| grammarlyAPIO | 90% / 95% | 0.48 | 0.38 | 0.46 | 78% |
| minimalTaxonomy | 90% / 95% | 0.52 | 0.25 | 0.42 | 86% |

Effect of the confidence threshold (aure prompt, BEA):

| Min confidence | Precision | Recall | F0.5 |
|---|---|---|---|
| 0 | 0.53 | 0.26 | 0.44 |
| 0.7 | 0.54 | 0.25 | 0.44 |
| 0.9 | 0.55 | 0.24 | 0.43 |

Findings:
- Neither published prompt beats Aure's on everyday text; all three miss the same 3 golden cases.
- The Grammarly prompt finds more real errors on essays (+50% recall) but also changes 22% of
  correct sentences (vs 12%). For typing in Slack/Gmail, false alarms hurt more, so `aure` stays
  the default. The other two remain selectable for evaluation only.
- Qwen3 4B is usually very sure (most edits score 1.00). Low scores do mark the doubtful edits
  ("20th" → "21st" 0.67, "licences" → "licenses" 0.88, "favourite" → "favourites" 0.68), so the
  threshold trims false alarms a little, at a similar cost in real fixes. It is a user preference,
  not a quality win: Settings → Suggestions (Show everything 0 / Balanced 0.7 / Only when sure 0.9).
- Conclusion: prompt wording is not the bottleneck. Bigger gains need a better or fine-tuned model.

## Long texts: whole emails (2026-09-26, Qwen3 4B, 4096-token context like the app)

Set: `eval/long/emails.jsonl` (built by `eval/make_long_set.py`): 10 emails and Slack messages,
394–1,496 characters, with greetings, sign-offs, bullet and numbered lists, @mentions, #channels,
emoji, a URL, an email address and amounts. 8 contain 28 planted errors, 2 are already correct.
Scored with `eval/score_long.py` (planted errors fixed, extra changes, layout kept).

| How the email is sent to the model | Errors fixed | Extra changes | Correct emails untouched | Layout kept |
|---|---|---|---|---|
| Whole email in one call | 57% (16/28) | 0 | 2/2 | 10/10 |
| Split into paragraphs / list items (`TextSegmenter`) | **93% (26/28)** | 0 | 2/2 | 10/10 |

Findings:
- Given a whole email, the model often copies long stretches back unchanged. On the 724-character
  project update it returned the email exactly as written and fixed 0 of 6 errors. It also missed
  errors in the middle of other long texts.
- Splitting fixes that. Each line (paragraph, list item) is checked on its own; lines longer than
  400 characters are split between sentences; lines under 3 words (greeting, sign-off, name) are
  skipped. Issues are mapped back to positions in the full text. Single sentences are unaffected
  (golden set still 90% / 95%).
- Still missed: "There is still a few things" and "has now been corrected and are scheduled", both
  agreement errors where the verb is far from its subject.
- Speed on this test Mac (Intel i7, CPU only): 15–47 s per email, about 1–3 s per paragraph.
  Apple Silicon with the GPU is expected to be several times faster (not measured here). Each
  paragraph is cached, so after an edit only the changed paragraph is checked again.

### Checking paragraphs in parallel (2026-09-26, Intel i7-8850H, CPU only)

`CorrectionService.maxParallel` sends up to N paragraphs at once; llama-server runs with N slots of
4,096 tokens each (`-np N -c 4096*N`). Same 10 emails (`aure-eval --parallel N`):

| Slots | Total for 10 emails | Largest email (1,496 chars) | Server memory |
|---|---|---|---|
| 1 | 230 s | 47.5 s | 4.7 GB |
| 2 | 231 s | 37.8 s | not measured |
| 4 | 182 s (−21%) | 31.4 s | 6.4 GB |

On an Intel CPU, one request already uses every core, so parallel slots help little and cost memory.
Default: 1 slot on Intel; on Apple Silicon 4 slots with 16 GB or more, else 2
(`Hardware.recommendedParallelSlots`). The GPU batches parallel requests much better; not yet
measured on Apple Silicon. Accuracy is the same with any number of slots (86–93% across runs; the
model's temperature of 0.2 makes single runs vary by an error or two).

Whole-text limit: `CheckScope.maxLength` went from 2,000 to 10,000 characters, so a long email is
always checked in full. Only longer texts (documents) fall back to the paragraph around the cursor.

## Better-writing alternatives (rewrite mode) (2026-09-27, Qwen3 4B, Intel i7 CPU)

After the grammar check, Aure asks the model for one optional rewrite in the current tone
(`CheckMode.rewrite`, temperature 0.6), shown under "Better writing · Optional". The app only offers
it when `WritingSuggestion` accepts it, meaning the words actually changed.

How to reproduce:

```
build/llama/llama-server -m ~/Library/Application\ Support/Aure/Models/Qwen3-4B-Q4_K_M.gguf \
  --port 18095 -c 4096 -ngl 0 --jinja --no-webui -np 1 &
swift run --package-path Packages/AureKit aure-eval --server http://127.0.0.1:18095 --set eval/rewrite/rewrite.jsonl
```

Set: `eval/rewrite/rewrite.jsonl`, 30 cases across informal, formal and strict formal:
- 20 "improve": wordy, passive, hedging or wrong-register text that should get an alternative.
- 10 "good": text that is already clear and fits the tone, where no alternative should appear.
  These include emoji, @mentions, a URL and a strict-formal letter.
- Each case lists the facts that must survive (names, dates, amounts, @mentions, #channels).
  Adding a template placeholder such as "[Name]" counts as a failure.

| Prompt | Alternative offered (needs work) | Left alone (already good) | Facts kept | Median length | p50 / p95 |
|---|---|---|---|---|---|
| v1 (first version) | 100% (20/20) | 90% (9/10) | 100% (21/21)* | 87% of original | 6.2 s / 11.5 s |
| v2 (concise-and-direct prompt, "unchanged" examples) | 100% (20/20) | 100% (10/10) | 95% (19/20) | 71–80% | 5.2 s / 14.4 s |
| **v3 (v2 + example without a name)** | **100% (20/20)** | **100% (10/10)** | **100% (20/20)** | 78% | 4.2 s / 7.4 s |

\* v1 was scored before the placeholder check existed. Its one strict-formal output also added
"Dear [Name]".

v2 ran three times and gave the same scores each time. Its only failure also repeated every time:
for "Hey, just checking in on the proposal…" in strict formal, the model wrote "Dear [Name], …".
v3 fixed this by changing the prompt only. Two targeted runs and the final full run showed no
placeholders.

What changed (all in `PromptBuilder`, no rules in app code):
- The task asks for clearer, more direct text: cut filler, prefer the active voice, and use plain
  phrases instead of wordy ones. Every word must fit the tone. The model must never add facts,
  excuses, names or placeholders, must keep tense and commitments, and must not swap in synonyms
  just to change the text. It repeats the text exactly when it is already fine.
- Each tone got an "already good, repeat it" example and a "wordy" example. Strict formal also got
  an example with no name, so the model learns not to invent a salutation.
- The strict-formal tone description now asks for formal salutations "where the writer used them",
  instead of "complete salutations", which led to "Dear [Name]".

v1 weaknesses that v3 fixed:
- A light touch on wordy text. v1 kept "I just wanted to reach out and touch base", "It was decided
  by the team…" and "no one noticed that the disk was full" (repeated). v3 turns these into "The team
  decided…" and "…and no one noticed."
- It rewrote an already good strict-formal letter ("reply" → "respond"), which was pure synonym churn.
- In informal tone it once invented a fact ("I'll be stuck in the office today").

Grammar (correct mode) is unaffected: the golden set is still 90% (28/31) fixed and 95% (18/19)
clean kept.

Limits:
- 30 cases is small. The results show the feature works, not that it is good at scale. Grow the set
  with real Slack and email text.
- Rewrites are slower than grammar checks (median about 4–5 s on this Intel CPU). They run in the
  background after grammar results are already shown.
- Texts over 1,200 characters get no alternative (`AppState.suggestWriting`). Long emails would need
  rewrites paragraph by paragraph, which is not built yet.
- "Facts kept" checks exact strings. It cannot catch a changed meaning that keeps every name and
  number, so read the outputs printed by `aure-eval`.
