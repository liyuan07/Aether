import AppKit
import Foundation
let identifier = CommandLine.arguments[1]
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
for app in apps { _ = app.terminate() }
let deadline = Date().addingTimeInterval(12)
while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if apps.contains(where: { !$0.isTerminated }) {
    fputs("Application did not finish quitting; installation stopped.\n", stderr)
    exit(1)
}
