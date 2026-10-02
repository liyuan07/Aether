import Foundation
import SwiftUI
import WhatPortCore
import WhatPortIOKit

@MainActor final class PortsModel: ObservableObject {
    enum Surface: Hashable { case summary, details }
    @Published private(set) var manager = PortManager()
    @Published private(set) var history = PortHistory()
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var phyAvailable = false
    @Published private(set) var collecting = false
    @Published private(set) var sleeping = false
    private var applicationHidden = false
    private var surfaces: Set<Surface> = []
    private var source: (any PortDataSource)?
    private var snapshotTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var session = UUID()
    private let factory: () -> any PortDataSource

    init(factory: @escaping () -> any PortDataSource = { LivePortDataSource() }) {
        self.factory = factory
    }

    func setVisible(_ surface: Surface, _ visible: Bool) {
        if visible { surfaces.insert(surface) } else { surfaces.remove(surface) }
        reconcile()
    }

    func setSleeping(_ value: Bool) { sleeping = value; reconcile() }
    func setApplicationHidden(_ value: Bool) { applicationHidden = value; reconcile() }
    func stop() { surfaces.removeAll(); endSession() }

    private func reconcile() {
        if !surfaces.isEmpty && !sleeping && !applicationHidden {
            if !collecting { beginSession() }
        } else if collecting { endSession() }
    }

    private func beginSession() {
        let token = UUID()
        session = token
        history.prune(at: .now)
        history.breakSession()
        // Don't render an old device as the current connection while refreshing.
        manager = PortManager()
        phyAvailable = false
        lastUpdated = nil
        let source = factory()
        self.source = source
        let updates = source.observePortUpdates()
        let events = source.observeLifecycleEvents()
        collecting = true
        snapshotTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await source.start()
            for await snapshot in updates {
                guard !Task.isCancelled, let self, self.session == token else { return }
                self.phyAvailable = !snapshot.phyData.isEmpty
                self.manager.applySnapshot(SnapshotAdapter.convert(snapshot))
                self.history.append(ports: self.manager.ports, at: snapshot.timestamp)
                self.lastUpdated = snapshot.timestamp
                self.objectWillChange.send()
            }
        }
        lifecycleTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, self.session == token else { return }
                self.manager.applyLifecycleSignal(SnapshotAdapter.convert(event))
                self.objectWillChange.send()
            }
        }
    }

    private func endSession() {
        session = UUID()
        collecting = false
        source?.stop()
        source = nil
        snapshotTask?.cancel()
        lifecycleTask?.cancel()
        snapshotTask = nil
        lifecycleTask = nil
        history.breakSession()
    }
}
