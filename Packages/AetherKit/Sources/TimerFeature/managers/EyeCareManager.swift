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

import Combine
import Defaults
import Foundation

@MainActor
final class EyeCareManager: ObservableObject {
    static let shared = EyeCareManager()

    static let workDurationRange: ClosedRange<TimeInterval> = 5 * 60...60 * 60
    static let restDurationRange: ClosedRange<TimeInterval> = 20...300

    @Published private(set) var state: EyeCareCycleState = .stopped
    @Published private(set) var message: String?
    @Published private(set) var displayDate = Date()

    private var machine = EyeCareCycleMachine()
    private var deadlineTimer: Timer?
    private var panelDisplayTimer: Timer?
    private var breakWindowRecoveryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        Defaults.publisher(.eyeCareEnabled, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard !change.newValue else { return }
                Task { @MainActor in
                    self?.stop()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        deadlineTimer?.invalidate()
        panelDisplayTimer?.invalidate()
        breakWindowRecoveryTask?.cancel()
    }

    var isActive: Bool { machine.isActive }
    var isPaused: Bool { machine.isPaused }
    var isBreakVisible: Bool { machine.isBreakVisible }
    var canCompleteRest: Bool { machine.canCompleteRest }

    var workDuration: TimeInterval {
        Self.clamp(Defaults[.eyeCareWorkDuration], to: Self.workDurationRange)
    }

    var restDuration: TimeInterval {
        Self.clamp(Defaults[.eyeCareRestDuration], to: Self.restDurationRange)
    }

    @discardableResult
    func start(now: Date = Date()) -> Bool {
        guard Defaults[.eyeCareEnabled] else {
            message = "请先在设置中开启护眼提醒"
            return false
        }
        guard !TimerManager.shared.isExternalTimerActive,
              !SystemTimerBridge.shared.hasObservedActiveSystemTimer else {
            message = "macOS“时钟”计时器正在运行，无法由本应用暂停。请先停止系统计时器。"
            return false
        }

        pauseManualTimerIfNeeded()
        message = nil
        machine.start(workDuration: workDuration, now: now)
        publishAndSchedule()
        AppRouter.shared.send(.dismissPanels)
        return true
    }

    func pause(now: Date = Date()) {
        guard machine.pause(reason: .user, now: now) else { return }
        message = nil
        publishAndSchedule()
    }

    @discardableResult
    func resume(now: Date = Date()) -> Bool {
        guard !TimerManager.shared.isExternalTimerActive,
              !SystemTimerBridge.shared.hasObservedActiveSystemTimer else {
            message = "macOS“时钟”计时器正在运行，无法由本应用暂停。请先停止系统计时器。"
            return false
        }

        pauseManualTimerIfNeeded()
        guard machine.resume(now: now) else { return false }
        message = nil
        publishAndSchedule()
        AppRouter.shared.send(.dismissPanels)
        return true
    }

    func stop() {
        machine.stop()
        message = nil
        publishAndSchedule()
    }

    @discardableResult
    func completeRest(now: Date = Date()) -> Bool {
        guard machine.completeRest(workDuration: workDuration, now: now) else { return false }
        message = nil
        publishAndSchedule()
        return true
    }

    func pauseForTimerConflict(isExternal: Bool = false, now: Date = Date()) {
        guard machine.pause(reason: .timerConflict, now: now) else { return }
        message = isExternal
            ? "macOS“时钟”计时器已启动，护眼循环已暂停"
            : "普通倒计时已启动，护眼循环已暂停"
        publishAndSchedule()
    }

    func handleAway(now: Date = Date()) {
        guard machine.beginAway(now: now) else { return }
        publishAndSchedule()
    }

    func handleReturn(now: Date = Date()) {
        guard machine.returnFromAway(
            now: now,
            workDuration: workDuration,
            restThreshold: restDuration
        ) else { return }
        publishAndSchedule()
    }

    func remainingTime(at date: Date = Date()) -> TimeInterval {
        machine.remainingTime(at: date)
    }

    func clearMessage() {
        message = nil
    }

    func beginPanelDisplayUpdates() {
        displayDate = Date()
        guard panelDisplayTimer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.displayDate = Date()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        panelDisplayTimer = timer
    }

    func endPanelDisplayUpdates() {
        panelDisplayTimer?.invalidate()
        panelDisplayTimer = nil
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(duration)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func pauseManualTimerIfNeeded() {
        let timerManager = TimerManager.shared
        guard timerManager.activeSource == .manual,
              timerManager.isTimerActive,
              !timerManager.isPaused else { return }
        timerManager.pauseTimer()
    }

    private func publishAndSchedule() {
        state = machine.state
        rescheduleDeadlineTimer()
        reconcileBreakWindow()
    }

    private func rescheduleDeadlineTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil

        let deadline: Date
        switch machine.state {
        case let .working(value), let .resting(value):
            deadline = value
        default:
            return
        }

        let fireDate = max(deadline, Date())
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.deadlineReached()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func deadlineReached(now: Date = Date()) {
        _ = machine.advanceIfNeeded(now: now, restDuration: restDuration)
        publishAndSchedule()
    }

    private func reconcileBreakWindow() {
        if machine.isBreakVisible, !LockScreenManager.shared.currentLockStatus {
            AppRouter.shared.send(.dismissPanels)
            presentBreakWindow()
            scheduleBreakWindowRecovery()
        } else {
            breakWindowRecoveryTask?.cancel()
            breakWindowRecoveryTask = nil
            EyeCareBreakWindowManager.shared.hide()
        }
    }

    private func presentBreakWindow() {
        EyeCareBreakWindowManager.shared.present(
            preferredScreenName: TimerRuntime.shared?.vm.screen
        )
    }

    /// A transient popover close or display-space transition can cause AppKit to drop a
    /// non-activating panel's first order-front request. The break state is persistent, so
    /// reassert its panel shortly afterwards instead of treating that one request as final.
    private func scheduleBreakWindowRecovery() {
        breakWindowRecoveryTask?.cancel()
        breakWindowRecoveryTask = Task { @MainActor [weak self] in
            for delay in [0.2, 0.8] as [TimeInterval] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled,
                      let self,
                      self.machine.isBreakVisible,
                      !LockScreenManager.shared.currentLockStatus else {
                    return
                }
                self.presentBreakWindow()
            }
            self?.breakWindowRecoveryTask = nil
        }
    }

    private static func clamp(_ value: TimeInterval, to range: ClosedRange<TimeInterval>) -> TimeInterval {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
