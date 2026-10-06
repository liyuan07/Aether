// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CAetherCore
@testable import ShortcutCore

@Test func rustPreferencesDefaultsAndMigrationMatchOriginalAcrossSixThousandDocuments() throws {
    var seed: UInt64 = 242
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let values: [Any] = [NSNull(),true,false,0,1,"invalid",[],[:]]
    var successful = 0
    for _ in 0..<6000 {
        var document: [String:Any] = ["schemaVersion":values[Int(next() % 8)]]
        for key in ["app","general"] where next() % 4 != 0 {
            var fields: [String:Any] = [:]
            for field in ["launchAtLogin","blockAutomaticABC","showModifierButtons"] where next() % 3 != 0 { fields[field] = values[Int(next() % 8)] }
            document[key] = next() % 5 == 0 ? values[Int(next() % 8)] : fields
        }
        if next() % 3 == 0 {
            document["applicationShortcuts"] = ["holdDuration":Double(next() % 25) / 10,"restoreMinimizedWindows":next() % 2 == 0,
                "orderedBundleIdentifiers":["A":["É","E\u{301}","synthetic"]]]
        }
        let data = try JSONSerialization.data(withJSONObject:document)
        let old = try? JSONDecoder().decode(OldPreferences.self,from:data)
        let rust = try? JSONDecoder().decode(AppPreferencesConfiguration.self,from:data)
        #expect((old == nil) == (rust == nil))
        if let old, let rust {
            successful += 1
            #expect(old.schemaVersion == rust.schemaVersion)
            #expect(old.app.launchAtLogin == rust.app.launchAtLogin)
            #expect(old.app.blockAutomaticABC == rust.app.blockAutomaticABC)
            #expect(old.app.showModifierButtons == rust.app.showModifierButtons)
            #expect(old.applicationShortcuts.orderedBundleIdentifiers == rust.applicationShortcuts.orderedBundleIdentifiers)
            #expect(old.applicationShortcuts.holdDuration == rust.applicationShortcuts.holdDuration)
            #expect(old.applicationShortcuts.restoreMinimizedWindows == rust.applicationShortcuts.restoreMinimizedWindows)
        }
    }
    #expect(successful > 500)
}

@Test func rustPreferencePoliciesMatchOriginalBoundaries() {
    for value in [Double.nan,-Double.infinity,Double.infinity,-1,0,0.3,0.5,1.5,2] {
        var prefs = ApplicationShortcutPreferences(); prefs.holdDuration = value
        let old = min(max(value,0.3),1.5), result = prefs.normalizedHoldDuration()
        #expect(old == result || (old.isNaN && result.isNaN))
    }
    for restore in [false,true] {
        for (behavior,moves,restores) in [(ApplicationWindowBehavior.followGlobal,true,restore),(.keepMinimized,true,false),(.restoreMinimized,true,true),(.activateOnly,false,false)] {
            var prefs = ApplicationShortcutPreferences(); prefs.restoreMinimizedWindows = restore; prefs.windowBehaviorOverrides["synthetic"] = behavior
            let result = prefs.windowBehavior(for:"synthetic")
            #expect(result.moveWindows == moves && result.restoreMinimized == restores)
        }
    }
    let keys: [UInt16:String] = [0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",40:"K",37:"L",46:"M",45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",32:"U",9:"V",13:"W",7:"X",16:"Y",6:"Z"]
    for code in UInt16.min...UInt16.max {
        #expect(ApplicationLetterKey.letter(for:code) == keys[code])
        #expect(PhysicalInputSwitchKey.matches(keyCode:code) == [57,63,102,104].contains(code))
    }
    for letter in ["a","Z","K","ſ","é","E\u{301}","ß","Ａ","","A\0","ab"] + Array(keys.values) {
        #expect(ApplicationLetterKey.keyCode(for:letter) == keys.first { $0.value == letter.uppercased() }?.key)
    }
    for code in UInt32(0)...UInt32(65535) {
        guard let scalar = UnicodeScalar(code) else { continue }
        let letter = String(scalar)
        #expect(ApplicationLetterKey.keyCode(for:letter) == keys.first { $0.value == letter.uppercased() }?.key)
    }
    for current in [false,true] { for legacy in [false,true] {
        #expect(aether_preferences_source(current ? 1 : 0,legacy ? 1 : 0) == (current ? 0 : legacy ? 1 : -1))
    } }
    for persist in [false,true] { for legacy in [false,true] { for version in [Int.min,-1,0,1,8,9,10,Int.max] {
        #expect((aether_preferences_should_write(persist ? 1 : 0,legacy ? 1 : 0,Int64(version)) != 0) == (persist && (legacy || version < 9)))
    } } }
}

@Test func rustPreferenceStoreKeepsMigrationSaveTimingAndFutureTags() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPrefs-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let current = directory.appendingPathComponent("preferences.json"), legacy = directory.appendingPathComponent("legacy.json")
    let store = AppPreferencesStore(fileURL:current,legacyFileURL:legacy)
    let data = Data("{\"schemaVersion\":1,\"general\":{\"launchAtLogin\":true,\"blockAutomaticABC\":true}}".utf8)
    try data.write(to:legacy)
    #expect(try store.load().app.launchAtLogin)
    #expect(!FileManager.default.fileExists(atPath:current.path))
    #expect(try Data(contentsOf:legacy) == data)
    #expect(try store.load(persistingMigrations:true).app.blockAutomaticABC)
    #expect(try Data(contentsOf:legacy) == data)
    let saved = try JSONDecoder().decode(AppPreferencesConfiguration.self,from:Data(contentsOf:current))
    #expect(saved.schemaVersion == 9 && saved.app.launchAtLogin)
    let future = Data("{\"schemaVersion\":99,\"app\":{\"launchAtLogin\":false}}".utf8)
    try future.write(to:current)
    #expect(try !store.load(persistingMigrations:true).app.launchAtLogin)
    #expect(try Data(contentsOf:current) == future)
}

public struct OldGeneral: Codable, Hashable, Sendable {
    public var launchAtLogin = false
    public var blockAutomaticABC = false
    public var showModifierButtons = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, blockAutomaticABC, showModifierButtons
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        blockAutomaticABC = try container.decodeIfPresent(Bool.self, forKey: .blockAutomaticABC) ?? blockAutomaticABC
        showModifierButtons = try container.decodeIfPresent(
            Bool.self,
            forKey: .showModifierButtons
        ) ?? showModifierButtons
    }
}

public struct OldShortcuts: Codable, Hashable, Sendable {
    public var defaultBundleIdentifiers: [String: String] = [:]
    public var orderedBundleIdentifiers: [String: [String]] = [:]
    public var holdDuration: TimeInterval = 0.5
    public var restoreMinimizedWindows = true
    public var windowBehaviorOverrides: [String: ApplicationWindowBehavior] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case defaultBundleIdentifiers, orderedBundleIdentifiers, holdDuration, restoreMinimizedWindows, windowBehaviorOverrides
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultBundleIdentifiers = try container.decodeIfPresent(
            [String: String].self,
            forKey: .defaultBundleIdentifiers
        ) ?? defaultBundleIdentifiers
        orderedBundleIdentifiers = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .orderedBundleIdentifiers
        ) ?? orderedBundleIdentifiers
        holdDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .holdDuration) ?? holdDuration
        restoreMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .restoreMinimizedWindows) ?? true
        windowBehaviorOverrides = try container.decodeIfPresent([String: ApplicationWindowBehavior].self,
                                                               forKey: .windowBehaviorOverrides) ?? [:]
    }

    public func normalizedHoldDuration() -> TimeInterval {
        min(max(holdDuration, 0.3), 1.5)
    }

    public func windowBehavior(for identifier: String?) -> (moveWindows: Bool, restoreMinimized: Bool) {
        switch identifier.flatMap({ windowBehaviorOverrides[$0] }) ?? .followGlobal {
        case .followGlobal: (true, restoreMinimizedWindows)
        case .keepMinimized: (true, false)
        case .restoreMinimized: (true, true)
        case .activateOnly: (false, false)
        }
    }
}

public struct OldPreferences: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 9

    public var schemaVersion = currentSchemaVersion
    public var app = OldGeneral()
    public var applicationShortcuts = OldShortcuts()

    public init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, app, general, applicationShortcuts }
    private enum LegacyGeneralKeys: String, CodingKey { case launchAtLogin, blockAutomaticABC }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let storedApp = try container.decodeIfPresent(OldGeneral.self, forKey: .app) {
            app = storedApp
        }
        applicationShortcuts = try container.decodeIfPresent(
            OldShortcuts.self,
            forKey: .applicationShortcuts
        ) ?? applicationShortcuts
        if container.contains(.general) {
            let legacy = try container.nestedContainer(keyedBy: LegacyGeneralKeys.self, forKey: .general)
            if !container.contains(.app) {
                app.launchAtLogin = try legacy.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? app.launchAtLogin
            }
            app.blockAutomaticABC = try legacy.decodeIfPresent(Bool.self, forKey: .blockAutomaticABC) ?? app.blockAutomaticABC
        }
        schemaVersion = Self.currentSchemaVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(app, forKey: .app)
        try container.encode(applicationShortcuts, forKey: .applicationShortcuts)
    }
}

