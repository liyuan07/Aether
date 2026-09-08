import AppKit
import SwiftUI

@MainActor public final class TimerModule {
    public static let shared = TimerModule()
    let runtime = TimerRuntime()
    private init() {}
    public func start() { runtime.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
    public func stop() { runtime.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    public func overview() -> AnyView {
        AnyView(TimerPopover().onAppear { EyeCareManager.shared.beginPanelDisplayUpdates() }.onDisappear { EyeCareManager.shared.endPanelDisplayUpdates() })
    }
    public func settings() -> AnyView { AnyView(SettingsView()) }
}
