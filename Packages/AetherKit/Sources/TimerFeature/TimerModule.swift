import AppKit
import SwiftUI

@MainActor public final class TimerModule {
    public static let shared = TimerModule()
    let runtime = TimerRuntime()
    private init() {}
    public func start() { runtime.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
    public func stop() { runtime.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    public func overview(isVisible: Bool = true) -> AnyView {
        AnyView(TimerPopover()
            .onAppear { if isVisible { EyeCareManager.shared.beginPanelDisplayUpdates() } }
            .onChange(of: isVisible) { _, visible in
                if visible { EyeCareManager.shared.beginPanelDisplayUpdates() }
                else { EyeCareManager.shared.endPanelDisplayUpdates() }
            }
            .onDisappear { EyeCareManager.shared.endPanelDisplayUpdates() })
    }
    public func settings() -> AnyView { AnyView(SettingsView()) }
}
