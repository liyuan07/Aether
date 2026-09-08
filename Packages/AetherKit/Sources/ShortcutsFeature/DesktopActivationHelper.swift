import SharedSupport
import AppKit
import Darwin
import Foundation

enum DesktopActivationHelper {
    private static let helperArgument = "--keypilot-activate-parent-for-desktop"

    static var isHelperProcess: Bool {
        CommandLine.arguments.dropFirst().first == helperArgument
    }

    static func runHelperAndExit() -> Never {
        let parentPID = getppid()
        guard let parent = NSRunningApplication(processIdentifier: parentPID),
              parent.executableURL?.standardizedFileURL == Bundle.main.executableURL?.standardizedFileURL
        else {
            exit(2)
        }
        exit(ApplicationFrontmostController.makeFrontmost(parent) ? 0 : 3)
    }

    @MainActor
    static func activateKeyPilotFromHelper() -> Bool {
        guard let executableURL = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [helperArgument]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
