import SharedSupport
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
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false, suite: AppEnvironment.appDefaults)
    static let hideDynamicIslandFromScreenCapture = Key<Bool>(
        "hideDynamicIslandFromScreenCapture",
        default: false,
        suite: AppEnvironment.appDefaults
    )

    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3, suite: AppEnvironment.appDefaults)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true, suite: AppEnvironment.appDefaults)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true, suite: AppEnvironment.appDefaults)
    static let externalDisplayStyle = Key<ExternalDisplayStyle>("externalDisplayStyle", default: .notch, suite: AppEnvironment.appDefaults)
    static let hideNonNotchUntilHover = Key<Bool>("hideNonNotchUntilHover", default: false, suite: AppEnvironment.appDefaults)
    static let notchHeightMode = Key<WindowHeightMode>("notchHeightMode", default: .matchRealNotchSize, suite: AppEnvironment.appDefaults)
    static let nonNotchHeightMode = Key<WindowHeightMode>("nonNotchHeightMode", default: .matchMenuBar, suite: AppEnvironment.appDefaults)
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32, suite: AppEnvironment.appDefaults)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32, suite: AppEnvironment.appDefaults)
    static let openNotchWidth = Key<CGFloat>("openNotchWidth", default: 690, suite: AppEnvironment.appDefaults)

    static let accentColor = Key<Color>("accentColor", default: .blue, suite: AppEnvironment.appDefaults)
    static let enableShadow = Key<Bool>("enableShadow", default: true, suite: AppEnvironment.appDefaults)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true, suite: AppEnvironment.appDefaults)
    static let useModernCloseAnimation = Key<Bool>("useModernCloseAnimation", default: true, suite: AppEnvironment.appDefaults)
    static let enableMinimalisticUI = Key<Bool>("enableMinimalisticUI", default: false, suite: AppEnvironment.appDefaults)

    static let enableGestures = Key<Bool>("enableGestures", default: false, suite: AppEnvironment.appDefaults)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true, suite: AppEnvironment.appDefaults)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200, suite: AppEnvironment.appDefaults)
    static let reverseScrollGestures = Key<Bool>("reverseScrollGestures", default: false, suite: AppEnvironment.appDefaults)
    static let enableFullscreenMediaDetection = Key<Bool>("enableFullscreenMediaDetection", default: true, suite: AppEnvironment.appDefaults)

    static let enableTimerFeature = Key<Bool>("enableTimerFeature", default: true, suite: AppEnvironment.appDefaults)
    static let timerDisplayMode = Key<TimerDisplayMode>("timerDisplayMode", default: .tab, suite: AppEnvironment.appDefaults)
    static let timerPresets = Key<[TimerPreset]>("timerPresets", default: TimerPreset.defaultPresets, suite: AppEnvironment.appDefaults)
    static let showTimerPresetsInNotchTab = Key<Bool>("showTimerPresetsInNotchTab", default: true, suite: AppEnvironment.appDefaults)
    static let timerIconColorMode = Key<TimerIconColorMode>("timerIconColorMode", default: .adaptive, suite: AppEnvironment.appDefaults)
    static let timerSolidColor = Key<Color>("timerSolidColor", default: .blue, suite: AppEnvironment.appDefaults)
    static let timerShowsCountdown = Key<Bool>("timerShowsCountdown", default: true, suite: AppEnvironment.appDefaults)
    static let timerShowsProgress = Key<Bool>("timerShowsProgress", default: true, suite: AppEnvironment.appDefaults)
    static let timerProgressStyle = Key<TimerProgressStyle>("timerProgressStyle", default: .bar, suite: AppEnvironment.appDefaults)
    static let mirrorSystemTimer = Key<Bool>("mirrorSystemTimer", default: true, suite: AppEnvironment.appDefaults)
    static let timerControlWindowEnabled = Key<Bool>("timerControlWindowEnabled", default: false, suite: AppEnvironment.appDefaults)
    static let showRealtimeClock = Key<Bool>("showRealtimeClock", default: false, suite: AppEnvironment.appDefaults)

    static let eyeCareEnabled = Key<Bool>("eyeCareEnabled", default: true, suite: AppEnvironment.appDefaults)
    static let eyeCareWorkDuration = Key<Double>("eyeCareWorkDuration", default: 20 * 60, suite: AppEnvironment.appDefaults)
    static let eyeCareRestDuration = Key<Double>("eyeCareRestDuration", default: 20, suite: AppEnvironment.appDefaults)

    static let enableLockScreenTimerWidget = Key<Bool>("enableLockScreenTimerWidget", default: true, suite: AppEnvironment.appDefaults)
    static let lockScreenTimerVerticalOffset = Key<Double>("lockScreenTimerVerticalOffset", default: 0, suite: AppEnvironment.appDefaults)
    static let lockScreenTimerWidgetWidth = Key<Double>("lockScreenTimerWidgetWidth", default: 350, suite: AppEnvironment.appDefaults)
    static let lockScreenTimerGlassStyle = Key<LockScreenGlassStyle>(
        "lockScreenTimerGlassStyle",
        default: .frosted,
        suite: AppEnvironment.appDefaults
    )
    static let lockScreenTimerGlassCustomizationMode = Key<LockScreenGlassCustomizationMode>(
        "lockScreenTimerGlassCustomizationMode",
        default: .standard,
        suite: AppEnvironment.appDefaults
    )
    static let lockScreenTimerLiquidGlassVariant = Key<LiquidGlassVariant>(
        "lockScreenTimerLiquidGlassVariant",
        default: .defaultVariant,
        suite: AppEnvironment.appDefaults
    )
    static let lockScreenTimerWidgetUsesBlur = Key<Bool>("lockScreenTimerWidgetUsesBlur", default: false, suite: AppEnvironment.appDefaults)
}
