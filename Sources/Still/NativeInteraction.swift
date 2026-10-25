import SwiftUI

enum CalmMotion {
    static let quick = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.12)
    static let standard = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.2)

    static func reveal(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .opacity.combined(with: .offset(y: 4))
    }
}

struct FolderDisclosureState: Equatable {
    private(set) var expandedIDs: Set<String>

    init() {
        expandedIDs = Set(NoteSection.allCases.map { Self.rootID(for: $0) })
    }

    static func rootID(for section: NoteSection) -> String {
        "root:\(section.rawValue)"
    }

    func isExpanded(_ id: String) -> Bool {
        expandedIDs.contains(id)
    }

    mutating func toggle(_ id: String) {
        if !expandedIDs.insert(id).inserted {
            expandedIDs.remove(id)
        }
    }

    mutating func expandAncestors(section: NoteSection, path: [String]) {
        expandedIDs.insert(Self.rootID(for: section))
        guard !path.isEmpty else { return }
        for count in 1...path.count {
            expandedIDs.insert(Folder(section: section, path: Array(path.prefix(count))).id)
        }
    }
}

struct CalmButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : CalmMotion.quick, value: configuration.isPressed)
    }
}

struct CalmHoverModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var controlIsEnabled
    @State private var isHovered = false
    var cornerRadius: CGFloat = 7
    var isEnabled = true

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? Color.primary.opacity(0.028) : .clear)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isHovered && !reduceMotion ? 1.005 : 1)
            .animation(reduceMotion ? nil : CalmMotion.quick, value: isHovered)
            .onHover { isHovered = isEnabled && controlIsEnabled && $0 }
            .onChange(of: controlIsEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
    }
}

extension View {
    func calmHover(cornerRadius: CGFloat = 7, isEnabled: Bool = true) -> some View {
        modifier(CalmHoverModifier(cornerRadius: cornerRadius, isEnabled: isEnabled))
    }
}
