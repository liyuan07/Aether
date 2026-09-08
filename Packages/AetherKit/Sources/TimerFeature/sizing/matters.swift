/*
 * package counter
 * Derived from Atoll (DynamicIsland) and boring.notch
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import CoreGraphics
import Defaults
import SwiftUI

func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
    guard let screenNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
    ] as? NSNumber else {
        return false
    }

    return CGDisplayIsBuiltin(CGDirectDisplayID(screenNumber.uint32Value)) != 0
}

var openNotchSize: CGSize {
    let width = min(max(Defaults[.openNotchWidth], 640), maxAllowedNotchWidth())
    return CGSize(width: width, height: 200)
}

func maxAllowedNotchWidth(for screenName: String? = nil) -> CGFloat {
    let screen = screenName.flatMap { name in
        NSScreen.screens.first { $0.localizedName == name }
    } ?? NSScreen.main
    guard let width = screen?.frame.width, width > 0 else { return 900 }
    return max(width - 60, 400)
}

func maxAllowedNotchWidth() -> CGFloat {
    maxAllowedNotchWidth(for: nil)
}

let minimalisticOpenNotchSize = CGSize(width: 420, height: 180)
let notchShadowPaddingStandard: CGFloat = 18
let notchShadowPaddingMinimalistic: CGFloat = 12

let cornerRadiusInsets: (
    opened: (top: CGFloat, bottom: CGFloat),
    closed: (top: CGFloat, bottom: CGFloat)
) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

let minimalisticCornerRadiusInsets: (
    opened: (top: CGFloat, bottom: CGFloat),
    closed: (top: CGFloat, bottom: CGFloat)
) = (opened: (top: 35, bottom: 35), closed: cornerRadiusInsets.closed)

func notchShadowPaddingValue(isMinimalistic: Bool) -> CGFloat {
    isMinimalistic ? notchShadowPaddingMinimalistic : notchShadowPaddingStandard
}

func addShadowPadding(to size: CGSize, isMinimalistic: Bool) -> CGSize {
    CGSize(
        width: size.width,
        height: size.height + notchShadowPaddingValue(isMinimalistic: isMinimalistic)
    )
}

func shouldUseDynamicIslandMode(for screenName: String?) -> Bool {
    guard Defaults[.externalDisplayStyle] == .dynamicIsland else { return false }
    let screen = screenName.flatMap { name in
        NSScreen.screens.first { $0.localizedName == name }
    } ?? NSScreen.main
    guard let screen else { return false }
    return screen.safeAreaInsets.top <= 0
}

let dynamicIslandPillCornerRadiusInsets: (
    opened: CGFloat,
    closed: (standard: CGFloat, minimalistic: CGFloat)
) = (opened: 24, closed: (standard: 16, minimalistic: 16))

let dynamicIslandTopOffset: CGFloat = 6
let dynamicIslandShadowInset: CGFloat = 14

enum CompactNotchLiveActivityMetrics {
    static let leadingInset: CGFloat = 6
    static let trailingInset: CGFloat = 6
    static let iconTrailingAllowance: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let countdownWidth: CGFloat = 56
}

func getScreenFrame(_ screen: String? = nil) -> CGRect? {
    if let screen {
        return NSScreen.screens.first { $0.localizedName == screen }?.frame
    }
    return NSScreen.main?.frame
}

func getClosedNotchSize(screen: String? = nil) -> CGSize {
    var notchHeight = CGFloat(Defaults[.nonNotchHeight])
    var notchWidth: CGFloat = 185
    let selectedScreen = screen.flatMap { name in
        NSScreen.screens.first { $0.localizedName == name }
    } ?? NSScreen.main

    guard let selectedScreen else {
        return CGSize(width: notchWidth, height: notchHeight)
    }

    if let left = selectedScreen.auxiliaryTopLeftArea?.width,
       let right = selectedScreen.auxiliaryTopRightArea?.width {
        notchWidth = selectedScreen.frame.width - left - right + 4
    }

    if selectedScreen.safeAreaInsets.top > 0 {
        notchHeight = CGFloat(Defaults[.notchHeight])
        switch Defaults[.notchHeightMode] {
        case .matchRealNotchSize:
            notchHeight = selectedScreen.safeAreaInsets.top
        case .matchMenuBar:
            notchHeight = selectedScreen.frame.maxY - selectedScreen.visibleFrame.maxY
        case .custom:
            break
        }
    } else {
        notchHeight = CGFloat(Defaults[.nonNotchHeight])
        if Defaults[.nonNotchHeightMode] == .matchMenuBar {
            notchHeight = selectedScreen.frame.maxY - selectedScreen.visibleFrame.maxY
        }
    }

    return CGSize(width: notchWidth, height: notchHeight)
}
