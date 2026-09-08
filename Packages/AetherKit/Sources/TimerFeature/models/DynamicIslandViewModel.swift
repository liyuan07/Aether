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

import Combine
import Defaults
import SwiftUI

@MainActor
final class DynamicIslandViewModel: NSObject, ObservableObject {
    @Published private(set) var notchState: NotchState = .closed
    @Published var hideOnClosed = false
    @Published var screen: String?
    @Published var notchSize: CGSize
    @Published var closedNotchSize: CGSize

    private var cancellables = Set<AnyCancellable>()

    init(screen: String? = nil) {
        self.screen = screen
        let closedSize = getClosedNotchSize(screen: screen)
        notchSize = closedSize
        closedNotchSize = closedSize
        super.init()
        setupFullscreenObserver()
    }

    var effectiveClosedNotchHeight: CGFloat {
        let selectedScreen = NSScreen.screens.first { $0.localizedName == screen }
        let noNotchAndFullscreen = hideOnClosed
            && (selectedScreen?.safeAreaInsets.top ?? 0 <= 0 || selectedScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    func close() {
        let targetSize = getClosedNotchSize(screen: screen)
        notchSize = targetSize
        closedNotchSize = targetSize
        notchState = .closed
    }

    func closeForLockScreen() {
        withAnimation(.none) { close() }
    }

    private func setupFullscreenObserver() {
        let enabled = Defaults.publisher(.enableFullscreenMediaDetection)
            .map(\.newValue)

        let status = $screen
            .compactMap { $0 }
            .removeDuplicates()
            .map { screenName in
                FullscreenMediaDetector.shared.$fullscreenStatus
                    .map { $0[screenName] ?? false }
                    .removeDuplicates()
            }
            .switchToLatest()

        Publishers.CombineLatest(status, enabled)
            .map { isFullscreen, isEnabled in isEnabled && isFullscreen }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }
}
