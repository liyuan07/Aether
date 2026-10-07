// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

// Edit behavior frozen from 1782534 AppModel; no Rust helpers in the reference.
private func originalMove(_ input: [ShortcutRule], _ offsets: IndexSet, _ destination: Int) -> [ShortcutRule]? {
    guard !offsets.isEmpty, offsets.allSatisfy(input.indices.contains), destination >= 0, destination <= input.count else { return nil }
    var rules = input
    let moving = offsets.map { rules[$0] }
    let insertion = destination - offsets.filter { $0 < destination }.count
    for index in offsets.reversed() { rules.remove(at: index) }
    rules.insert(contentsOf: moving, at: insertion)
    return rules
}

@Test("Rust 规则索引与编辑计划保留首 UUID、选择、冲突扫描及稳定拖动语义")
func shortcutRuleIndexParity() {
    var seed: UInt64 = 7781
    func next(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(count)) }
    let ids = (0..<12).map { _ in UUID() }
    for iteration in 0..<2500 {
        let rules = (0..<next(30)).map { i -> ShortcutRule in
            var source = KeyCombination(keyCode: UInt16(next(65536)), modifiers: .command,
                physicalModifiers: .init(rawValue: UInt16(next(65536))))
            source.modifiers = .init(rawValue: UInt8(next(256)))
            return .init(id: ids[next(ids.count)], name: "合成\(i)", source: source,
                action: .finderFolder(path: "合成/\(i)"), isEnabled: next(2) == 0)
        }
        let index = ShortcutRuleIndex(rules)
        for id in ids + [UUID()] {
            let position = rules.firstIndex { $0.id == id }
            #expect(index.position(of: id) == position)
            let removal = index.removing(id)
            #expect(removal.index == position)
            if let position {
                var remaining = rules; remaining.remove(at: position)
                let selected = remaining.indices.contains(position) ? position : remaining.indices.last
                #expect(removal.selection == selected)
                #expect(removal.requiresConflictScan)
            } else {
                #expect(removal.selection == nil && !removal.requiresConflictScan)
            }
            var changed = position.map { rules[$0] } ?? ShortcutRule(id: id, name: "missing", source: .init(keyCode: 1, modifiers: .command), action: .showDesktop)
            switch iteration % 5 {
            case 0: changed.name = "改名"; changed.action = .showDesktop
            case 1: changed.isEnabled.toggle()
            case 2: changed.source.keyCode &+= 1
            case 3: changed.source.physicalModifiers.formSymmetricDifference(.capsLock)
            default: changed.source.modifiers.formSymmetricDifference(.option)
            }
            let update = index.updating(changed)
            #expect(update.index == position)
            let rescan = position.map { rules[$0].source != changed.source || rules[$0].isEnabled != changed.isEnabled } ?? false
            #expect(update.requiresConflictScan == rescan)
        }
        let offsets = IndexSet((0..<next(8)).map { _ in next(rules.count + 3) })
        let destination = iteration % 11 == 0 ? (iteration % 2 == 0 ? Int.min : Int.max) : next(rules.count + 3) - 1
        #expect(ShortcutRuleIndex.moving(rules, offsets: offsets, destination: destination) == originalMove(rules, offsets, destination))
    }
}

@Test("规则索引拥有独立元数据，可并发只读，新增规则沿用原模板且使用新身份")
func shortcutRuleIndexLifetimeAndTemplate() async {
    let id = UUID()
    var source = [ShortcutRule(id: id, name: "合成", source: .init(keyCode: 0, modifiers: .command), action: .showDesktop)]
    let index = ShortcutRuleIndex(source)
    source[0].id = UUID(); source.removeAll()
    await withTaskGroup(of: Bool.self) { tasks in
        for _ in 0..<256 { tasks.addTask { index.position(of: id) == 0 && index.removing(id).selection == nil } }
        for await result in tasks { #expect(result) }
    }
    for path in ["", "~/Desktop", "/合成/E\u{301}", "x\0y"] {
        let first = ShortcutRuleIndex.newRule(desktopPath: path), second = ShortcutRuleIndex.newRule(desktopPath: path)
        #expect(first.id != second.id)
        #expect(first.name == "新快捷键" && !first.isEnabled)
        #expect(first.source == .init(keyCode: 45, modifiers: [.option, .shift]))
        #expect(first.action == .finderFolder(path: path))
    }
}

@Test("规则索引读取与批量重排局部基准，仅显式启用 Release 时运行")
func shortcutRuleEditBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { return }
    guard !_isDebugAssertConfiguration() else { Issue.record("Benchmark requires Release"); return }
    let rules = (0..<3000).map { i in ShortcutRule(name: "合成 \(i)", source: .init(keyCode: UInt16(i), modifiers: .command), action: .showDesktop) }
    let index = ShortcutRuleIndex(rules), ids = rules.map(\.id)
    let offsets = IndexSet(stride(from: 0, to: rules.count, by: 2))
    let expected = originalMove(rules, offsets, rules.count)!
    #expect(ShortcutRuleIndex.moving(rules, offsets: offsets, destination: rules.count) == expected)
    func oldRead() -> Int {
        var sum = 0
        for _ in 0..<3 { for id in ids { sum += Int(rules.first { $0.id == id }!.source.keyCode) } }
        return sum
    }
    func newRead() -> Int {
        var sum = 0
        for _ in 0..<3 { for id in ids { sum += Int(rules[index.position(of: id)!].source.keyCode) } }
        return sum
    }
    func oldMove() -> Int { originalMove(rules, offsets, rules.count)!.reduce(0) { $0 + Int($1.source.keyCode) } }
    func newMove() -> Int { ShortcutRuleIndex.moving(rules, offsets: offsets, destination: rules.count)!.reduce(0) { $0 + Int($1.source.keyCode) } }
    func measure(_ body: () -> Int, expected: Int) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        let sum = body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(sum == expected)
        return elapsed
    }
    var oldReads: [UInt64] = [], newReads: [UInt64] = [], oldMoves: [UInt64] = [], newMoves: [UInt64] = []
    let sum = 3000 * 2999 / 2
    for round in 0..<7 {
        if round.isMultiple(of: 2) {
            oldReads.append(measure(oldRead, expected: 3 * sum)); newReads.append(measure(newRead, expected: 3 * sum))
            oldMoves.append(measure(oldMove, expected: sum)); newMoves.append(measure(newMove, expected: sum))
        } else {
            newReads.append(measure(newRead, expected: 3 * sum)); oldReads.append(measure(oldRead, expected: 3 * sum))
            newMoves.append(measure(newMove, expected: sum)); oldMoves.append(measure(oldMove, expected: sum))
        }
    }
    let result: [String: Any] = ["rules": rules.count, "rounds": 7, "readPasses": 3, "moveOffsets": offsets.count,
        "oldReadNs": oldReads, "newReadNs": newReads, "oldMoveNs": oldMoves, "newMoveNs": newMoves,
        "oldReadMedianNs": oldReads.sorted()[3], "newReadMedianNs": newReads.sorted()[3],
        "oldMoveMedianNs": oldMoves.sorted()[3], "newMoveMedianNs": newMoves.sorted()[3],
        "scope": "synthetic repeated identity reads (index prebuilt) and one half-selection move; includes native DTO assembly, excludes model publication, I/O, rendering, process resources"]
    print("RULE_EDIT_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}
