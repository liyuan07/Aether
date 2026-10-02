import Foundation

/// App identity and version helpers. Pure Swift so the domain layer and tests
/// can compare versions without importing AppKit.
public enum AppInfo {
    public static let name = "WhatPort"

    /// Running app version. The single source of truth is the bundled
    /// Info.plist's CFBundleShortVersionString (written by the build scripts).
    /// Falls back to "dev" when run via `swift run`, which has no bundle.
    public static let version: String = {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return v
        }
        // No bundled Info.plist resolved via Bundle.main. Walk up from the
        // executable to find a Contents/Info.plist sibling. Resolve symlinks
        // first: invoked via Homebrew's /opt/homebrew/bin symlink, the
        // executable path points outside the .app, and walking up the symlink
        // would never find the bundle.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        var dir = URL(fileURLWithPath: exe)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<4 {
            let plist = dir.appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: plist),
               let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let v = parsed["CFBundleShortVersionString"] as? String {
                return v
            }
            dir = dir.deletingLastPathComponent()
        }
        return "dev"
    }()

    /// Compare dot-separated numeric versions. Non-numeric segments compare as 0.
    public static func isNewer(remote: String, current: String) -> Bool {
        let r = parts(remote)
        let c = parts(current)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
