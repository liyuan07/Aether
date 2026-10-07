// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// Immutable presentation snapshot. Native String equality/sort remain the text primitives.
public final class ApplicationCatalog: Sendable {
    public let groups: [RegisteredApplicationGroup]
    public let seedAdditions: [String: String]
    private let groupPositions: [String: Int]
    private let defaults: [String: RegisteredApplication]

    public init(applications: [RegisteredApplication], preferences: ApplicationShortcutPreferences,
                legacyTargets: [ApplicationTarget], rules: [ShortcutRule]) {
        var tokens: [String: UInt64] = [:]
        func key(_ value: String) -> UInt64 {
            if let token = tokens[value] { return token }
            let token = UInt64(tokens.count + 1); tokens[value] = token; return token
        }
        let apps = applications.map { AetherCatalogApp(initial: key($0.initial), bundle: key($0.bundleIdentifier), path: key($0.applicationPath)) }
        let initials = Set(applications.map(\.initial)).sorted()
        var ordered: [UInt64] = []
        let descriptors = initials.map { initial -> AetherCatalogGroup in
            let start = ordered.count
            ordered.append(contentsOf: (preferences.orderedBundleIdentifiers[initial] ?? []).map(key))
            let selected = preferences.defaultBundleIdentifiers[initial]
            return .init(initial: key(initial), default_bundle: selected.map(key) ?? 0,
                start: start, count: ordered.count - start, has_default: selected == nil ? 0 : 1)
        }
        var targets = legacyTargets.map { AetherCatalogTarget(bundle: $0.bundleIdentifier.map(key) ?? 0, path: key($0.applicationPath), enabled: 1) }
        targets.append(contentsOf: rules.compactMap { rule in
            guard case let .application(target, _) = rule.action else { return nil }
            return .init(bundle: target.bundleIdentifier.map(key) ?? 0, path: key(target.applicationPath), enabled: rule.isEnabled ? 1 : 0)
        })
        let plan = apps.withUnsafeBufferPointer { a in descriptors.withUnsafeBufferPointer { g in
            ordered.withUnsafeBufferPointer { p in targets.withUnsafeBufferPointer { t in
                aether_app_catalog_create(a.baseAddress, a.count, g.baseAddress, g.count, p.baseAddress, p.count, t.baseAddress, t.count)
            } }
        } }
        guard let plan else { preconditionFailure("Invalid application catalog input") }
        defer { aether_app_catalog_destroy(plan) }
        var groups: [RegisteredApplicationGroup] = [], defaults: [String: RegisteredApplication] = [:], additions: [String: String] = [:]
        for (index, initial) in initials.enumerated() {
            let info = aether_app_catalog_info(plan, index)
            let rows = (0..<info.count).map { applications[aether_app_catalog_index(plan, index, $0)] }
            groups.append(.init(initial: initial, applications: rows))
            if info.default_index >= 0 { defaults[initial] = applications[info.default_index] }
            if info.seed_index >= 0 { additions[initial] = applications[info.seed_index].bundleIdentifier }
        }
        self.groups = groups; self.defaults = defaults; self.seedAdditions = additions
        self.groupPositions = Dictionary(uniqueKeysWithValues: initials.enumerated().map { ($0.element, $0.offset) })
    }

    public func applications(for initial: String) -> [RegisteredApplication] {
        guard let index = groupPositions[initial] else { return [] }
        return groups[index].applications
    }
    public func defaultApplication(for initial: String) -> RegisteredApplication? { defaults[initial] }
}
