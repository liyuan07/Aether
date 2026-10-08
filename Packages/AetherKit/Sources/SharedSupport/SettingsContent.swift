import SwiftUI

/// One spacing vocabulary for settings and the menu-bar workspace.
public enum AetherLayout {
    public static let pageInset: CGFloat = 20
    public static let groupSpacing: CGFloat = 16
    public static let rowHeight: CGFloat = 36
    public static let panelInset: CGFloat = 12
    public static let panelWidth: CGFloat = 360
}

/// Feature views own controls, never another window or sidebar.
public struct SettingsContent<Content: View>: View {
    private let title: String
    private let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, AetherLayout.pageInset)
                .padding(.vertical, 16)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 13))
        .controlSize(.small)
    }
}

public struct SettingsForm<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherLayout.groupSpacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AetherLayout.pageInset)
        }
        .toggleStyle(AlignedSettingsToggleStyle())
        .labeledContentStyle(AlignedSettingsLabelStyle())
    }
}

private struct AlignedSettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch)
        }.frame(minHeight: AetherLayout.rowHeight)
    }
}

private struct AlignedSettingsLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }.frame(maxWidth: .infinity, minHeight: AetherLayout.rowHeight)
    }
}

public struct SettingsGroup<Content: View>: View {
    private let header: AnyView
    private let footer: AnyView
    private let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.header = AnyView(Text(title))
        self.footer = AnyView(EmptyView())
        self.content = content()
    }
    public init(@ViewBuilder content: () -> Content) {
        self.header = AnyView(EmptyView())
        self.footer = AnyView(EmptyView())
        self.content = content()
    }
    public init<H: View>(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> H) {
        self.header = AnyView(header())
        self.footer = AnyView(EmptyView())
        self.content = content()
    }
    public init<H: View, F: View>(@ViewBuilder content: () -> Content,
                                 @ViewBuilder header: () -> H, @ViewBuilder footer: () -> F) {
        self.header = AnyView(header())
        self.footer = AnyView(footer())
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 0.5))
            footer.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

public struct SettingsRow<Content: View>: View {
    private let title: String
    private let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    public var body: some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer(minLength: 8)
            content
        }.frame(minHeight: AetherLayout.rowHeight)
    }
}

/// Keep numeric values next to their stepper instead of depending on Form label layout.
public struct SettingsStepperRow: View {
    private let title: String
    private let display: String
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let step: Int
    public init(_ title: String, display: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
        self.title = title
        self.display = display
        self._value = value
        self.range = range
        self.step = step
    }
    public var body: some View {
        SettingsRow(title) {
            Text(display).monospacedDigit().foregroundStyle(.secondary)
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden().accessibilityValue(display)
        }
    }
}

/// Shared chrome. The application supplies navigation; each feature supplies its actions.
public struct PanelToolbar<Actions: View>: View {
    private let title: String
    private let back: (() -> Void)?
    private let actions: Actions
    public init(_ title: String, back: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.back = back
        self.actions = actions()
    }
    public var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .help("返回首页").accessibilityLabel("返回首页")
                    .accessibilityIdentifier("control-center.back")
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            actions
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, AetherLayout.panelInset)
        .frame(minHeight: 44)
    }
}

/// Embedded feature views put their actions into the single shared toolbar.
private struct PanelBackKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
public extension EnvironmentValues {
    var panelBackAction: (() -> Void)? {
        get { self[PanelBackKey.self] }
        set { self[PanelBackKey.self] = newValue }
    }
}
