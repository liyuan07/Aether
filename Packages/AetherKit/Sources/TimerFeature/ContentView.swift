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
import Defaults
import SwiftUI

struct NotchHorizontalOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @ObservedObject private var timerManager = TimerManager.shared
    @ObservedObject private var eyeCareManager = EyeCareManager.shared
    @State private var notchHorizontalOffset: CGFloat = 0

    @Default(.enableMinimalisticUI) private var enableMinimalisticUI
    @Default(.externalDisplayStyle) private var externalDisplayStyle
    @Default(.showRealtimeClock) private var showRealtimeClock

    private var dynamicNotchSize: CGSize {
        enableMinimalisticUI ? minimalisticOpenNotchSize : openNotchSize
    }

    private var currentScreenName: String {
        vm.screen ?? NSScreen.main?.localizedName ?? ""
    }

    private var isDynamicIslandMode: Bool {
        shouldUseDynamicIslandMode(for: currentScreenName)
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: cornerRadiusInsets.closed.top,
            bottomCornerRadius: cornerRadiusInsets.closed.bottom
        )
    }

    private var currentPillShape: DynamicIslandPillShape {
        let radius = max(
            vm.effectiveClosedNotchHeight / 2,
            enableMinimalisticUI
                ? dynamicIslandPillCornerRadiusInsets.closed.minimalistic
                : dynamicIslandPillCornerRadiusInsets.closed.standard
        )
        return DynamicIslandPillShape(cornerRadius: radius)
    }

    private var resolvedClipShape: AnyShape {
        isDynamicIslandMode ? AnyShape(currentPillShape) : AnyShape(currentNotchShape)
    }

    private var shadowPadding: CGFloat {
        notchShadowPaddingValue(isMinimalistic: enableMinimalisticUI)
    }

    private var pillTopOffset: CGFloat {
        isDynamicIslandMode ? dynamicIslandTopOffset : 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchSurface
                .padding(.bottom, shadowPadding)
                .offset(x: notchHorizontalOffset)
        }
        .frame(
            maxWidth: dynamicNotchSize.width + (isDynamicIslandMode ? dynamicIslandShadowInset * 2 : 0),
            maxHeight: dynamicNotchSize.height + shadowPadding + pillTopOffset,
            alignment: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(NotchHorizontalOffsetPreferenceKey.self) { offset in
            notchHorizontalOffset = offset
        }
        .onDisappear {
            TimerInteractionPanelManager.shared.hide(animated: false)
        }
    }

    private var notchSurface: some View {
        notchContent
            .frame(alignment: .top)
            .padding(.horizontal, cornerRadiusInsets.closed.bottom)
            .background(.black)
            .clipShape(resolvedClipShape)
            .compositingGroup()
            .padding(.horizontal, isDynamicIslandMode ? dynamicIslandShadowInset : 0)
            .padding(.top, pillTopOffset)
    }

    @ViewBuilder
    private var notchContent: some View {
        if vm.hideOnClosed {
            emptyNotchContent
        } else if eyeCareManager.state.showsWorkingNotchActivity {
            EyeCareLiveActivity()
        } else if eyeCareManager.state.suppressesRetainedTimerInNotch {
            passiveNotchContent
        } else if timerManager.isTimerActive {
            TimerLiveActivity()
        } else {
            passiveNotchContent
        }
    }

    @ViewBuilder
    private var passiveNotchContent: some View {
        if showRealtimeClock {
            RealtimeClockLiveActivity()
        } else {
            emptyNotchContent
        }
    }

    private var emptyNotchContent: some View {
        Rectangle()
            .fill(.clear)
            .frame(
                width: max(0, vm.closedNotchSize.width - 20),
                height: vm.effectiveClosedNotchHeight
            )
            .preference(key: NotchHorizontalOffsetPreferenceKey.self, value: 0)
    }
}
