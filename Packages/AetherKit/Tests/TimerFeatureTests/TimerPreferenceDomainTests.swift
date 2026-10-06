// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Defaults
import SharedSupport
@testable import TimerFeature

final class TimerPreferenceDomainTests: XCTestCase {
    func testAllTimerKeysUseTheApplicationEnvironmentDomain() {
        let keys: [Defaults._AnyKey] = [
            Defaults.Keys.showOnAllDisplays,
            Defaults.Keys.hideDynamicIslandFromScreenCapture,
            Defaults.Keys.minimumHoverDuration,
            Defaults.Keys.enableHaptics,
            Defaults.Keys.openNotchOnHover,
            Defaults.Keys.externalDisplayStyle,
            Defaults.Keys.hideNonNotchUntilHover,
            Defaults.Keys.notchHeightMode,
            Defaults.Keys.nonNotchHeightMode,
            Defaults.Keys.nonNotchHeight,
            Defaults.Keys.notchHeight,
            Defaults.Keys.openNotchWidth,
            Defaults.Keys.accentColor,
            Defaults.Keys.enableShadow,
            Defaults.Keys.cornerRadiusScaling,
            Defaults.Keys.useModernCloseAnimation,
            Defaults.Keys.enableMinimalisticUI,
            Defaults.Keys.enableGestures,
            Defaults.Keys.closeGestureEnabled,
            Defaults.Keys.gestureSensitivity,
            Defaults.Keys.reverseScrollGestures,
            Defaults.Keys.enableFullscreenMediaDetection,
            Defaults.Keys.enableTimerFeature,
            Defaults.Keys.timerDisplayMode,
            Defaults.Keys.timerPresets,
            Defaults.Keys.showTimerPresetsInNotchTab,
            Defaults.Keys.timerIconColorMode,
            Defaults.Keys.timerSolidColor,
            Defaults.Keys.timerShowsCountdown,
            Defaults.Keys.timerShowsProgress,
            Defaults.Keys.timerProgressStyle,
            Defaults.Keys.mirrorSystemTimer,
            Defaults.Keys.timerControlWindowEnabled,
            Defaults.Keys.showRealtimeClock,
            Defaults.Keys.eyeCareEnabled,
            Defaults.Keys.eyeCareWorkDuration,
            Defaults.Keys.eyeCareRestDuration,
            Defaults.Keys.enableLockScreenTimerWidget,
            Defaults.Keys.lockScreenTimerVerticalOffset,
            Defaults.Keys.lockScreenTimerWidgetWidth,
            Defaults.Keys.lockScreenTimerGlassStyle,
            Defaults.Keys.lockScreenTimerGlassCustomizationMode,
            Defaults.Keys.lockScreenTimerLiquidGlassVariant,
            Defaults.Keys.lockScreenTimerWidgetUsesBlur
        ]
        XCTAssertEqual(keys.count, 44)
        XCTAssertEqual(Set(keys.map(\.name)).count, keys.count)
        for key in keys { XCTAssertTrue(key.suite === AppEnvironment.appDefaults, key.name) }
    }

    func testTypedAndNativePreferenceAccessShareTheIsolatedDomain() {
        let name = "AetherSuiteProbe-" + UUID().uuidString
        let key = Defaults.Key<Double>(name, default: 0, suite: AppEnvironment.appDefaults)
        defer { AppEnvironment.appDefaults.removeObject(forKey: name) }
        Defaults[key] = 1.25
        XCTAssertEqual(AppEnvironment.appDefaults.double(forKey: name), 1.25)
        AppEnvironment.appDefaults.set(3.5, forKey: name)
        XCTAssertEqual(Defaults[key], 3.5)
        // Defaults registers a process-shared fallback of 0. Persistent writes
        // to the application suite must not propagate to these feature suites.
        XCTAssertEqual(AppEnvironment.clipboardDefaults.double(forKey: name), 0)
        XCTAssertEqual(AppEnvironment.shortcutsDefaults.double(forKey: name), 0)
        XCTAssertEqual(AppEnvironment.controlCenterDefaults.double(forKey: name), 0)
    }
}
