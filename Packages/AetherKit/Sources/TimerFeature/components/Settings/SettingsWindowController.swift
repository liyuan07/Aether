import SharedSupport
@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func showWindow() { AppRouter.shared.send(.settings(.timer)) }
}
