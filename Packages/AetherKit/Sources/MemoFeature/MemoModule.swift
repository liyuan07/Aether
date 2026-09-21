import SwiftUI

/// The application owns presentation; this module owns local memo data and its compact page.
@MainActor public final class MemoModule {
    public static let shared = MemoModule()
    private var storedModel: MemoModel?
    private var model: MemoModel {
        if let storedModel { return storedModel }
        let created = MemoModel()
        storedModel = created
        return created
    }

    private init() {}

    public func compactPanel() -> AnyView { AnyView(MemoWorkspaceView(model: model)) }
}
