import AppKit
import SwiftUI

@MainActor public final class PortsModule {
    public static let shared = PortsModule()
    private var storedModel: PortsModel?
    private var observers: [NSObjectProtocol] = []
    private var model: PortsModel {
        if let storedModel { return storedModel }
        let created = PortsModel()
        storedModel = created
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak created] _ in
                MainActor.assumeIsolated { created?.setSleeping(sleeping) }
            })
        }
        for (name, hidden) in [(NSApplication.didHideNotification, true), (NSApplication.didUnhideNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak created] _ in
                MainActor.assumeIsolated { created?.setApplicationHidden(hidden) }
            })
        }
        return created
    }
    private init() {}
    public func summary() -> AnyView { AnyView(PortsSummaryView(model: model)) }
    public func details() -> AnyView { AnyView(PortsWorkspaceView(model: model)) }
    public func setSummaryVisible(_ value: Bool) {
        if value { model.setVisible(.summary, true) } else { storedModel?.setVisible(.summary, false) }
    }
    public func setDetailsVisible(_ value: Bool) {
        if value { model.setVisible(.details, true) } else { storedModel?.setVisible(.details, false) }
    }
    public func stop() {
        storedModel?.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        storedModel = nil
    }
}
