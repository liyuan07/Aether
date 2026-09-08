import AppKit
import Darwin
import ShortcutCore

@MainActor
final class InstalledApplicationCatalog {
    var onApplicationsChanged: (([RegisteredApplication]) -> Void)?

    private var directorySources: [DispatchSourceFileSystemObject] = []
    private var refreshWorkItem: DispatchWorkItem?

    func start() {
        refresh()
        stopMonitoring()
        for root in Self.applicationRoots() where FileManager.default.fileExists(atPath: root.path) {
            let descriptor = open(root.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            directorySources.append(source)
        }
    }

    func stop() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        stopMonitoring()
    }

    func refresh() {
        let roots = Self.applicationRoots()
        let excludedBundleIdentifier = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let applications = Self.scan(
                roots: roots,
                excludingBundleIdentifier: excludedBundleIdentifier
            )
            DispatchQueue.main.async { self?.onApplicationsChanged?(applications) }
        }
    }

    nonisolated static func scan(
        roots: [URL],
        excludingBundleIdentifier: String? = nil,
        fileManager: FileManager = .default
    ) -> [RegisteredApplication] {
        var applicationsByBundleIdentifier: [String: RegisteredApplication] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      bundleIdentifier != excludingBundleIdentifier
                else { continue }
                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                guard let initial = ApplicationInitialResolver.initial(for: displayName) else { continue }
                if applicationsByBundleIdentifier[bundleIdentifier] == nil {
                    applicationsByBundleIdentifier[bundleIdentifier] = RegisteredApplication(
                        bundleIdentifier: bundleIdentifier,
                        displayName: displayName,
                        applicationPath: url.path,
                        initial: initial
                    )
                }
            }
        }

        return applicationsByBundleIdentifier.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func applicationRoots(fileManager: FileManager = .default) -> [URL] {
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        roots.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true))
        roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        return roots
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func stopMonitoring() {
        directorySources.forEach { $0.cancel() }
        directorySources.removeAll()
    }
}
