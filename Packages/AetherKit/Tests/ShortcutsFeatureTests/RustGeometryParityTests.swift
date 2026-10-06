// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
@testable import ShortcutsFeature

@Test func rustGeometryMatchesOriginalAcrossGeneratedDisplaysAndCollisions() {
    var seed: UInt64 = 19
    func next(_ limit: Int) -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1
        return CGFloat((seed >> 32) % UInt64(limit))
    }
    func rect() -> CGRect {
        CGRect(x: next(8000) - 4000, y: next(6000) - 3000, width: next(2400), height: next(1800))
    }
    for _ in 0..<1_000 {
        let window = rect(), source = rect(), target = rect()
        for resizable in [true, false] {
            let actual = WindowPlacement.destination(for: window, source: source, target: target, resizable: resizable)
            let expected = ReferenceWindowPlacement.destination(for: window, source: source, target: target, resizable: resizable)
            #expect(abs(actual.minX - expected.minX) < 0.000001)
            #expect(abs(actual.minY - expected.minY) < 0.000001)
            #expect(actual.size == expected.size)
        }
        let screens = (0..<4).map { PlacementScreen(id: UInt32($0), frame: rect(), visibleFrame: .zero) }
        #expect(WindowPlacement.source(for: window, screens: screens)?.id == ReferenceWindowPlacement.source(for: window, screens: screens)?.id)
        let occupied = [window] + (0..<5).map { _ in rect() }
        #expect(WindowPlacement.avoidingOverlap(window, occupied: occupied, within: target)
            == ReferenceWindowPlacement.avoidingOverlap(window, occupied: occupied, within: target))
    }
    let duplicateScreens = (0..<4).map { PlacementScreen(id: UInt32($0), frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: .zero) }
    #expect(WindowPlacement.source(for: .zero, screens: duplicateScreens)?.id == ReferenceWindowPlacement.source(for: .zero, screens: duplicateScreens)?.id)
}

enum ReferenceWindowPlacement {
    static func quartzRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func source(for window: CGRect, screens: [PlacementScreen]) -> PlacementScreen? {
        screens.max { lhs, rhs in
            func area(_ screen: PlacementScreen) -> CGFloat {
                let intersection = window.intersection(screen.frame)
                return intersection.isNull ? 0 : intersection.width * intersection.height
            }
            let a = area(lhs), b = area(rhs)
            if a != b { return a < b }
            func distance(_ screen: PlacementScreen) -> CGFloat {
                pow(window.midX - screen.frame.midX, 2) + pow(window.midY - screen.frame.midY, 2)
            }
            return distance(lhs) > distance(rhs)
        }
    }

    static func destination(for window: CGRect, source: CGRect, target: CGRect, resizable: Bool) -> CGRect {
        let size = resizable
            ? CGSize(width: min(window.width, target.width), height: min(window.height, target.height))
            : window.size
        func position(_ value: CGFloat, _ sourceStart: CGFloat, _ sourceLength: CGFloat,
                      _ targetStart: CGFloat, _ targetLength: CGFloat, _ windowLength: CGFloat) -> CGFloat {
            let relative = (value - sourceStart) / max(sourceLength, 1)
            return min(max(targetStart + relative * targetLength, targetStart),
                       targetStart + max(0, targetLength - windowLength))
        }
        return CGRect(x: position(window.minX, source.minX, source.width, target.minX, target.width, size.width),
                      y: position(window.minY, source.minY, source.height, target.minY, target.height, size.height),
                      width: size.width, height: size.height)
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3
            && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
    }

    /// Preserve existing target-screen windows and stagger exact collisions.
    static func avoidingOverlap(_ frame: CGRect, occupied: [CGRect], within bounds: CGRect) -> CGRect {
        func collides(_ candidate: CGRect) -> Bool {
            occupied.contains { abs($0.minX - candidate.minX) < 20 && abs($0.minY - candidate.minY) < 20 }
        }
        if !collides(frame) { return frame }
        for distance in 1...12 {
            for direction in [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: 1)] {
                let offset = CGFloat(distance * 28)
                let candidate = CGRect(x: frame.minX + direction.x * offset,
                                       y: frame.minY + direction.y * offset,
                                       width: frame.width, height: frame.height)
                if bounds.contains(candidate), !collides(candidate) { return candidate }
            }
        }
        return frame // No space: do not shrink or move existing windows to manufacture room.
    }
}

