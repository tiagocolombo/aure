# Aure — Task Backlog (for agent execution after plan approval)

Companion to `docs/PLAN.md`. Tracked as GitHub Issues #1-#33, epic #34. Every task:
- Is scoped to be doable by one agent in one session (≈ 0.5–1 day).
- Lists its dependencies, files, and acceptance criteria (AC).
- Uses TDD for logic in `Packages/AureKit` (write the failing test, then implement).
- Ends with `swift test` (and `pnpm -C extension/chrome test` where relevant) passing,
  plus one conventional commit per task.

Legend: `Dep:` = must be merged first. `P` = can run in parallel with the other P tasks
in the same phase.

---

## Phase 0 — Foundations

**F1 (#1). Repository scaffold** — Dep: none
- Create the layout from section 7 of the plan: `.gitignore` (Xcode, build/, dist/, node_modules),
  `README.md`, `docs/` stubs (PLAN.md and BACKLOG.md already exist), and `project.yml` (XcodeGen) with targets `Aure` (app,
  LSUIElement=YES, macOS 14, bundle id `com.tiagocolombo.aure`, product name Aure), `aure-nm-host` (tool), and `AureTests`.
- Clean up `dev.toml`: remove postgres/nx/processes/up/doppler, and keep Nix. Toolchain:
  node 22, pnpm 10, gh, xcodegen, cmake, create-dmg. Commands: `test` (swift test +
  extension tests), `lint`, `build = scripts/build-app.sh`, `dmg = scripts/make-dmg.sh`.
  Note in the README that Xcode 16+ must be installed from Apple.
- AC: `dev test` runs; `xcodegen && xcodebuild -scheme Aure build` succeeds; launching it shows an empty
  menu bar item.

**F2 (#2). AureKit Swift package** — Dep: F1
- `Packages/AureKit/Package.swift` with library targets AureCore, AureInference,
  AureModels, AureProfile, AureAccessibility, AureBridge, AureUI; test targets; executable
  `aure-eval`. Add GRDB.
- AC: `swift test` runs (a placeholder test per module); the app target links AureKit.

**F3 (#3). Vendor + universal llama-server build** — Dep: F1 · P
- Add `vendor/llama.cpp` as a submodule pinned to a release tag.
- `scripts/build-llama.sh` does arm64 (Metal, embedded lib) and x86_64 (CPU) static
  builds, then `lipo`.
- AC: `lipo -archs build/llama/llama-server` → `x86_64 arm64`; `llama-server --version`
  runs natively and under `arch -x86_64`.

**F4 (#4). CI** — Dep: F2 · P
- `.github/workflows/ci.yml` on macos-latest: `swift test`, xcodegen build, extension
  lint/test, and llama build cache.
- AC: green on a PR.

## Phase 1 — Engine

**E1 (#5). Core types + DiffEngine** — Dep: F2 · P
- AureCore: `Tone`, `CheckMode`, `Dialect` (`enUS` default, `enCA`), `CheckRequest` (with dialect), `Issue`, `CheckResult`, `FieldSnapshot`;
  a word-level Myers diff producing UTF-16 ranges.
- AC: tests cover punctuation, whitespace, emoji, multi-line, and no-change.

**E2 (#6). PromptBuilder + ResponseParser + Validator** — Dep: E1
- Prompts live in `Resources/prompts/*.md` (system, tone definitions, few-shot per tone).
- The dialect note is part of the system prompt (en-CA: colour, centre, cheque, but American -ize endings).
- The parser tolerates code fences and trailing text.
- The validator enforces the rules in plan section 4.3 (edit ratio, URLs, @mentions,
  code, emoji, placeholders).
- AC: snapshot tests for all 3 tones × 2 modes × 2 dialects; validator unit tests.

**E3a (#7). LLMProvider + FakeLLMProvider** — Dep: E1 · P
- Protocol from plan 4.2, `GenParams`, cancellation, and a scripted fake for tests.
- AC: CorrectionService (E4) can be unit-tested with the fake.

**E3b (#8). LlamaServerProcess + LlamaServerProvider** — Dep: F3, E3a
- Launch on a random port with an API key, `/health` wait, crash restart with backoff,
  idle unload, `/v1/chat/completions` with `response_format` json_schema, and cancel via
  URLSession task cancel.
- AC: integration test (`AURE_IT=1`) with qwen3-0.6b returns valid JSON for 5 sample
  inputs; killing the process triggers an automatic restart.

**E4 (#9). CorrectionService** — Dep: E2, E3a
- Prompt → provider → parse → validate → diff → `CheckResult`; includes an LRU cache by
  hash, request coalescing, and an NSSpellChecker pre-pass for spelling issues (language `en_US` or `en_CA` by dialect).
- AC: unit tests with the fake; cancelled requests never deliver results.

**E5 (#10). Model catalog + ModelManager** — Dep: F2 · P
- `Resources/models.json` covers the 4 models in plan section 2. Fill in sha256 from the
  HF tree API `lfs.oid` (script `scripts/update-model-catalog.sh`).
- Resumable download, sha256 verify, disk and RAM gates, delete, import GGUF, and
  hardware detection with a recommendation.
- AC: unit tests with URLProtocol mock (resume, bad hash → delete + error); manual
  download of qwen3-0.6b succeeds.

**E6 (#11). Eval harness + model selection** — Dep: E3b, E4, E5
- `eval/golden/*.jsonl` with ≥150 cases (≥30% clean-text negatives, Slack-style and
  email-style, all 3 tones), plus ≥20 en-CA cases (for example, "colour" must not be flagged).
- `swift run aure-eval --model <id> --set all` prints precision/recall/FP rate,
  over-rewrite rate, and p50/p95.
- Tune temperature and prompts, then record the results in `docs/MODEL_EVAL.md` and set
  the default per hardware class.
- AC: the report is committed; the default model meets the targets or the gap is
  documented.

## Phase 2 — MVP shell (usable end-to-end without system integration)

**U1 (#12). App lifecycle + menu bar** — Dep: F2, E3b
- `MenuBarExtra` (window style) with the icon states from plan 3.1, tone switcher, pause,
  and quit. An `AppState` observable is the single source of truth. Launch at login uses
  SMAppService.
- AC: the icon changes state under a mocked coordinator; login item toggles.

**U2 (#13). Settings window** — Dep: U1, E5
- Tabs from plan 3.4 (Providers disabled). The Models tab has download progress and
  switching. Settings persist in UserDefaults + GRDB.
- AC: switching models restarts llama-server and the menu shows the new model.

**U3 (#14). Aure Pad** — Dep: U1, E4
- Editor, tone picker, Check/Rewrite, inline diff rendering, per-issue accept/dismiss,
  Copy corrected.
- AC: typing "their going to the store tomorow" (Formal) gives the corrected sentence and
  2 issues; Replace all updates the editor.

**U4 (#15). Onboarding flow** — Dep: U2, U3
- Steps from plan 3.5, including a model download and a live demo field. The
  Accessibility step waits for the trust flag; the extension step is optional (links to
  C4).
- AC: a fresh user account can go from launch to a working Pad check without opening
  Terminal.

## Phase 3 — System-wide (AX)

**A1 (#16). AX permission + focus tracking** — Dep: U1
- `AccessibilityPermission` helper; `FocusTracker` (app activation → AXObserver → focused
  element) with a 0.25 s messaging timeout; eligibility rules and blocklist.
- AC: a debug menu item logs role, bundleId, and text length when you focus fields in
  TextEdit, Notes, and Slack.

**A2 (#17). AXTextSource read/replace** — Dep: A1
- Read value + selection + frame; replace via `AXSelectedTextRange` + `AXSelectedText`,
  verify, else paste fallback with clipboard save/restore.
- AC: replacement works in TextEdit and Notes, and undo (⌘Z) reverts it.

**A3 (#18). SlackAdapter** — Dep: A2 · P
- Set `AXManualAccessibility` on launch/activation; limit to the message composer;
  handle thread and edit composers.
- AC: the bubble appears in a DM, a channel, and a thread; Replace all works; the search
  box is ignored.

**A4 (#19). CheckCoordinator** — Dep: A2, E4
- Debounce 700 ms, paragraph extraction around the caret, cancel on new input, per-app
  tone resolution, pause state, and the heartbeat check for the Chrome extension.
- AC: unit tests with a fake TextSource and fake provider; at most 1 in-flight request
  per field.

**A5 (#20). Bubble panel + suggestion card** — Dep: A4
- Non-activating NSPanel; positioning from AX frames with follow on move/resize; states
  green/red/spinner; the card with diff, issue list, Replace all (⏎), dismiss, "Rewrite
  in tone", Copy, "Never flag". Accept/dismiss emits a FeedbackEvent (stored only if
  learning is on).
- AC: works in Slack, TextEdit, and Notes; the target app never loses focus; Esc closes
  the card.

**A6 (#21). Check-selection hotkey** — Dep: A5 · P
- Global hotkey (⌥⌘G, configurable) reads the selection via AX, falling back to ⌘C with
  clipboard restore; shows the card; writes back when possible, else Copy.
- AC: works in any app with selectable text, including ones AX can't write to (the Copy
  path).

## Phase 4 — Chrome / Gmail

**C1 (#22). Bridge server + protocol** — Dep: E4
- AureBridge: Unix socket server (0600) with NDJSON messages from plan 5.3, version
  handshake, and rate limit.
- AC: tests for framing, malformed input, and concurrent clients.

**C2 (#23). aure-nm-host** — Dep: C1
- Native messaging stdio framing (4-byte native-endian length, 1 MB cap) ↔ socket relay;
  launches the app if it's missing.
- AC: a test harness pipes framed messages and receives results; logs go to stderr only.

**C3 (#24). Chrome extension** — Dep: C2 · P (UI part can start earlier)
- `extension/chrome` with TS + esbuild, MV3, fixed `key`. Content script: field
  detection, Shadow DOM bubble and card (same states and actions as A5), Gmail compose
  handling (skip quote and signature), `execCommand('insertText')` replacement. Service
  worker: `connectNative` and heartbeat.
- AC: vitest passes with Gmail DOM fixtures; manual check in real Gmail (new, reply) shows
  bubble → Replace all, and ⌘Z undoes it.

**C4 (#25). Extension installer in Settings** — Dep: C3, U2
- Writes the NM host manifest, copies the extension folder, opens chrome://extensions,
  and shows step-by-step instructions plus live status ("Connected ✓").
- AC: from a clean Chrome profile, install takes < 1 minute; Settings shows Connected;
  the AX path stops drawing bubbles in Chrome.

## Phase 5 — Voice & learning

**V1 (#26). Tone presets + per-app tones** — Dep: E2, U2 · P
- Editable tone descriptions and toggles; per-app/per-host default tone table.
- AC: a Slack field defaults to Informal and Gmail to Formal; override from the menu bar.

**V2 (#27). VoiceProfile store** — Dep: F2 · P
- GRDB schema + migrations for VoiceProfile, WritingSample, FeedbackEvent, LearnedRule,
  and DictionaryWord; retention job; delete-all.
- AC: migration tests; delete-all leaves empty tables.

**V3 (#28). Voice assistant** — Dep: V2, E3b, U2
- Guided chat UI (6–8 steps) → the model proposes profile JSON (schema-constrained) →
  diff review → save. Can be re-run.
- AC: completing the assistant with sample answers produces a valid profile shown in the
  editor.

**V4 (#29). LearningService** — Dep: V2, A5
- Deterministic rules (3 dismissals → never-suggest; dictionary adds), "Refine my
  profile" with model-generated diff and approval, and injection of the top rules into
  PromptBuilder.
- AC: after dismissing the same suggestion 3 times, it no longer appears; unit tests for
  rule weighting.

## Phase 6 — Ship v1

**S1 (#30). Signing + helpers embedding** — Dep: F3, C2
- `scripts/build-app.sh` embeds the helpers, applies hardened runtime entitlements, and
  signs inside-out with the stable self-signed "Aure Local" certificate (a
  `scripts/bootstrap.sh` step creates it in the keychain). Developer ID is optional via an
  env var.
- AC: `codesign --verify --deep --strict` passes; the Accessibility grant survives a
  rebuild and reinstall.

**S2 (#31). DMG** — Dep: S1
- `scripts/make-dmg.sh` produces `dist/Aure-<ver>.dmg` with the Applications symlink,
  background, and layout. `notarize.sh` is skipped unless Developer ID credentials exist (none yet).
  `.github/workflows/release.yml` runs on tag.
- AC: installing on a second Mac (or a fresh user) by drag-to-Applications works.

**S3 (#32). Docs** — Dep: S2 · P
- `docs/INSTALL.md` (DMG, right-click, Open for the un-notarized first launch, permissions, Chrome extension), `PRIVACY.md`, `ARCHITECTURE.md`,
  `TESTING.md` (QA matrix).

**S4 (#33). QA + performance pass** — Dep: all
- Run the plan section 9 matrix on Apple Silicon and Intel/Rosetta; fix issues; check the
  performance budgets; tag `v0.1.0`.

---

## Dependency summary (critical path)
F1 → F2 → E1 → E2 → E4 → A4 → A5 → (A3, C1→C2→C3→C4, V4) → S1 → S2 → S4
Parallel early tracks: F3 → E3b; E5; V2; U1 → U2 → U3.

Estimated total: ~30 tasks, about 5–7 weeks for one developer, or much less with 3–4
agents running in parallel along the tracks above.
