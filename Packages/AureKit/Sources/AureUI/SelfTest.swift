import AureCore
import AureModels
import Foundation

/// `Aure.app/Contents/MacOS/Aure --selftest ["text"]`
/// Headless end-to-end check of the packaged app: finds the bundled
/// llama-server, loads the selected (or recommended, installed) model,
/// runs one correction and prints the result. Exit code 0 on success.
enum SelfTest {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return }
        let text = i + 1 < args.count ? args[i + 1] : "Their going to the store tomorow, can you came with me?"

        Task { @MainActor in
            let state = AppState()
            print("catalog: \(state.catalog.map { "\($0.id) (\($0.sizeDescription))" }.joined(separator: ", "))")
            print("hardware: \(state.hardware.cpuName), \(Int(state.hardware.memoryGB.rounded())) GB, recommended \(state.recommendedModelID)")
            if state.selectedModel.map(state.isInstalled) != true {
                let pick = state.catalog.first { $0.id == state.recommendedModelID && state.isInstalled($0) }
                    ?? state.installedModels.first
                state.selectedModelID = pick?.id
            }
            print("model: \(state.selectedModel?.name ?? "none installed")")
            let started = Date()
            await state.startEngine()
            print("engine: \(state.engine.label) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            guard state.engine.isReady else {
                await state.stopEngine()
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
            exit(failed ? 1 : 0)
        }
        RunLoop.main.run()
    }
}
