import AppKit
import SwiftUI

// The shared look, taken from the mocks in docs/redesign/ (section 4 of plan.md).

enum Theme {
    // Page and text.
    static let paper = Color(hex: 0xfaf5ee)
    static let ink = Color(hex: 0x211d19)
    /// Secondary text, table headers and small cap labels.
    static let muted = Color(hex: 0x696156)
    /// Rules and row dividers.
    static let line = Color(hex: 0xdcd4c8)

    // Window chrome.
    static let rail = Color(hex: 0xede7dd)
    static let railSelected = Color(hex: 0xdbd3c6)
    static let bar = Color(hex: 0xf4eee5)
    static let footer = Color(hex: 0xf2ece2)
    static let crumbSeparator = Color(hex: 0xa79c8b)

    // Grouped areas.
    static let hero = Color(hex: 0xeae2d4)
    static let inset = Color(hex: 0xeee7dc)
    static let picked = Color(hex: 0xefe7da)

    // Controls.
    static let field = Color(hex: 0xfdfaf5)
    static let fieldBorder = Color(hex: 0xcfc6ba)
    static let button = Color(hex: 0xfcf9f3)
    static let buttonBorder = Color(hex: 0xc9c0b4)
    static let primary = Color(hex: 0x2c2923)
    static let primaryText = Color(hex: 0xfffaf0)

    // Waveform areas.
    static let scope = Color(hex: 0xeae5d9)
    static let scopeBorder = Color(hex: 0xcfc7b9)
    static let waveform = Color(hex: 0x716e5d)

    /// Recording and edit position, and anything needing attention.
    static let rust = Color(hex: 0x914d37)
    static let needle = Color(hex: 0x9d4e35)
    static let eyebrow = Color(hex: 0x81533d)

    // Status dots. Never used for text: draft gold on paper is too faint to read.
    static let dotPublished = Color(hex: 0x61775d)
    static let dotDraft = Color(hex: 0x9e8054)
    static let dotWorking = Color(hex: 0xa36245)
    static let dotIdle = Color(hex: 0x88877a)

    /// Green words, such as "Published". The mocks' darker `.status` green.
    static let goodText = Color(hex: 0x52644e)

    // The dark meter panel, on the record screen only.
    static let meterPanel = Color(hex: 0x292e29)
    static let meterText = Color(hex: 0xf4efdc)
    static let meterDot = Color(hex: 0xde886c)

    // Names from before the redesign, still used by screens not yet rebuilt.
    static let inkMuted = muted
    static let card = inset
    static let board = hero
    static let accent = rust
    static let attention = rust
    static let good = dotPublished

    /// The serif for titles, track names, captions and the write-up.
    static func display(_ size: CGFloat) -> Font { serif(size) }

    static func serif(_ size: CGFloat) -> Font {
        guard let serifName else { return .system(size: size, design: .serif) }
        return .custom(serifName, fixedSize: size)
    }

    /// The first of the mocks' serifs that's installed. A custom font name that
    /// doesn't resolve falls back silently to sans, so each one is checked.
    private static let serifName: String? = [
        "IowanOldStyle-Roman", "PalatinoLinotype-Roman", "Palatino-Roman", "Georgia",
    ].first { NSFont(name: $0, size: 12) != nil }

    /// Eyebrow and cap labels.
    static let smallLabel = Font.system(size: 10, design: .monospaced)
    static let smallLabelTracking: CGFloat = 1.35

    /// RA numbers and timecodes.
    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, design: .monospaced).monospacedDigit()
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

/// Sizes chosen from the width of the detail area, since the mocks are drawn far
/// wider than the app's usual window.
enum LayoutSize {
    case regular, compact

    init(detailWidth: CGFloat) {
        self = detailWidth >= 980 ? .regular : .compact
    }

    var pageTitle: CGFloat { self == .regular ? 49 : 32 }
    var heroTitle: CGFloat { self == .regular ? 35 : 26 }
    var sectionTitle: CGFloat { self == .regular ? 27 : 21 }
    var rowName: CGFloat { self == .regular ? 19 : 16 }
    var rightColumn: CGFloat { self == .regular ? 282 : 230 }
    var heroHeight: CGFloat { self == .regular ? 212 : 150 }

    static func pagePadding(windowWidth: CGFloat) -> CGFloat {
        min(49, max(25, windowWidth * 0.0335))
    }
}

/// The rust label above a page or hero title.
struct EyebrowLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.smallLabel)
            .tracking(Theme.smallLabelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.eyebrow)
            .lineLimit(1)
    }
}

/// The muted label for table headers and groups, such as "Tape label".
struct CapLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.smallLabel)
            .tracking(Theme.smallLabelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
    }
}

/// Eyebrow, title and subtitle, with the page's actions to the right.
struct PageHeader<Actions: View>: View {
    var eyebrow: String?
    let title: String
    var subtitle: String?
    var size: LayoutSize = .compact
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if let eyebrow { EyebrowLabel(eyebrow) }
                Text(title)
                    .font(Theme.serif(size.pageTitle))
                    .tracking(size == .regular ? -1.9 : -1)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .help(title)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 9) { actions }
                .fixedSize()
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil, size: LayoutSize = .compact) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, size: size) { EmptyView() }
    }
}

/// A word with a coloured dot. Only the dot is coloured.
struct StatusBadge: View {
    enum Tone {
        case published, draft, working, idle

        var color: Color {
            switch self {
            case .published: Theme.dotPublished
            case .draft: Theme.dotDraft
            case .working: Theme.dotWorking
            case .idle: Theme.dotIdle
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
        }
        .fixedSize()
    }
}

struct HairlineRule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A name on the left and its value on the right, ruled underneath.
struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(key)
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                Spacer(minLength: 0)
                Text(value)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
            }
            .font(.system(size: 13))
            .padding(.vertical, 10)
            HairlineRule()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Number, serif name, a small line under it, and the duration. The name is the
/// caller's view, so it can be edited in place.
struct NumberedTrackRow<Name: View>: View {
    let number: String
    var detail: String?
    let duration: String
    var size: LayoutSize = .compact
    var isPicked = false
    @ViewBuilder var name: Name

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: size == .regular ? 12 : 8) {
                Text(number)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.muted)
                    .frame(width: size == .regular ? 31 : 20, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    name
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(duration)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
            }
            .padding(.horizontal, size == .regular ? 10 : 7)
            .padding(.vertical, size == .regular ? 12 : 9)
            HairlineRule()
        }
        .background(isPicked ? Theme.picked : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// The mocks' two buttons: dark for a screen's main action, pale for the rest.
struct PaperButtonStyle: ButtonStyle {
    var isPrimary = false
    /// Tighter, for rows of controls under a waveform.
    var isSmall = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, isPrimary: isPrimary, isSmall: isSmall)
    }

    /// A view of its own, so it can read whether the button is enabled.
    private struct Face: View {
        @Environment(\.isEnabled) private var isEnabled

        let configuration: Configuration
        let isPrimary: Bool
        let isSmall: Bool

        var body: some View {
            configuration.label
                .font(.system(size: isSmall ? 12 : 13))
                .foregroundStyle(isPrimary ? Theme.primaryText : Theme.ink)
                .fixedSize()
                .padding(.horizontal, isSmall ? 9 : 12)
                .padding(.vertical, isSmall ? 4 : 8)
                .background(isPrimary ? Theme.primary : Theme.button, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isPrimary ? Theme.primary : Theme.buttonBorder)
                }
                .contentShape(.rect(cornerRadius: 6))
                .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
        }
    }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paperPrimary: PaperButtonStyle { PaperButtonStyle(isPrimary: true) }
    static var paperStandard: PaperButtonStyle { PaperButtonStyle() }
    static var paperSmall: PaperButtonStyle { PaperButtonStyle(isSmall: true) }
}

extension View {
    /// A text field or editor as the mocks draw it.
    func paperField() -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Theme.field, in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.fieldBorder) }
    }

    /// The bordered panel behind a waveform.
    func scopeBackground() -> some View {
        background(Theme.scope)
            .clipShape(.rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.scopeBorder)
                    .allowsHitTesting(false)
            }
    }
}
