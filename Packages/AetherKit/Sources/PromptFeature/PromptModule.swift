import SwiftUI

/// The application owns window presentation; this module owns its state and views.
@MainActor public final class PromptModule {
    public static let shared = PromptModule()
    private var storedModel: PromptModel?
    private var model: PromptModel {
        if let storedModel { return storedModel }
        let created = PromptModel()
        storedModel = created
        return created
    }
    private init() {}
    public func compactPanel() -> AnyView { AnyView(PromptWorkspaceView(model: model)) }
    public func settings() -> AnyView { AnyView(PromptSettingsView(model: model)) }
    public func stop() { storedModel?.cancelOptimization() }
}
