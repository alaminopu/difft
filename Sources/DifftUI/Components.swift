import SwiftUI

/// Small building blocks shared by every pane, so a field or a badge is drawn
/// once rather than re-derived per file.

/// A two-or-three-way switch drawn in the app's own surfaces.
///
/// The system segmented picker brings its own bezel and accent, which over the
/// dark chrome read as a bright foreign object in every header it sat in.
public struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    public init(selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? Palette.textStrong : Palette.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(active ? Palette.controlActive : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

/// The filled call to action. One per screen.
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// An outlined button for everything that is not the one primary action.
public struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var tint: Color?
    public init(tint: Color? = nil) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tint ?? Palette.text)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(configuration.isPressed ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder((tint ?? Palette.cardBorder).opacity(tint == nil ? 1 : 0.55))
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// A text-only action inside a card: Reply, Dismiss, Open.
public struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var tint: Color
    public init(tint: Color = Palette.accent) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : 1))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// A square icon button with a hover wash, for bar and header actions.
public struct IconButton: View {
    let systemName: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    public init(_ systemName: String, help: String, active: Bool = false,
                action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active ? Palette.accent : Palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(active ? Palette.activeChip : (hovering ? Palette.hover : .clear),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A plain search or filter field.
public struct QuietField: View {
    let placeholder: String
    @Binding var text: String
    var systemImage = "magnifyingglass"
    var focus: FocusState<Bool>.Binding?

    public init(_ placeholder: String, text: Binding<String>,
                systemImage: String = "magnifyingglass",
                focus: FocusState<Bool>.Binding? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.systemImage = systemImage
        self.focus = focus
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textTertiary)
            field
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Typography.control)
        if let focus { base.focused(focus) } else { base }
    }
}

/// A person, as their initials on a colour that stays theirs.
public struct AvatarDisc: View {
    let login: String
    var size: CGFloat = 24

    public init(login: String, size: CGFloat = 24) {
        self.login = login
        self.size = size
    }

    /// "audreyfeldroy" → "AU", "chatgpt-codex-connector[bot]" → "CC".
    static func initials(for login: String) -> String {
        let name = login.replacingOccurrences(of: "[bot]", with: "")
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first {
            return "\(a)\(b)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    public var body: some View {
        Text(Self.initials(for: login))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: size, height: size)
            .background(Palette.avatar(for: login), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A small tinted label: "Open", "Draft", "HIGH".
public struct Tag: View {
    let text: String
    let tint: Color

    public init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

/// A key cap, for the few places a shortcut is worth showing.
public struct KeyCap: View {
    let key: String
    public init(_ key: String) { self.key = key }

    public var body: some View {
        Text(key)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.cardBorder) }
    }
}

/// The bar at the top of a centre pane: a title, its detail, and its controls.
public struct PaneHeader<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Spacing.md) {
            leading
            Spacer(minLength: Spacing.sm)
            trailing
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: Chrome.paneHeader)
        .background(Palette.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

public extension View {
    /// A card on the canvas: raised fill, hairline border.
    func card(radius: CGFloat = Radius.lg, border: Color = Palette.cardBorder) -> some View {
        self
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(border)
                    .allowsHitTesting(false)
            }
    }
}
