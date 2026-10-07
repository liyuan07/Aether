// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Dispatch
import Testing
@testable import ShortcutsFeature

@Test("Rust 应用动作与独立旧实现的激活、取消、目标与截止状态一致")
func rustActionTokenMatchesFrozenNativeState() {
    var seed: UInt64 = 117
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    let pids: [Int32?] = [nil, 0, 1, -1, 2, .min, .max]
    let times: [Double] = [-.infinity, .infinity, .nan, -0.0, 0, 1000, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
    for iteration in 0..<800 {
        let source = pids[next(pids.count)]; let target = pids[next(pids.count)]
        let now = iteration.isMultiple(of: 3) ? ProcessInfo.processInfo.systemUptime : times[next(times.count)]
        let token = ApplicationActionToken(sourcePID: source, targetPID: target, now: now)
        let reference = ReferenceApplicationActionToken(sourcePID: source, targetPID: target, now: now)
        for _ in 0..<100 {
            let pid = pids[next(pids.count)] ?? 0
            switch next(6) {
            case 0: token.setTarget(pid); reference.setTarget(pid)
            case 1: #expect(token.acceptsActivation(of: pid) == reference.acceptsActivation(of: pid))
            case 2: token.cancel(); reference.cancel()
            case 3:
                let sample = times[next(times.count)]
                #expect(token.isActive(now: sample) == reference.isActive(now: sample))
            case 4:
                let foreground = pids[next(pids.count)]
                #expect(token.canSend(to: pid, frontmostPID: foreground) == reference.canSend(to: pid, frontmostPID: foreground))
            default:
                #expect(token.isActive(now: now + 15) == reference.isActive(now: now + 15))
                #expect(token.isActive(now: now + 14.999) == reference.isActive(now: now + 14.999))
            }
        }
    }
}

@Test("Rust 动作管理连续替换、输入中断和激活事件保留旧代际与所有令牌状态")
func rustIntentManagerMatchesFrozenNativeTransitions() {
    var seed: UInt64 = 718
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    let pids: [Int32?] = [nil, 0, 1, 2, -1, .min, .max]
    for _ in 0..<100 {
        let intent = ApplicationIntent(); let reference = ReferenceApplicationIntent()
        var tokens: [(ApplicationActionToken, ReferenceApplicationActionToken)] = []
        var leases: [(WindowMoveLease, ReferenceWindowMoveLease)] = []
        for _ in 0..<80 {
            switch next(4) {
            case 0:
                let source = pids[next(pids.count)], target = pids[next(pids.count)]
                let token = intent.begin(sourcePID: source, targetPID: target)
                let original = reference.begin(sourcePID: source, targetPID: target)
                tokens.append((token, original))
                leases.append((WindowMoveLease(now: 0, duration: 1, action: token), ReferenceWindowMoveLease(now: 0, duration: 1, action: original)))
            case 1: intent.interrupt(); reference.interrupt()
            case 2:
                let pid = pids[next(pids.count)] ?? 0
                intent.applicationActivated(pid: pid); reference.applicationActivated(pid: pid)
            default:
                if !tokens.isEmpty {
                    let index = next(tokens.count); let pid = pids[next(pids.count)] ?? 0
                    tokens[index].0.setTarget(pid); tokens[index].1.setTarget(pid)
                    if next(2) == 0 { leases[index].0.cancel(); leases[index].1.cancel() }
                }
            }
            #expect(intent.revision == reference.revision)
            for (token, original) in tokens { #expect(token.isActive(now: 0) == original.isActive(now: 0)) }
            for (lease, original) in leases { #expect(lease.isActive(now: 0) == original.isActive(now: 0)) }
        }
    }
}

@Test("Rust 窗口动作租约保留 IEEE 时间、精确截止和父动作取消语义")
func rustWindowLeaseMatchesFrozenNativeDeadline() {
    let values: [Double] = [-.infinity, .infinity, .nan, -0.0, 0, -1, 0.35, 10, .greatestFiniteMagnitude]
    for now in values {
        for duration in values {
            let token = ApplicationActionToken(sourcePID: nil, now: now)
            let oldToken = ReferenceApplicationActionToken(sourcePID: nil, now: now)
            let lease = WindowMoveLease(now: now, duration: duration, action: token)
            let reference = ReferenceWindowMoveLease(now: now, duration: duration, action: oldToken)
            #expect(lease.deadline.isNaN ? reference.deadline.isNaN : lease.deadline == reference.deadline)
            for sample in values + [lease.deadline, lease.deadline - 0.001] {
                #expect(lease.isActive(now: sample) == reference.isActive(now: sample))
            }
            token.cancel(); oldToken.cancel()
            #expect(!lease.isActive(now: -.infinity) && !reference.isActive(now: -.infinity))
            lease.cancel(); reference.cancel()
            #expect(!lease.isActive(now: now) && !reference.isActive(now: now))
        }
    }
}

private final class CapturedActionTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ApplicationActionToken] = []
    func append(_ token: ApplicationActionToken) { lock.withLock { values.append(token) } }
    var snapshot: [ApplicationActionToken] { lock.withLock { values } }
}

@Test("事件线程与 AX 队列并发中断后，所有已发放令牌与租约失效")
func rustActionCancellationAcrossConcurrentNativeLocks() {
    let intent = ApplicationIntent()
    let captured = CapturedActionTokens()
    DispatchQueue.concurrentPerform(iterations: 500) { index in
        captured.append(intent.begin(sourcePID: Int32(index), targetPID: Int32(index + 1)))
        intent.interrupt()
    }
    intent.interrupt()
    #expect(intent.revision == 501)
    #expect(captured.snapshot.count == 500)
    #expect(captured.snapshot.allSatisfy { !$0.isActive() })
    let token = ApplicationActionToken(sourcePID: 1, targetPID: 2)
    let lease = WindowMoveLease(action: token)
    DispatchQueue.concurrentPerform(iterations: 1000) { index in
        switch index % 5 {
        case 0: token.setTarget(Int32(index))
        case 1: _ = token.acceptsActivation(of: Int32(index))
        case 2: _ = token.canSend(to: 2, frontmostPID: 2)
        case 3: token.cancel()
        default: _ = lease.isActive()
        }
    }
    token.setTarget(2)
    #expect(!token.isActive() && !token.canSend(to: 2, frontmostPID: 2) && !lease.isActive())
}
