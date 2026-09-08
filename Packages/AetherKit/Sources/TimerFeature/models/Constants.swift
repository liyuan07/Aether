/*
 * package counter
 * Derived from Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Defaults
import SwiftUI

enum TimerIconColorMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case adaptive = "Adaptive"
    case solid = "Solid"

    var id: String { rawValue }
}

enum TimerProgressStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case bar = "Bar"
    case ring = "Ring"

    var id: String { rawValue }
}

extension Defaults.Keys {
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let hideDynamicIslandFromScreenCapture = Key<Bool>(
        "hideDynamicIslandFromScreenCapture",
        default: false
    )

    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let externalDisplayStyle = Key<ExternalDisplayStyle>("externalDisplayStyle", default: .notch)
    static let hideNonNotchUntilHover = Key<Bool>("hideNonNotchUntilHover", default: false)
    static let notchHeightMode = Key<WindowHeightMode>("notchHeightMode", default: .matchRealNotchSize)
    static let nonNotchHeightMode = Key<WindowHeightMode>("nonNotchHeightMode", default: .matchMenuBar)
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    static let openNotchWidth = Key<CGFloat>("openNotchWidth", default: 690)

    static let accentColor = Key<Color>("accentColor", default: .blue)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)
    static let useModernCloseAnimation = Key<Bool>("useModernCloseAnimation", default: true)
    static let enableMinimalisticUI = Key<Bool>("enableMinimalisticUI", default: false)

    static let enableGestures = Key<Bool>("enableGestures", default: false)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200)
    static let reverseScrollGestures = Key<Bool>("reverseScrollGestures", default: false)
    static let enableFullscreenMediaDetection = Key<Bool>("enableFullscreenMediaDetection", default: true)

    static let enableTimerFeature = Key<Bool>("enableTimerFeature", default: true)
    static let timerDisplayMode = Key<TimerDisplayMode>("timerDisplayMode", default: .tab)
    static let timerPresets = Key<[TimerPreset]>("timerPresets", default: TimerPreset.defaultPresets)
    static let showTimerPresetsInNotchTab = Key<Bool>("showTimerPresetsInNotchTab", default: true)
    static let timerIconColorMode = Key<TimerIconColorMode>("timerIconColorMode", default: .adaptive)
    static let timerSolidColor = Key<Color>("timerSolidColor", default: .blue)
    static let timerShowsCountdown = Key<Bool>("timerShowsCountdown", default: true)
    static let timerShowsProgress = Key<Bool>("timerShowsProgress", default: true)
    static let timerProgressStyle = Key<TimerProgressStyle>("timerProgressStyle", default: .bar)
    static let mirrorSystemTimer = Key<Bool>("mirrorSystemTimer", default: true)
    static let timerControlWindowEnabled = Key<Bool>("timerControlWindowEnabled", default: false)
    static let showRealtimeClock = Key<Bool>("showRealtimeClock", default: false)

    static let eyeCareEnabled = Key<Bool>("eyeCareEnabled", default: true)
    static let eyeCareWorkDuration = Key<Double>("eyeCareWorkDuration", default: 20 * 60)
    static let eyeCareRestDuration = Key<Double>("eyeCareRestDuration", default: 20)

    static let enableLockScreenTimerWidget = Key<Bool>("enableLockScreenTimerWidget", default: true)
    static let lockScreenTimerVerticalOffset = Key<Double>("lockScreenTimerVerticalOffset", default: 0)
    static let lockScreenTimerWidgetWidth = Key<Double>("lockScreenTimerWidgetWidth", default: 350)
    static let lockScreenTimerGlassStyle = Key<LockScreenGlassStyle>(
        "lockScreenTimerGlassStyle",
        default: .frosted
    )
    static let lockScreenTimerGlassCustomizationMode = Key<LockScreenGlassCustomizationMode>(
        "lockScreenTimerGlassCustomizationMode",
        default: .standard
    )
    static let lockScreenTimerLiquidGlassVariant = Key<LiquidGlassVariant>(
        "lockScreenTimerLiquidGlassVariant",
        default: .defaultVariant
    )
    static let lockScreenTimerWidgetUsesBlur = Key<Bool>("lockScreenTimerWidgetUsesBlur", default: false)
}
