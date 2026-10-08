/*
 * Aether
 * Copyright (C) 2026 Li Yuan
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import SharedSupport
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum BackgroundMode: String, CaseIterable {
    case imageToWindow, windowToImage
    var title: String { self == .imageToWindow ? "图片向窗口对齐" : "窗口向图片对齐" }
}
enum BackgroundFit: String, CaseIterable {
    case fill, contain, stretch
    var title: String {
        switch self { case .fill: return "铺满裁切"; case .contain: return "完整显示"; case .stretch: return "拉伸" }
    }
}
enum BackgroundAnchor: Int, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var title: String { ["左上", "上", "右上", "左", "居中", "右", "左下", "下", "右下"][rawValue] }
    var alignment: Alignment {
        [.topLeading, .top, .topTrailing, .leading, .center, .trailing, .bottomLeading, .bottom, .bottomTrailing][rawValue]
    }
    var fraction: CGPoint { CGPoint(x: CGFloat(rawValue % 3) / 2, y: CGFloat(rawValue / 3) / 2) }
}
struct BackgroundSettings: Equatable {
    var fileName: String = ""
    var mode: BackgroundMode = .imageToWindow
    var fit: BackgroundFit = .fill
    var anchor: BackgroundAnchor = .center
    var opacity: Double = 1
    init() {}
    init(defaults: UserDefaults) {
        let name = defaults.string(forKey: "backgroundFile") ?? ""
        fileName = name == (name as NSString).lastPathComponent && !name.hasPrefix(".") ? name : ""
        mode = BackgroundMode(rawValue: defaults.string(forKey: "backgroundMode") ?? "") ?? .imageToWindow
        fit = BackgroundFit(rawValue: defaults.string(forKey: "backgroundFit") ?? "") ?? .fill
        anchor = BackgroundAnchor(rawValue: defaults.object(forKey: "backgroundAnchor") as? Int ?? 4) ?? .center
        let value = defaults.object(forKey: "backgroundOpacity") as? Double ?? 1
        opacity = value.isFinite ? min(max(value, 0), 1) : 1
    }
    func save(to defaults: UserDefaults) {
        defaults.set(fileName, forKey: "backgroundFile")
        defaults.set(mode.rawValue, forKey: "backgroundMode")
        defaults.set(fit.rawValue, forKey: "backgroundFit")
        defaults.set(anchor.rawValue, forKey: "backgroundAnchor")
        defaults.set(opacity, forKey: "backgroundOpacity")
    }
}
enum BackgroundGeometry {
    static func windowSize(base: CGSize, image: CGSize?, visible: CGSize, minimumWidth: CGFloat = 1_120) -> CGSize {
        guard let image, image.width > 0, image.height > 0 else { return base }
        let maxW = visible.width * 0.94, maxH = visible.height * 0.94
        let width = base.width, height = width * image.height / image.width
        let scale = min(1, maxW / width, maxH / height)
        return CGSize(width: min(maxW, max(min(minimumWidth, maxW), width * scale)),
                      height: min(maxH, max(min(580, maxH), height * scale)))
    }
    static func imageRect(image: CGSize, container: CGSize, fit: BackgroundFit, anchor: BackgroundAnchor) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        if fit == .stretch { return CGRect(origin: .zero, size: container) }
        let ratios = (container.width / image.width, container.height / image.height)
        let scale = fit == .fill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) * anchor.fraction.x,
                      y: (container.height - size.height) * anchor.fraction.y, width: size.width, height: size.height)
    }
}
struct BackgroundPayload {
    let image: NSImage
    let size: CGSize
}
extension ClipboardImageDecodeQueue {
    func background(from url: URL, maxPixels: Int) throws -> BackgroundPayload {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary) else { throw BackgroundError.invalidImage }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return BackgroundPayload(image: NSImage(cgImage: image, size: size), size: size)
    }
    func importBackground(from source: URL, directory: URL, maxPixels: Int) throws -> (String, BackgroundPayload) {
        // Copy first, then validate exactly the bytes that will become the managed resource.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent(name)
        do {
            try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic)
            return (name, try background(from: destination, maxPixels: maxPixels))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    func removeBackground(_ name: String, directory: URL) {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
enum BackgroundError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "无法读取背景图片。请选择有效的静态 PNG、JPEG、HEIC 或 TIFF 图片。" }
}
@MainActor
final class BackgroundManager: ObservableObject {
    static let shared = BackgroundManager()
    @Published var settings: BackgroundSettings { didSet {
        settings.save(to: defaults)
        if settings.mode != oldValue.mode || settings.fileName != oldValue.fileName {
            NotificationCenter.default.post(name: .clipboardBackgroundDidChange, object: self)
        }
    } }
    @Published private(set) var payload: BackgroundPayload?
    @Published private(set) var error: String?
    @Published private(set) var importing = false
    private let defaults: UserDefaults
    let directory: URL
    private var revision = 0
    private var loadedPixels = 0
    private var loadTask: Task<Void, Never>?
    init(defaults: UserDefaults = AppEnvironment.clipboardDefaults, directory: URL = ClipboardStorage.archiveDirectory.appendingPathComponent("Backgrounds", isDirectory: true)) {
        self.defaults = defaults
        self.directory = directory
        settings = BackgroundSettings(defaults: defaults)
    }
    private var requestedPixels: Int {
        max(1, Int(NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2048))
    }
    func loadIfNeeded() {
        guard !settings.fileName.isEmpty, !importing, loadTask == nil,
              payload == nil || loadedPixels < requestedPixels else { return }
        let token = revision, name = settings.fileName, pixels = requestedPixels
        let url = directory.appendingPathComponent(name)
        loadTask = Task {
            do {
                let result = try await ClipboardImageDecodeQueue.shared.background(from: url, maxPixels: pixels)
                guard token == revision else { return }
                payload = result; loadedPixels = pixels; error = nil
            } catch {
                guard token == revision else { return }
                payload = nil; self.error = "背景图片加载失败，请重新选择图片。"
            }
            guard token == revision else { return }
            loadTask = nil
            NotificationCenter.default.post(name: .clipboardBackgroundDidChange, object: self)
        }
    }
    func importImage(_ url: URL) async {
        revision += 1
        let token = revision, pixels = requestedPixels
        loadTask?.cancel(); loadTask = nil
        importing = true; error = nil
        do {
            let (name, result) = try await ClipboardImageDecodeQueue.shared.importBackground(from: url, directory: directory, maxPixels: pixels)
            guard token == revision else {
                await ClipboardImageDecodeQueue.shared.removeBackground(name, directory: directory)
                return
            }
            let previous = settings.fileName
            payload = result; loadedPixels = pixels
            settings.fileName = name
            importing = false
            await ClipboardImageDecodeQueue.shared.removeBackground(previous, directory: directory)
        } catch {
            guard token == revision else { return }
            importing = false; self.error = "导入失败，请选择有效的静态图片，或检查文件是否可读。"
            if payload == nil { loadIfNeeded() }
        }
    }
    func removeImage() {
        revision += 1; loadTask?.cancel(); loadTask = nil
        let previous = settings.fileName
        payload = nil; loadedPixels = 0; error = nil; importing = false
        settings.fileName = ""
        Task { await ClipboardImageDecodeQueue.shared.removeBackground(previous, directory: directory) }
    }
}
extension Notification.Name {
    static let clipboardBackgroundDidChange = Notification.Name("clipboardBackgroundDidChange")
}
struct ClipboardBackgroundView: View {
    @ObservedObject private var manager = BackgroundManager.shared
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ClipboardVisualEffectView()
                if let payload = manager.payload {
                    let fit: BackgroundFit = manager.settings.mode == .windowToImage ? .fill : manager.settings.fit
                    let rect = BackgroundGeometry.imageRect(image: payload.size, container: geometry.size, fit: fit, anchor: manager.settings.anchor)
                    Image(nsImage: payload.image).resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .opacity(manager.settings.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { manager.loadIfNeeded() }
    }
}
struct BackgroundSettingsView: View {
    @ObservedObject private var manager = BackgroundManager.shared
    var body: some View {
        SettingsGroup("背景图片") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("当前图片", value: manager.settings.fileName.isEmpty ? "未设置" : manager.settings.fileName)
                GeometryReader { geometry in
                    let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
                    let base = CGSize(width: min(max(screenSize.width * 0.76, 1_120), min(screenSize.width * 0.94, 1_380)),
                                      height: min(max(screenSize.height * 0.78, 580), screenSize.height * 0.94))
                    let window = BackgroundGeometry.windowSize(
                        base: base,
                        image: manager.settings.mode == .windowToImage ? manager.payload?.size : nil,
                        visible: screenSize
                    )
                    let scale = min(geometry.size.width / window.width, geometry.size.height / window.height)
                    ClipboardBackgroundView()
                        .frame(width: window.width * scale, height: window.height * scale)
                        .overlay {
                            Text("剪贴板内容预览").padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(height: 84)
                HStack {
                    Button(manager.settings.fileName.isEmpty ? "选择图片…" : "更换图片…") { chooseImage() }
                    Button("移除") { manager.removeImage() }.disabled(manager.settings.fileName.isEmpty && !manager.importing)
                    if manager.importing { ProgressView().controlSize(.small) }
                }
                DisclosureGroup("调整图片显示") {
                Picker("适配模式", selection: $manager.settings.mode) {
                    ForEach(BackgroundMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if manager.settings.mode == .imageToWindow {
                    Picker("图片缩放", selection: $manager.settings.fit) {
                        ForEach(BackgroundFit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } else {
                    Text("窗口随图片比例调整；极端比例优先保证列表和详情可用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("位置对齐")
                    Spacer()
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(54)), count: 3), spacing: 4) {
                        ForEach(BackgroundAnchor.allCases, id: \.self) { anchor in
                            Button { manager.settings.anchor = anchor } label: {
                                Text(anchor.title).frame(width: 46, height: 22)
                            }.tint(manager.settings.anchor == anchor ? .accentColor : .secondary)
                                .buttonStyle(.bordered)
                                .accessibilityValue(manager.settings.anchor == anchor ? "已选中" : "未选中")
                        }
                    }.disabled(manager.settings.mode == .imageToWindow && manager.settings.fit == .stretch)
                }
                HStack {
                    Text("图片透明度")
                    Slider(value: Binding(get: { 1 - manager.settings.opacity }, set: { manager.settings.opacity = 1 - $0 }), in: 0...1)
                    Text("\(Int(((1 - manager.settings.opacity) * 100).rounded()))%")
                        .monospacedDigit().frame(width: 44)
                }
                Text("0% 完全可见，100% 完全透明；文字和按钮保持清晰。")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let error = manager.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await manager.importImage(url) }
        }
    }
}
