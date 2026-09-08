import AppKit
import SharedSupport
@MainActor final class SettingsWindowController {
    let model: AppModel
    init(model: AppModel, presentationChanged: @escaping (Bool) -> Void) { self.model = model }
    func show(section: SettingsSection = .general, ruleID: UUID? = nil) {
        ShortcutsModule.shared.navigation.section = section
        model.selectedRuleID = ruleID
        AppRouter.shared.send(.settings(.shortcuts))
    }
    func show(ruleID: UUID?) { show(section: .general, ruleID: ruleID) }
}
