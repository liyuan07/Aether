import SwiftUI

/// Shared page chrome. Feature views own controls, never another window or sidebar.
public struct SettingsContent<Content: View>: View {
    private let title: String
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
