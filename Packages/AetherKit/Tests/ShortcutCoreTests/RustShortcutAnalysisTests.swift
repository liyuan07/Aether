// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

private func oldExecutableIDs(_ rules: [ShortcutRule], monitoring: Bool) -> Set<UUID> {
    let invalid = Set(ReferenceShortcutRuleValidator.issues(in: rules).flatMap(\.affectedRuleIDs))
    return Set(rules.compactMap { rule in
        guard rule.isEnabled, !invalid.contains(rule.id), rule.source.physicalModifiers.isEmpty || monitoring else { return nil }
        return rule.id
    })
}

@Test("Rust 规则快照的校验和执行策略与独立旧实现一致")
func shortcutAnalysisParity() {
    var seed: UInt64 = 712
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    func key() -> KeyCombination {
        .init(keyCode: UInt16(next(12)), modifiers: .init(rawValue: UInt8(next(16))),
            physicalModifiers: .init(rawValue: UInt16(next(4) == 0 ? next(65536) : 0)))
    }
    for iteration in 0..<800 {
        var rules: [ShortcutRule] = []
        for position in 0..<(iteration % 45) {
            let id = position > 0 && next(4) == 0 ? rules[next(position)].id : UUID()
            rules.append(.init(id: id, name: "合成规则 \(position)", source: key(),
                action: next(3) == 0 ? .showDesktop : .remap(to: key()), isEnabled: next(4) != 0))
        }
        let analysis = ShortcutRuleAnalysis(rules: rules)
        let expectedIssues = ReferenceShortcutRuleValidator.issues(in: rules)
        #expect(analysis.issues.count == expectedIssues.count)
        #expect(analysis.issues.allSatisfy { expectedIssues.contains($0) })
        for monitoring in [false, true] {
            let ids = oldExecutableIDs(rules, monitoring: monitoring)
            #expect(analysis.executableRuleIDs(inputMonitoringGranted: monitoring) == ids)
            for permission in [false, true] {
                for recording in [false, true] {
                    let expected = permission && !recording ? rules.filter { ids.contains($0.id) } : []
                    #expect(analysis.executableRules(permissionGranted: permission, inputMonitoringGranted: monitoring,
                        isRecording: recording) == expected)
                }
            }
        }
    }
}

@Test("UUID 占用与过滤保持旧语义，禁用副本也按身份集合展开")
func shortcutAnalysisDuplicateIdentitySemantics() {
    let id = UUID()
    let regular = ShortcutRule(id: id, name: "普通", source: .init(keyCode: 1, modifiers: .command), action: .showDesktop)
    var disabled = regular; disabled.isEnabled = false; disabled.name = "禁用副本"
    var physical = regular; physical.source.physicalModifiers = .capsLock; physical.name = "物理副本"
    let snapshot = ShortcutRuleAnalysis(rules: [regular, disabled, physical])
    #expect(snapshot.executableRules(permissionGranted: true, inputMonitoringGranted: false, isRecording: false)
        == [regular, disabled, physical])
    var invalid = regular; invalid.source = .init(keyCode: 99, modifiers: [])
    let rejected = ShortcutRuleAnalysis(rules: [regular, disabled, physical, invalid])
    #expect(rejected.executableRuleIDs(inputMonitoringGranted: true).isEmpty)
    #expect(rejected.executableRules(permissionGranted: true, inputMonitoringGranted: true, isRecording: false).isEmpty)
}

@Test("不可变规则快照共享来源且隔离后续编辑，支持并发读取")
func shortcutAnalysisSnapshotOwnership() async {
    var rules = (0..<100).map { ShortcutRule(name: "合成 \($0)",
        source: .init(keyCode: UInt16($0), modifiers: .command), action: .showDesktop) }
    let analysis = ShortcutRuleAnalysis(rules: rules)
    let original = analysis.executableRules(permissionGranted: true, inputMonitoringGranted: true, isRecording: false)
    rules.withUnsafeBufferPointer { source in
        original.withUnsafeBufferPointer { #expect($0.baseAddress == source.baseAddress) }
    }
    rules[0].name = "后续编辑"; rules.removeLast()
    #expect(analysis.executableRules(permissionGranted: true, inputMonitoringGranted: false, isRecording: false) == original)
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<128 {
            group.addTask {
                analysis.issues.isEmpty && analysis.executableRules(permissionGranted: true,
                    inputMonitoringGranted: false, isRecording: false) == original
            }
        }
        for await valid in group { #expect(valid) }
    }
}
