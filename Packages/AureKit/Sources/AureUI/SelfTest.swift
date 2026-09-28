import AureCore
import AureModels
import Foundation

/// `Aure.app/Contents/MacOS/Aure --selftest ["text"] [--model <id>]`
/// `--model` takes a catalog id or "path:/abs/file.gguf" (a model from another app).
/// `--ollama <name>` runs through a local Ollama server instead, e.g. `--ollama qwen3:4b`.
/// Headless end-to-end check of the packaged app: finds the bundled
/// llama-server, loads the selected (or recommended, installed) model,
/// runs one correction and prints the result. Exit code 0 on success.
enum SelfTest {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return }
        let explicit = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
        let text = explicit ?? "Their going to the store tomorow, can you came with me?"

        Task { @MainActor in
            let state = AppState()
            print("catalog: \(state.catalog.map { "\($0.id) (\($0.sizeDescription))" }.joined(separator: ", "))")
            print("hardware: \(state.hardware.cpuName), \(Int(state.hardware.memoryGB.rounded())) GB, recommended \(state.recommendedModelID)")
            await state.refreshExternalModels()
            print("other apps: " + (state.externalModels.isEmpty ? "none found"
                : state.externalModels.map { "\($0.name) [\($0.source), \($0.architecture ?? "?"), \($0.info.sizeDescription)]" }
                    .joined(separator: ", ")))
            // --model <id>: use a specific model for this run only (catalog id or "path:/abs/file.gguf").
            let savedModelID = state.selectedModelID
            let savedEngine = state.engineKind, savedOllamaModel = state.ollamaModelName
            if let m = args.firstIndex(of: "--model"), m + 1 < args.count {
                state.selectedModelID = args[m + 1]
                if state.hasBuiltInEngine { state.engineKind = .builtIn }
            }
            if let o = args.firstIndex(of: "--ollama"), o + 1 < args.count {
                state.engineKind = .ollama
                state.ollamaModelName = args[o + 1]
            }
            if state.engineKind == .ollama {
                await state.refreshOllama()
                print("ollama: \(state.ollamaStatus), models: "
                      + (state.ollamaModels.isEmpty ? "none" : state.ollamaModels.map(\.name).joined(separator: ", ")))
                print("model: \(state.ollamaModelName.map(state.ollamaDisplayName) ?? "none selected") (Ollama)")
            } else if state.selectedModel.map(state.isInstalled) != true {
                let pick = state.catalog.first { $0.id == state.recommendedModelID && state.isInstalled($0) }
                    ?? state.installedModels.first
                state.selectedModelID = pick?.id
            }
            if state.engineKind == .builtIn { print("model: \(state.selectedModel?.name ?? "none installed")") }
            let started = Date()
            await state.startEngine()
            print("engine: \(state.engine.label) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            guard state.engine.isReady else {
                await state.stopEngine()
                state.selectedModelID = savedModelID
                state.engineKind = savedEngine
                state.ollamaModelName = savedOllamaModel
                exit(1)
            }
            var failed = false
            for tone in [Tone.informal, .formal, .strictFormal] {
                do {
                    let r = try await state.check(text, tone: tone)
                    print("[\(tone.rawValue)] \(r.latencyMs) ms: \(r.corrected)")
                    for issue in r.issues {
                        print("   - \(issue.category.rawValue): \"\(issue.original)\" -> \"\(issue.replacement)\" (\(issue.explanation))")
                    }
                } catch {
                    print("[\(tone.rawValue)] error: \(error.localizedDescription)")
                    failed = true
                }
            }
            do {
                let r = try await state.check(text, mode: .rewrite, tone: .strictFormal)
                print("[rewrite strictFormal] \(r.latencyMs) ms: \(r.corrected)")
            } catch {
                print("[rewrite strictFormal] error: \(error.localizedDescription)")
            }
            // The bubble's "Better writing · Optional" path: grammar first, then one alternative.
            let wordy = "It was decided by the team that the budget would be reviewed by us again next week."
            do {
                let grammar = try await state.check(wordy, tone: .formal)
                let started = Date()
                if let s = try await state.suggestWriting(grammar.corrected, tone: .formal) {
                    print("[better writing formal] \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(s.replacement)")
                } else {
                    print("[better writing formal] no alternative offered"
                          + (state.writingSuggestionsEnabled ? "" : " (disabled in Settings)"))
                }
            } catch {
                print("[better writing formal] error: \(error.localizedDescription)")
                failed = true
            }
            await state.stopEngine()
            // The self-test must not change the model the user picked in the app.
            state.selectedModelID = savedModelID
            state.engineKind = savedEngine
            state.ollamaModelName = savedOllamaModel
            exit(failed ? 1 : 0)
        }
        RunLoop.main.run()
    }
}
