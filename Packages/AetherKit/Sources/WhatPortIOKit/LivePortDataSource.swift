// Derived from WhatPort (MIT). Aether adaptation: serialize reads and teardown,
// bound snapshot buffering, and give each visibility session a single lifetime.
import Foundation
import WhatPortCore
import os

private let samplingLog = Logger(subsystem: "com.liyuan.aether", category: "PortSampling")

public final class LivePortDataSource: @unchecked Sendable, PortDataSource {
    // Shared across successive sources so old teardown precedes new reads.
    private static let readerQueue = DispatchQueue(label: "com.liyuan.aether.ports.reader", qos: .utility)
    private let queue = LivePortDataSource.readerQueue
    private let notifier = PortNotifier()
    private let smc = SMCPowerReader()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var ended = false
    private var snapshots: AsyncStream<PortSnapshot>.Continuation?
    private var lifecycle: AsyncStream<RawPortLifecycleEvent>.Continuation?

    public init() {}

    public func observePortUpdates() -> AsyncStream<PortSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            queue.async { [self] in
                if ended { continuation.finish() } else { snapshots = continuation }
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func observeLifecycleEvents() -> AsyncStream<RawPortLifecycleEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            queue.async { [self] in
                if ended { continuation.finish() } else { lifecycle = continuation }
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func start() async {
        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { completion.resume() }
                guard !running, !ended else { return }
                running = true
                samplingLog.debug("Sampling started")
                smc.open()
                read()
                notifier.start(onChange: { [weak self] in
                    guard let self else { return }
                    self.queue.async { [weak self] in self?.read() }
                }, onLifecycleEvent: { [weak self] event in
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        guard let self, self.running else { return }
                        self.lifecycle?.yield(event)
                    }
                })
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.read() }
                self.timer = timer
                timer.resume()
            }
        }
    }

    public func handleWake() { queue.async { [weak self] in self?.read() } }

    public func stop() {
        queue.async { [self] in
            guard !ended else { return }
            ended = true
            running = false
            samplingLog.debug("Sampling stopped")
            timer?.cancel()
            timer = nil
            notifier.stop()
            smc.close()
            snapshots?.finish()
            lifecycle?.finish()
            snapshots = nil
            lifecycle = nil
        }
    }

    private func read() {
        guard running, !ended else { return }
        snapshots?.yield(SnapshotReader.takeSnapshot(smc: smc))
    }
}
