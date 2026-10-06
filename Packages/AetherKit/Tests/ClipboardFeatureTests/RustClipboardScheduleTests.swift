// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import CAetherCore
@testable import ClipboardFeature

final class RustClipboardScheduleTests: XCTestCase {
    func testCaptureMatchesPreviousRetryStateAcrossChangeSequences() {
        for seed in 0..<100 {
            var native = PreviousCapture(last: Int64(seed))
            var core = AetherClipboardCapture(last_change: Int64(seed), pending_change: 0, pending: 0, failures: 0, needed: 0)
            for step in 0..<300 {
                let change = Int64((step / 5 + seed) % 13 - 4)
                if step % 17 == 0 {
                    native.last = change
                    core = aether_clipboard_capture_observed(core, change)
                } else {
                    let needed = native.probe(change)
                    core = aether_clipboard_capture_probe(core, change)
                    XCTAssertEqual(core.needed != 0, needed)
                    if needed {
                        if (step + seed) % 11 == 0 {
                            native.commit(change); core = aether_clipboard_capture_committed(core, change)
                        } else { native.fail(change); core = aether_clipboard_capture_failed(core, change) }
                    }
                }
                XCTAssertEqual(core.last_change, native.last)
                XCTAssertEqual(Int(core.failures), native.failures)
                XCTAssertEqual(core.pending != 0, native.pending != nil)
                if let pending = native.pending { XCTAssertEqual(core.pending_change, pending) }
            }
        }
    }
    func testCaptureFourFailuresStopSameChangeAndNewChangeRestarts() {
        var core = AetherClipboardCapture(last_change: Int64.min, pending_change: 0, pending: 0, failures: 0, needed: 0)
        for attempt in 0..<4 {
            core = aether_clipboard_capture_probe(core, Int64.max)
            XCTAssertEqual(core.needed, 1)
            core = aether_clipboard_capture_failed(core, Int64.max)
            XCTAssertEqual(Int(core.failures), attempt == 3 ? 0 : attempt + 1)
        }
        core = aether_clipboard_capture_probe(core, Int64.max)
        XCTAssertEqual(core.needed, 0)
        core = aether_clipboard_capture_probe(core, Int64.min)
        XCTAssertEqual(core.needed, 1)
        core = aether_clipboard_capture_committed(core, Int64.min)
        XCTAssertEqual(core.last_change, Int64.min)
        XCTAssertEqual(core.pending, 0)
    }
    func testWriteCoalescingMatchesPreviousCleanupAndSchedulingState() {
        var previous = PreviousWriter(), core = AetherClipboardWriter()
        for step in 0..<10000 {
            if step % 13 == 0 || step % 17 == 0 {
                let native = previous.take()
                let rust = aether_clipboard_writer_take(core)
                XCTAssertEqual(rust.write != 0, native.write)
                XCTAssertEqual(rust.cleanup != 0, native.cleanup)
                core = rust.state
            } else {
                let cleanup = step % 7 == 0
                let scheduled = previous.enqueue(cleanup)
                core = aether_clipboard_writer_enqueue(core, cleanup ? 1 : 0)
                XCTAssertEqual(core.schedule != 0, scheduled)
            }
            XCTAssertEqual(core.pending != 0, previous.pending)
            XCTAssertEqual(core.cleanup != 0, previous.cleanup)
            XCTAssertEqual(core.scheduled != 0, previous.scheduled)
        }
    }
    func testRevisionWrapAndDailyMaintenanceKeepNativeClockSemantics() {
        var core = AetherClipboardWork(history_revision: UInt64.max, maintenance_generation: UInt64.max,
            last_maintenance: Date.distantPast.timeIntervalSinceReferenceDate)
        core = aether_clipboard_history_changed(core)
        XCTAssertEqual(core.history_revision, 0)
        XCTAssertEqual(aether_clipboard_revision_current(core, UInt64.max), 0)
        XCTAssertEqual(aether_clipboard_revision_current(core, 0), 1)
        for start in [-1e10, -1, 0, 12345, 1e10] {
            let last = Date(timeIntervalSinceReferenceDate: start)
            core = aether_clipboard_maintenance_begin(core, last.timeIntervalSinceReferenceDate)
            for delta in [-86400.0, 0, 86399.99, 86400, 86400.01, 172800] {
                let now = last.addingTimeInterval(delta)
                XCTAssertEqual(aether_clipboard_maintenance_due(core, now.timeIntervalSinceReferenceDate) != 0,
                    now.timeIntervalSince(last) >= 86400)
            }
            XCTAssertEqual(aether_clipboard_maintenance_current(core, core.maintenance_generation), 1)
            XCTAssertEqual(aether_clipboard_maintenance_current(core, core.maintenance_generation &- 1), 0)
        }
    }
    func testResourcePlanPreservesNativeCanonicalFilenameEquality() {
        let texts = ["", "a\u{301}.png", "á.png", "中文.rtf", "👨‍👩‍👧‍👦.png", "Ａ.rtf", "A.rtf", "synthetic.png", "合成\u{0000}"]
        XCTAssertEqual(rustClipboardUnreferencedResources(keeping: [], files: texts), Array(texts.indices))
        XCTAssertEqual(rustClipboardUnreferencedResources(keeping: texts, files: []), [])
        for seed in 0..<100 {
            let keeping = (0..<20).map { texts[($0 * 3 + seed) % texts.count] }
            let files = (0..<40).map { texts[($0 * 7 + seed) % texts.count] }
            let expected = files.indices.filter { !Set(keeping).contains(files[$0]) }
            XCTAssertEqual(rustClipboardUnreferencedResources(keeping: keeping, files: files), expected)
        }
    }
}

// Independent pre-migration state transitions, with no Rust calls.
private struct PreviousCapture {
    var last: Int64
    var pending: Int64?
    var failures = 0
    mutating func probe(_ count: Int64) -> Bool {
        guard count != last else { pending = nil; failures = 0; return false }
        if pending != count { pending = count; failures = 0 }
        return true
    }
    mutating func fail(_ count: Int64) {
        failures += 1
        if failures >= 4 { last = count; pending = nil; failures = 0 }
    }
    mutating func commit(_ count: Int64) { last = count; pending = nil; failures = 0 }
}
private struct PreviousWriter {
    var pending = false, cleanup = false, scheduled = false
    mutating func enqueue(_ clean: Bool) -> Bool {
        pending = true; cleanup = cleanup || clean
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    mutating func take() -> (write: Bool, cleanup: Bool) {
        let result = (pending, cleanup)
        pending = false; cleanup = false; scheduled = false
        return result
    }
}
