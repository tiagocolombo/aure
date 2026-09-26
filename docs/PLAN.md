# Aure — Offline Grammar & Voice Assistant for macOS — Implementation Plan

> For Hermes: after approval, turn the backlog (docs/BACKLOG.md) into
> tasks and implement them with subagent-driven development, one task per agent, with a
> review after each task.
> Status: APPROVED 2026-09-26. Backlog: docs/BACKLOG.md; tasks tracked as GitHub Issues
> in tiagocolombo/aure.

Goal: A personal-use macOS menu bar app that checks your English grammar and tone in any
text field (Slack and Chrome/Gmail work best). It shows a red or green bubble and replaces
your text with the suggested version in one click. Everything runs offline on a small local
model that you can download from inside the app.

Architecture: A native Swift/SwiftUI menu bar app (LSUIElement, no Dock icon). It watches
the focused text field through the macOS Accessibility (AX) API and shows a floating
bubble. It sends text to a bundled `llama-server` process (llama.cpp) on 127.0.0.1, which
runs a downloaded GGUF model. In Chrome, an optional MV3 extension handles the text field
instead. It talks to the app through Chrome native messaging, which gives reliable reads
and writes in Gmail's editor. A voice profile (tone + learned preferences) is stored
locally in SQLite and included in every prompt.

Tech stack: Swift 6 / SwiftUI + AppKit (Observation framework), macOS 14 Sonoma+,
universal binary (arm64 + x86_64);
llama.cpp `llama-server` (Metal on Apple Silicon, CPU/AVX2 on Intel); GRDB (SQLite);
XcodeGen; TypeScript + esbuild for the Chrome extension (pnpm, already in dev.toml);
hdiutil/create-dmg for packaging.

---

## 1. Decisions captured so far

| Topic | Decision |
|---|---|
| Audience | Personal use only (not App Store, no accounts, no telemetry) |
| Hardware | Apple Silicon and Intel Macs |
| Scope | Focused v1: system-wide corrections, 3 tones, local models, voice learning. Wider Grammarly parity in later phases |
| Must work well at launch | Slack desktop, Chrome (Gmail especially), plus a simple "Aure Pad" window for any unsupported app |
| Integration | Native Accessibility permission, plus an optional Chrome extension |
| Learning | Opt-in. Learns only from accepted/dismissed suggestions and writing samples you provide. No raw writing history by default |
| UI home | Menu bar icon at the top of the screen for settings and all interaction |
| Models | Small local models, several download options with sizes shown. OpenAI provider later |
| Install | Drag-to-Applications DMG |
| Product name / bundle id | Aure / `com.tiagocolombo.aure` (helpers: `com.tiagocolombo.aure.nmhost`) |
| Minimum macOS | 14 Sonoma |
| Dialect | US English by default; Canadian English as an option |
| Signing | No Apple Developer account yet: stable self-signed "Aure Local" certificate, not notarized (first launch: right-click, Open). Developer ID path kept ready for later |
| Tasks | GitHub Issues in `tiagocolombo/aure` |
| Dev environment | Keep Nix (`flake.nix` + `dev.toml`) for tooling; `dev test`, `dev build`, `dev dmg` wrap the scripts. Postgres/Nx template parts removed |

## 2. Model catalog (v1)

Sizes were checked against the Hugging Face tree API on 2026-09-26 (Q4_K_M quant):

| Id | Model | File | Size | Best for |
|---|---|---|---|---|
| `qwen3-0.6b` | Qwen3 0.6B Instruct | bartowski/Qwen_Qwen3-0.6B-GGUF · Qwen_Qwen3-0.6B-Q4_K_M.gguf | 484 MB | Fastest; basic fixes; default on Intel / 8 GB Macs |
| `smollm2-1.7b` | SmolLM2 1.7B Instruct | HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF · smollm2-1.7b-instruct-q4_k_m.gguf | 1.06 GB | English-focused alternative |
| `qwen3-1.7b` (recommended) | Qwen3 1.7B Instruct | bartowski/Qwen_Qwen3-1.7B-GGUF · Qwen_Qwen3-1.7B-Q4_K_M.gguf | 1.28 GB | Best quality/speed balance on Apple Silicon |
| `qwen3-4b` (optional) | Qwen3 4B | Qwen/Qwen3-4B-GGUF · Qwen3-4B-Q4_K_M.gguf | ~2.5 GB | Highest quality; Apple Silicon 16 GB+ |

- Plus "Import GGUF…" for any local file.
- The catalog lives in `Resources/models.json` with repo, file, byte size, sha256 (from the
  HF tree API `lfs.oid`), license, a RAM hint, and prompt template notes.
- Qwen3 must run in non-thinking mode (`/no_think`, or `enable_thinking=false` in the chat
  template).
- The default model is chosen by the evaluation harness (task E3), not guessed. The table
  above is the starting hypothesis.

## 3. User experience

### 3.1 Menu bar (NSStatusItem via SwiftUI `MenuBarExtra`, window style; macOS 14)
- Icon state: idle (outline), checking (pulse), all good (green dot), issues (red dot
  + count), paused (slashed), model not loaded (gray).
- Popover contents:
  - Current app and field status.
  - Tone switcher: Informal / Formal / Strict formal.
  - "Pause in <App>" and "Pause for 1 hour".
  - Open Aure Pad.
  - Check selection (⌥⌘G).
  - Model status and switcher.
  - Settings…
  - Quit.

### 3.2 Bubble in any text field
- A small circle (18 pt) anchored to the bottom-right of the focused text field. It uses
  `AXFrame` of the field, falling back to `AXBoundsForRange` of the caret.
- States: green (no issues), red with a count (issues), spinner (checking), hidden
  (field too short, password field, or paused).
- Clicking the bubble opens the suggestion card (non-activating NSPanel, so the target app
  keeps focus). The card shows:
  - The original text with inline diff (strikethrough red / insert green).
  - The corrected full sentence or paragraph.
  - A per-issue list with category (Spelling, Grammar, Punctuation, Word choice, Tone)
    and a one-line explanation.
  - Buttons: **Replace all** (primary, ⏎), Accept single issue, Dismiss issue, "Rewrite
    in <tone>", Copy, "Never flag this" (adds a rule or dictionary word).
- Checks run 700 ms after typing stops. Only changed paragraphs are sent; results are
  cached by hash, in-flight requests are cancelled, and input is capped at ~2,000 chars
  (the paragraph around the caret).

### 3.3 Aure Pad (fallback window)
- A simple window: text editor, tone picker, "Check" / "Rewrite" buttons, suggestion
  list, and "Copy corrected" (⌘⇧C).
- Also opens with the global hotkey "Check selection". That hotkey reads the selected
  text through AX, falling back to ⌘C with clipboard restore. It shows the card and, if
  possible, writes the result back to the source app.

### 3.4 Settings window (tabs)
1. **General**: launch at login (SMAppService), hotkeys, debounce, bubble position,
   per-app enable/disable list with default tone per app (Slack → Informal,
   mail.google.com → Formal).
2. **Models**: catalog with size, RAM hint, speed score, and a Download/Delete/Use button
   with a progress bar; import GGUF; advanced settings (context, temperature, threads,
   GPU layers). Shows detected hardware (chip, RAM) and a recommendation.
3. **Voice & Tone**: 3 tone presets (editable descriptions), voice profile editor, "Run
   voice assistant", writing samples list, English dialect (US default, or Canadian English).
4. **Learning**: opt-in toggle, learned rules list (view/edit/delete), personal
   dictionary, "Refine my profile now", "Delete all learning data".
5. **Integrations**: Accessibility permission status and a Grant button; per-app health
   check; Chrome extension install/status.
6. **Providers** (disabled in v1): OpenAI placeholder.
7. **About / Privacy**: states that nothing leaves the Mac except model downloads, and
   offers an "Offline mode" that blocks even those.

### 3.5 First-run onboarding
Welcome → hardware check → pick and download a model → grant Accessibility (deep link to
`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`, wait until
`AXIsProcessTrusted()` is true) → optional Chrome extension → voice assistant (can skip) →
a demo field to try it.

## 4. Architecture

```
┌──────────────────────── Aure.app (menu bar, LSUIElement) ────────────────────────┐
│ UI: MenuBarExtra · SettingsWindow · AurePad · Onboarding · BubblePanel · Card     │
│                                   │                                               │
│ CheckCoordinator (debounce, cache, cancel, per-app policy, tone resolution)       │
│      │                    │                          │                             │
│ TextSources:            Engine:                   Profile:                        │
│  AXTextSource ◄─AXObserver  CorrectionService        VoiceProfileStore (GRDB)     │
│  ExtensionTextSource        PromptBuilder            LearningService              │
│  PadTextSource              ResponseParser+Validator ToneAssistant                │
│      │                      DiffEngine (word-level)                                │
│ BridgeServer (unix socket)  LLMProvider protocol ──► LlamaServerProvider (HTTP)   │
│      ▲                        (OpenAIProvider later)       │                       │
│      │                      ModelManager (catalog, download, sha256, RAM check)   │
└──────┼────────────────────────────────────────────┼──────────────────────────────┘
       │ stdio JSON (native messaging)               │ spawns / supervises
 aure-nm-host (Swift CLI, in bundle)          llama-server (universal, in bundle)
       ▲                                       127.0.0.1:<random port>, --api-key token
 Chrome MV3 extension (content script + SW)
```

### 4.1 Why these choices
- **Native Swift instead of Electron/Tauri**: AX APIs, non-activating panels, and menu
  bar behavior are first-class in AppKit, and the app stays light.
- **`llama-server` subprocess instead of linking llama.cpp in-process**: a model crash
  can't take down the app, it's easy to swap versions, and it speaks the OpenAI chat API.
  That means the future `OpenAIProvider` is almost the same client, and JSON-schema
  constrained output is built in (`response_format` / `json_schema`).
- **Spelling via `NSSpellChecker` first, then the LLM for grammar and tone**: fast
  underlines and fewer model calls. The Harper rule engine is a Phase 2 option.
- **Chrome extension for Chrome**: Gmail's compose box is a `contenteditable`. Writing to
  it through AX is unreliable; `document.execCommand('insertText')` inside the page keeps
  Gmail's state and undo working. When the extension is connected (heartbeat), the AX
  path skips Chrome so you don't get two bubbles.
- **Slack**: Electron apps expose the AX tree only after `AXManualAccessibility = true`
  is set on the app element (plus `AXEnhancedUserInterface` for Chromium). Replacement:
  set `AXSelectedTextRange` then `AXSelectedText`. If the value doesn't change, fall back
  to "select range + paste via pasteboard (⌘V synthesized with CGEvent) + restore
  clipboard".

### 4.2 Core contracts (Swift)

```swift
enum Tone: String, Codable, CaseIterable { case informal, formal, strictFormal }
enum CheckMode: String, Codable { case correct /* minimal edits */, rewrite /* tone rewrite */ }

struct CheckRequest: Codable, Hashable {
    let text: String; let tone: Tone; let mode: CheckMode
    let appBundleId: String?; let host: String?   // e.g. "mail.google.com"
}
struct Issue: Codable, Hashable, Identifiable {
    let id: UUID; let range: Range<Int>            // UTF-16 offsets into original, computed locally
    let original: String; let replacement: String
    let category: Category; let explanation: String
    enum Category: String, Codable { case spelling, grammar, punctuation, wordChoice, tone, clarity }
}
struct CheckResult: Codable { let request: CheckRequest; let corrected: String; let issues: [Issue]; let latencyMs: Int }

protocol LLMProvider: Sendable {
    var id: String { get }
    func complete(system: String, user: String, schema: JSONSchema?, params: GenParams) async throws -> String
    func cancelAll()
}
protocol TextSource: AnyObject {
    var id: String { get }
    func currentText() async -> FieldSnapshot?          // text, selection, frame, pid, bundleId, isSecure
    func replace(range: Range<Int>, with: String, in: FieldSnapshot) async throws
}
```

### 4.3 Model output contract (JSON schema enforced by llama-server)

```json
{ "corrected": "string", "edits": [ { "from": "string", "to": "string",
  "category": "spelling|grammar|punctuation|wordChoice|tone|clarity", "why": "string (<= 12 words)" } ] }
```

The app never trusts model offsets. It runs a word-level diff (Myers) between the original
and `corrected` to build the `Issue` ranges, and matches `edits[].why` to diff hunks by
text. Validator rules:
- In `correct` mode, reject the result if the normalized edit distance ratio is over 0.35
  (the model is rewriting, not correcting).
- Reject if the language changed or placeholders, URLs, @mentions, `code`, or emoji were
  altered.
- If `corrected == original`, show green.

### 4.4 Prompt (PromptBuilder)
- System prompt: role ("You are a precise English copy editor"), dialect, tone
  definition, voice profile summary (≤ 150 tokens), learned rules (top 20 by weight,
  "never change X", "prefer Y over Z"), personal dictionary, hard rules (keep meaning,
  keep formatting, line breaks, names, and code; minimal edits in correct mode), output
  schema, and `/no_think` for Qwen3.
- Few-shot: 3 short examples per tone (bundled), plus up to 2 of your own samples in
  rewrite mode.
- Parameters: temp 0.2 for correct, 0.6 for rewrite; top_p 0.9; max_tokens =
  1.5 × input tokens + 128. Tune in the eval harness.

### 4.5 Tones
- **Informal**: contractions OK, friendly, short sentences, emoji preserved, Slack-style.
  Fix only real errors.
- **Formal**: professional email register, no slang, complete sentences, polite hedging
  allowed, contractions allowed sparingly.
- **Strict formal**: no contractions, no colloquialisms or emoji, full salutations and
  sign-offs kept, passive voice allowed, precise vocabulary (legal/executive tone).

Each is an editable text description plus a structured toggle set (contractions,
exclamation marks, emoji, sentence length target).

### 4.6 Voice profile & learning
- `VoiceProfile` (JSON in SQLite): dialect, tone defaults, formality 1–5, preferred
  sign-offs/greetings, vocabulary to prefer/avoid, oxford comma, contraction preference,
  sentence length, emoji usage, notes (free text), and derived style summary.
- **Voice assistant** (Settings → Voice & Tone, and in onboarding): a 6–8 step guided
  chat that runs on the local model. It asks about audience, role, how formal you are
  with colleagues vs. clients, and pet peeves, then asks you to paste 2–3 samples (email,
  Slack message). The model returns a proposed `VoiceProfile` JSON. You review it as a
  diff and save.
- **Learning (opt-in)**: each accept/dismiss/partial edit is stored as a `FeedbackEvent`.
  It holds category, the short `from`/`to` spans (≤ 60 chars each, not the full text),
  tone, app, and timestamp. A `LearningService` does two things:
  1. Deterministic rules: 3 dismissals of the same `from→to` pattern create a
     "never suggest" rule, and repeated identical flags of a proper noun add it to the
     dictionary.
  2. Periodic refinement (manual button or weekly): the model summarizes events into a
     proposed profile diff, which you approve.
- Retention: events are kept for 90 days (configurable). Everything can be viewed and
  deleted, and nothing is sent anywhere.

## 5. Integration details

### 5.1 AX pipeline (AureAccessibility)
- `AXIsProcessTrustedWithOptions` prompt; poll every 2 s until trusted.
- `NSWorkspace.didActivateApplicationNotification` sets up an `AXObserver` on the frontmost
  app for `kAXFocusedUIElementChangedNotification`, `kAXValueChangedNotification`,
  `kAXSelectedTextChangedNotification`, and window move/resize (to reposition the bubble).
- Field eligibility:
  - Role is `AXTextArea`, `AXTextField`, or `AXComboBox`, or it's a web area with an
    editable ancestor.
  - Not `AXSecureTextField`.
  - `AXValue` is settable, or the paste fallback is allowed.
  - Text is ≥ 12 characters and ≥ 3 words.
- Per-app adapters (`AppAdapter` protocol): `SlackAdapter` (enable manual accessibility;
  only the message composer; ignore the search box), `ChromeAdapter` (defer to the
  extension when it's connected), `GenericAdapter`. Adapter tuning for Mail, Notes,
  TextEdit, and Messages comes in Phase 2.
- Blocklist by default: 1Password, Terminal/iTerm/Ghostty, Xcode/VS Code editors,
  password fields.
- Set `AXUIElementSetMessagingTimeout` to 0.25 s so the app never hangs on unresponsive
  apps.

### 5.2 Chrome extension (`extension/chrome`)
- MV3; the content script runs on all URLs (`all_frames: true`). It detects focused
  `textarea`, `input[type=text|search|email]`, and `[contenteditable]`, and draws the
  bubble and card in a closed Shadow DOM so page CSS can't touch them.
- Gmail specifics: target `div[contenteditable][role=textbox]` in compose. Skip quoted
  replies (`.gmail_quote`) and the signature. Replace text with a Range selection +
  `execCommand('insertText')`, falling back to InputEvent `beforeinput`/`input`.
- The service worker runs `chrome.runtime.connectNative('com.tiagocolombo.aure')`, forwards
  check requests, and sends a heartbeat every 5 s.
- `manifest.json` has a fixed `key` so the extension ID is stable for the
  native-messaging `allowed_origins`.
- Install for personal use: Settings → Integrations → "Install Chrome extension". This
  writes `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.tiagocolombo.aure.json`
  (path → `Aure.app/Contents/Helpers/aure-nm-host`), copies the unpacked extension to
  `~/Library/Application Support/Aure/chrome-extension`, opens `chrome://extensions`, and
  shows 3-step instructions (Developer mode → Load unpacked → select folder).
- `aure-nm-host`: reads 4-byte length-prefixed JSON on stdin (native byte order,
  ≤ 1 MB replies) and relays over the Unix socket
  `~/Library/Application Support/Aure/bridge.sock` (0600) to the app. If the app isn't
  running, it launches it via `open -b com.tiagocolombo.aure` and retries.

### 5.3 Bridge protocol (NDJSON over unix socket)
`{"v":1,"id":"…","type":"check","payload":CheckRequest}` returns
`{"id":"…","type":"result","payload":CheckResult}`. Other message types: `hello`
(version handshake), `ping/pong`, `feedback` (accept/dismiss events from the extension),
`settings` (tone for host, paused state), `error`.

## 6. Model runtime (AureInference)
- `LlamaServerProcess`: picks a free port, generates a random API key, and launches
  `llama-server -m <gguf> --host 127.0.0.1 --port P --api-key K -c 4096 --jinja -ngl 99`
  on arm64. On x86_64 it uses `-ngl 0` and `-t <physical cores>`.
- It waits for `/health`, restarts with backoff after a crash (max 3/min), stops when you
  switch models or quit, and unloads after 30 min idle (configurable) to free RAM.
- `ModelManager`:
  - Download: URLSession background download with resume data, to
    `~/Library/Application Support/Aure/Models/`.
  - Verify: sha256 check.
  - Disk: free-space check before download.
  - RAM: refuse or warn if the model needs more than 60% of physical RAM.
  - Warmup: run one warmup prompt after load.
- Hardware detection: `sysctl hw.optional.arm64`, `hw.memsize`, `machdep.cpu.brand_string`,
  and an AVX2 check (Intel).

## 7. Repository layout

```
aure/
├── project.yml                     # XcodeGen: Aure.app, aure-nm-host, tests
├── Packages/AureKit/               # SwiftPM, all logic testable with `swift test`
│   ├── Package.swift
│   └── Sources/{AureCore,AureInference,AureModels,AureProfile,AureAccessibility,AureBridge,AureUI}
│       Tests/{AureCoreTests,AureInferenceTests,AureModelsTests,AureProfileTests,AureBridgeTests}
├── App/                            # thin app target: AureApp.swift, Info.plist, entitlements, Assets
├── NativeHost/main.swift           # aure-nm-host
├── Resources/{models.json,prompts/,fewshot/}
├── extension/chrome/               # TS + esbuild, pnpm; src/{content,sw,ui}/, tests (vitest + jsdom)
├── eval/                           # golden sets (jsonl) + aure-eval CLI (Swift executable in AureKit)
├── scripts/{bootstrap.sh,build-llama.sh,build-app.sh,make-dmg.sh,notarize.sh}
├── vendor/llama.cpp                # git submodule pinned to a tagged release
├── docs/{ARCHITECTURE.md,PRIVACY.md,INSTALL.md,TESTING.md}
├── .github/workflows/{ci.yml,release.yml}
├── dev.toml / flake.nix            # kept: Nix toolchain; drop postgres/nx; `dev test|build|dmg|lint` → scripts
└── .hermes/plans/
```

## 8. Build, signing & DMG
- `scripts/build-llama.sh`: builds `llama-server` twice with CMake (arm64 with
  `GGML_METAL=ON` and embedded Metal lib; x86_64 with Metal off), then `lipo`s them into
  a universal binary at `build/llama/llama-server`. Static link (`BUILD_SHARED_LIBS=OFF`)
  keeps the bundle self-contained.
- `scripts/build-app.sh`: `xcodegen` → `xcodebuild -scheme Aure -configuration Release
  ARCHS="arm64 x86_64" archive` → copies llama-server and aure-nm-host into
  `Contents/Helpers/`.
- Signing: hardened runtime; entitlements need no sandbox, since AX and spawning helpers
  aren't compatible with the App Sandbox (hence DMG distribution, not the App Store).
  - With a Developer ID: `codesign --options runtime --timestamp` on helpers first, then
    the app, then `notarytool submit --wait` + `stapler staple`.
  - **v1 default (no Apple Developer account):** sign with a stable self-signed "Aure
    Local" code-signing certificate from your keychain (created once by
    `scripts/bootstrap.sh`), **not ad-hoc**. Ad-hoc signatures change on every build and
    make macOS forget the Accessibility permission. Not notarized, so the first launch
    needs right-click, Open (or `xattr -dr com.apple.quarantine /Applications/Aure.app`),
    as documented in INSTALL.md.
  - Later, with a Developer ID: `notarize.sh` becomes active when the credentials exist.
- `scripts/make-dmg.sh`: `create-dmg` (or `hdiutil` fallback) with an
  `Applications` symlink, background image, and icon layout → `dist/Aure-<ver>.dmg`.
  Install = open DMG, drag Aure to Applications, launch, and onboarding takes over.
- Updates in v1: manual (new DMG). Sparkle is Phase 3.

## 9. Testing & quality
- Unit tests (`swift test`): PromptBuilder snapshots, DiffEngine, ResponseParser/Validator
  (malformed JSON, over-rewrite rejection, placeholder preservation), tone resolution,
  LearningService rules, ModelManager (sha256, resume, RAM gate) with a mocked URLProtocol,
  and the bridge framing (length-prefix edge cases, 1 MB limit).
- Provider tests: a `FakeLLMProvider` for all logic tests, plus an opt-in integration test
  (`AURE_IT=1`) that starts a real llama-server with qwen3-0.6b.
- Extension: vitest + jsdom for field detection, Gmail DOM fixtures, and insertText
  replacement. A manual checklist covers real Gmail.
- Eval harness (`aure-eval`): `eval/golden/{informal,formal,strict}.jsonl` with 150+
  cases (input, acceptable outputs, "no-change" negatives). Metrics: correction precision
  and recall (word-diff), false-positive rate on clean text, over-rewrite rate, p50/p95
  latency per model. Target for the default model: FP rate < 5%, p50 < 1.2 s for a
  40-word sentence on M1.
- Manual QA matrix: Slack (DM, channel, thread, edit message), Chrome Gmail (new, reply,
  forward), a Chrome textarea (GitHub comment), Aure Pad, check-selection in Notes and
  TextEdit; Apple Silicon and Intel (or Rosetta x86_64 run as an approximation).
- Performance budget: app idle < 80 MB RAM (excluding model), zero CPU when idle, bubble
  appears < 100 ms after focus.

## 10. Phases

- **Phase 0 — Foundations**: repo scaffold, XcodeGen, AureKit package, CI, llama.cpp
  vendoring + universal build, dev.toml cleanup.
- **Phase 1 — Engine**: provider protocol, llama-server supervisor, model catalog +
  downloader, prompt/parse/validate/diff, eval harness → pick the default model.
- **Phase 2 — MVP shell**: menu bar, settings, onboarding, Aure Pad (a working end-to-end
  product without integrations).
- **Phase 3 — System-wide**: AX pipeline, bubble + card, replacement, Slack adapter,
  check-selection hotkey.
- **Phase 4 — Chrome**: native host, bridge, extension, Gmail support.
- **Phase 5 — Voice**: tone presets, voice profile, voice assistant, learning + dictionary.
- **Phase 6 — Ship v1**: signing, DMG, docs, QA matrix, performance pass.
- **Later (Grammarly parity roadmap)**:
  - Tone detection ("this sounds harsh").
  - Clarity/concision suggestions and full-paragraph rewrites with alternatives.
  - Harper rule engine for instant checks.
  - More native app adapters (Mail, Notes, Messages, Teams, Notion) and Safari/Arc/Brave
    (same Chromium extension for Arc/Brave; Safari Web Extension wrapper).
  - Writing stats / weekly insights, snippets, generative "reply to this" prompts.
  - OpenAI provider (API key in Keychain), Sparkle updates.
  - Explicitly out of scope: plagiarism and AI detection (they need online corpora).

## 11. Risks & mitigations
| Risk | Mitigation |
|---|---|
| Small models over-rewrite or hallucinate | Correct-mode validator, JSON schema, eval gate before choosing the default, "show diff" UI (never auto-replace) |
| Slow on Intel (CPU only) | Recommend 0.6B on Intel, paragraph-only checks, cache, idle-only checking, a visible "slow model" hint |
| AX writes fail in some apps | Paste fallback with clipboard restore; the card always offers Copy |
| Gmail DOM changes | Extension layer with fixtures; generic contenteditable fallback |
| Accessibility permission lost between builds | Stable signing identity (section 8), onboarding re-check with a clear banner |
| Privacy (AX reads everything) | Password fields and blocklisted apps are never read; no text stored unless learning is on (only spans); offline mode |
| Bubble overlaps app UI | Offset rules per adapter, drag-to-reposition memory per app |

## 12. Resolved decisions (2026-09-26)
1. No Apple Developer account yet: use the self-signed stable certificate; notarization
   is optional/future.
2. Tasks: GitHub Issues in `tiagocolombo/aure`.
3. Minimum macOS: 14 Sonoma.
4. Dialect: US English default; Canadian English selectable (spelling via NSSpellChecker
   `en_CA`, prompt dialect note, e.g. colour/centre with American -ize endings).
5. Product name "Aure"; bundle id `com.tiagocolombo.aure`.
6. dev.toml: remove Postgres/Nx; keep Nix so `dev test`, `dev build`, `dev dmg`, and
   `dev lint` work (Xcode itself comes from the system, not Nix).
