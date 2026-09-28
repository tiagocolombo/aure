import AureModels
import Foundation
import Testing
@testable import AureUI

@Test @MainActor func externalModelIsUsedInPlaceAndSurvivesRelaunch() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aure-ext-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let weights = dir.appendingPathComponent("lmstudio/Llama-3.2-3B-Q4_K_M.gguf")
    try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("GGUF".utf8).write(to: weights)
    // A folder Aure scans for models from other apps.
    setenv("AURE_EXTRA_MODEL_DIRS", weights.deletingLastPathComponent().path, 1)
    defer { unsetenv("AURE_EXTRA_MODEL_DIRS") }
    let suite = UUID().uuidString
    let store = ModelStore(directory: dir.appendingPathComponent("aure"))

    let app = AppState(defaults: UserDefaults(suiteName: suite)!, store: store)
    let external = ExternalModel(url: weights, name: "Llama 3.2 3B", source: "LM Studio", bytes: 2_000_000_000, architecture: "llama")
    app.selectedModelID = external.id

    // Relaunch before any scan: the model is rebuilt from its path, not copied into Aure's folder.
    let relaunched = AppState(defaults: UserDefaults(suiteName: suite)!, store: store)
    let model = try #require(relaunched.selectedModel)
    #expect(model.family == ExternalModels.family)
    #expect(relaunched.isInstalled(model))
    #expect(relaunched.modelURL(for: model) == weights)
    #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(weights.lastPathComponent).path))

    // If the other app deletes the file, Aure no longer treats it as installed.
    try FileManager.default.removeItem(at: weights)
    #expect(AppState(defaults: UserDefaults(suiteName: suite)!, store: store).selectedModel == nil)
}

/// The saved model id is a preference any program can write: it must not load a file
/// from outside the folders Aure scans.
@Test @MainActor func savedModelOutsideKnownFoldersIsIgnored() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aure-ext-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let weights = dir.appendingPathComponent("planted.gguf")
    try Data("GGUF".utf8).write(to: weights)
    let suite = UUID().uuidString
    UserDefaults(suiteName: suite)!.set(ExternalModels.idPrefix + weights.path, forKey: "selectedModelID")
    let app = AppState(defaults: UserDefaults(suiteName: suite)!, store: ModelStore(directory: dir.appendingPathComponent("aure")))
    #expect(app.selectedModel == nil)
}
