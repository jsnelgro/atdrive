import SwiftUI

/// A row in the menu-bar window that looks and behaves like a menu item: full width, an icon,
/// highlighted under the pointer, an optional shortcut on the right.
struct MenuRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    init(_ title: String, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).opacity(0.6)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let highlighted = hovering && isEnabled
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                        .opacity(configuration.isPressed ? 0.8 : 1)
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// A choice shown as a card: an icon, a title, a line about it.
struct ChoiceCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            hovering && isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                            lineWidth: 1)
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// Something went wrong (or needs attention), said in a box that can be dismissed.
struct Callout: View {
    enum Kind { case error, warning }

    let text: String
    var kind: Kind = .error
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(kind == .error ? .red : .orange)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((kind == .error ? Color.red : Color.orange).opacity(0.1))
        }
    }
}

/// A step's title, with an icon and a line under it.
struct StepHeader: View {
    let title: String
    let systemImage: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
