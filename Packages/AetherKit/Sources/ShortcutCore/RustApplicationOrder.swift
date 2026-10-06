// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

enum RustApplicationOrder {
    private static func keys(apps: [RegisteredApplication], prefs: [String]) -> ([UInt64],[UInt64]) {
        var tokens: [String:UInt64] = [:]
        func key(_ s: String) -> UInt64 {
            if let token = tokens[s] { return token }
            let token = UInt64(tokens.count + 1); tokens[s] = token; return token
        }
        return (apps.map { key($0.bundleIdentifier) },prefs.map(key))
    }
    static func ordered(_ apps: [RegisteredApplication], preferences: [String]) -> [RegisteredApplication] {
        let (appsKeys,prefsKeys) = keys(apps:apps,prefs:preferences)
        var output = [Int](repeating:0,count:apps.count + preferences.count)
        let count = appsKeys.withUnsafeBufferPointer { a in prefsKeys.withUnsafeBufferPointer { p in output.withUnsafeMutableBufferPointer { o in
            aether_app_order(a.baseAddress,a.count,p.baseAddress,p.count,o.baseAddress,o.count)
        } } }
        return output.prefix(count).map { apps[$0] }
    }
    static func move(_ prefs: [String], applications apps: [RegisteredApplication], offsets: IndexSet, destination: Int) -> [String]? {
        let (appsKeys,prefsKeys) = keys(apps:apps,prefs:prefs)
        let offsets = offsets.map(Int64.init)
        var output = [AetherAppReference](repeating:.init(),count:2 * (apps.count + prefs.count))
        let result = appsKeys.withUnsafeBufferPointer { a in prefsKeys.withUnsafeBufferPointer { p in offsets.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in
            aether_app_move(a.baseAddress,a.count,p.baseAddress,p.count,i.baseAddress,i.count,Int64(destination),o.baseAddress,o.count)
        } } } }
        guard result.valid != 0 else { return nil }
        return output.prefix(result.count).map { $0.source == 0 ? apps[$0.index].bundleIdentifier : prefs[$0.index] }
    }
}
