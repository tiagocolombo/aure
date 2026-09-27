import Foundation

/// Pure presentation state: nil symbol means the healthy, ready brand mark.
@MainActor struct MenuBarPresentation {
    let paused: Bool
    let engine: AppState.EngineStatus
    let status: CheckCoordinator.Status?

    var symbol: String? {
        if paused { return "text.badge.xmark" }
        switch engine {
        case .ready:
            switch status {
            case .issues: return "exclamationmark.bubble"
            case .error: return "text.badge.minus"
            case .checking: return "hourglass"
            default: return nil
            }
        case .loading: return "hourglass"
        case .noModel, .failed: return "text.badge.minus"
        }
    }

    var accessibilityLabel: String {
        if paused { return "Aure — Paused" }
        if engine.isReady {
            switch status {
            case .issues(let count), .suggestions(let count):
                return "Aure — \(count) \(count == 1 ? "suggestion" : "suggestions")"
            case .checking: return "Aure — Checking writing"
            case .error(let message): return "Aure — \(message)"
            default: break
            }
        }
        return "Aure — \(engine.label)"
    }
}
