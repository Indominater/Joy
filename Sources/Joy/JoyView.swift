import AppKit
import SwiftUI

enum JoyTerminalPulse: Equatable {
    case success
    case failure

    static func transition(
        from previousState: ChatState,
        to state: ChatState
    ) -> JoyTerminalPulse? {
        guard case .running = previousState else { return nil }
        return switch state {
        case .finished: .success
        case .failed: .failure
        default: nil
        }
    }
}

enum JoyStatusText {
    static func label(for state: ChatState, now: Date) -> String {
        switch state {
        case .unconfigured: "Ready"
        case .invalid: "Invalid"
        case .closed: "Closed"
        case .idle: "Idle"
        case .running(let startedAt):
            "Run \(duration(max(0, now.timeIntervalSince(startedAt))))"
        case .finished(let value):
            value.map { "Done \(duration($0))" } ?? "Done"
        case .failed: "Failed"
        }
    }

    static func duration(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "—" }
        let seconds = Int(max(0, value).rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct JoyTerminalPulseTaskID: Equatable {
    let state: ChatState
    let reduceMotion: Bool
}

struct JoyView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ZStack {
            ArtworkBackground()

            VStack(spacing: 5) {
                ForEach(store.slots) { slot in
                    ChatRow(
                        slot: slot,
                        state: store.state(for: slot),
                        now: store.now,
                        showsUndo: store.undoableClearSlotID == slot.id,
                        updateURL: { store.updateURL(for: slot.id, to: $0) },
                        clear: {
                            store.clearURL(for: slot.id)
                            NSApp.windows
                                .first(where: { $0 is JoyPanel })?
                                .makeKey()
                        },
                        undo: { store.undoLastClear(for: slot.id) },
                        focus: { store.focus(slot) }
                    )
                }
            }
            .padding(.horizontal, 10)
            // The transparent titlebar supplies the visual top inset; this
            // compensation balances the first and last rows.
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}

private struct ChatRow: View {
    let slot: ChatSlot
    let state: ChatState
    let now: Date
    let showsUndo: Bool
    let updateURL: (String) -> Void
    let clear: () -> Void
    let undo: () -> Void
    let focus: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isClearHovered = false
    @State private var isStatusHovered = false
    @State private var previousState: ChatState?
    @State private var terminalPulse: JoyTerminalPulse?
    @State private var terminalGlowOpacity = 0.0

    var body: some View {
        HStack(spacing: 0) {
            JoyTextField(
                text: slot.url,
                onPaste: updateURL,
                onOpen: focus
            )
            .frame(
                maxWidth: .infinity,
                minHeight: 42,
                maxHeight: 42,
                alignment: .leading
            )

            HStack(spacing: 8) {
                if !slot.url.isEmpty {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(
                                Color(hex: 0xEAC5BB)
                                    .opacity(isClearHovered ? 0.96 : 0.70)
                            )
                            .frame(width: 28, height: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(
                        JoyTactileButtonStyle(
                            pressedScale: 0.90,
                            reduceMotion: reduceMotion
                        )
                    )
                    .background {
                        JoyActiveHoverRegion(isHovered: $isClearHovered)
                    }
                    .help("Remove link — Command-Z restores it for 5 seconds")
                    .accessibilityLabel("Remove link")
                    .accessibilityHint("Can be undone for five seconds")
                }

                Button(action: showsUndo ? undo : focus) {
                    StatusPill(
                        state: state,
                        now: now,
                        showsUndo: showsUndo,
                        isHovered: isStatusHovered && isStatusActionEnabled
                    )
                    .frame(width: 100, height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(
                    JoyTactileButtonStyle(
                        pressedScale: 0.98,
                        reduceMotion: reduceMotion
                    )
                )
                .background {
                    JoyActiveHoverRegion(isHovered: $isStatusHovered)
                }
                .disabled(!isStatusActionEnabled)
                .help(showsUndo ? "Restore removed link" : openHelp)
                .accessibilityLabel(
                    showsUndo ? "Undo remove link" : statusAccessibilityLabel
                )
            }
        }
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(
            Color(hex: 0x190811).opacity(0.48),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .background(
            .ultraThinMaterial.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .background {
            JoyActiveHoverRegion(isHovered: $isHovered)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    Color(hex: 0xFFAA80)
                        .opacity(isHovered ? 0.025 : 0)
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    Color(hex: 0xFFAA80)
                        .opacity(isHovered ? 0.32 : 0.22),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    terminalPulseColor.opacity(terminalGlowOpacity),
                    lineWidth: 1.5
                )
                .shadow(
                    color: terminalPulseColor.opacity(
                        terminalGlowOpacity * 0.58
                    ),
                    radius: 7
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovered
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.10),
            value: isClearHovered
        )
        .task(
            id: JoyTerminalPulseTaskID(
                state: state,
                reduceMotion: reduceMotion
            )
        ) {
            let oldState = previousState
            previousState = state
            terminalGlowOpacity = 0
            terminalPulse = nil

            guard let oldState,
                  let pulse = JoyTerminalPulse.transition(
                    from: oldState,
                    to: state
                  ),
                  !reduceMotion
            else { return }

            terminalPulse = pulse
            terminalGlowOpacity = pulse == .success ? 0.68 : 0.62
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.65)) {
                terminalGlowOpacity = 0
            }
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            terminalPulse = nil
        }
    }

    private var openHelp: String {
        switch URLNormalizer.target(slot.url) {
        case .chatGPT: "Open this ChatGPT conversation"
        case .codex: "Open this Codex task"
        case nil: "Link unavailable"
        }
    }

    private var isStatusActionEnabled: Bool {
        showsUndo || (state != .unconfigured && state != .invalid)
    }

    private var statusAccessibilityLabel: String {
        "\(openHelp), status \(JoyStatusText.label(for: state, now: now))"
    }

    private var terminalPulseColor: Color {
        switch terminalPulse {
        case .success: Color(hex: 0x78DFAF)
        case .failure: Color(hex: 0xFF795F)
        case nil: .clear
        }
    }
}

private struct StatusPill: View {
    let state: ChatState
    let now: Date
    let showsUndo: Bool
    let isHovered: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if showsUndo {
                content(icon: "arrow.uturn.backward", label: "Undo")
                    .transition(.opacity)
            } else {
                content(
                    icon: icon,
                    label: JoyStatusText.label(for: state, now: now)
                )
                    .transition(.opacity)
            }
        }
        .frame(width: 100, height: 28, alignment: .leading)
        .background(accentColor.opacity(backgroundOpacity), in: Capsule())
        .overlay {
            Capsule().stroke(
                accentColor.opacity(strokeOpacity),
                lineWidth: 1
            )
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: showsUndo
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.10),
            value: isHovered
        )
    }

    @ViewBuilder
    private func content(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accentColor)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(labelColor)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 100, height: 28, alignment: .leading)
    }

    private var icon: String {
        switch state {
        case .running: "waveform"
        case .finished: "checkmark"
        case .failed, .invalid: "exclamationmark"
        case .closed: "rectangle.slash"
        case .unconfigured, .idle: "circle"
        }
    }

    private var accentColor: Color {
        if showsUndo {
            return Color(hex: 0xE9A98F)
        }
        return switch state {
        case .running: Color(hex: 0x4DE2EA)
        case .finished: Color(hex: 0x78DFAF)
        case .failed, .invalid: Color(hex: 0xFF795F)
        case .closed: Color(hex: 0xC69AA8)
        case .unconfigured, .idle: Color(hex: 0xE9A98F)
        }
    }

    private var labelColor: Color {
        if showsUndo {
            return Color(hex: 0xF1D4C7)
        }
        return switch state {
        case .running: Color(hex: 0xBDF7F5)
        case .finished: Color(hex: 0xC4F1D8)
        case .failed, .invalid: Color(hex: 0xFFC0B0)
        case .closed: Color(hex: 0xE2C7CF)
        case .unconfigured, .idle: Color(hex: 0xF1D4C7)
        }
    }

    private var backgroundOpacity: Double {
        if showsUndo {
            return isHovered ? 0.20 : 0.14
        }
        return isHovered ? 0.15 : 0.10
    }

    private var strokeOpacity: Double {
        if showsUndo {
            return isHovered ? 0.48 : 0.34
        }
        return isHovered ? 0.38 : 0.26
    }

}

private struct JoyTactileButtonStyle: ButtonStyle {
    let pressedScale: CGFloat
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                reduceMotion || !configuration.isPressed ? 1 : pressedScale
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(
                    duration: configuration.isPressed ? 0.07 : 0.11
                ),
                value: configuration.isPressed
            )
    }
}

private struct JoyActiveHoverRegion: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> JoyActiveHoverView {
        let view = JoyActiveHoverView(frame: .zero)
        view.onHoverChange = updateHover
        return view
    }

    func updateNSView(_ view: JoyActiveHoverView, context: Context) {
        view.onHoverChange = updateHover
    }

    private func updateHover(_ value: Bool) {
        if isHovered != value {
            isHovered = value
        }
    }
}

final class JoyActiveHoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
                .enabledDuringMouseDrag
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            onHoverChange?(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

private struct ArtworkBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(hex: 0x12070E)

                if let image = JoyArtwork.backgroundImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: proxy.size.width * 1.15,
                            height: proxy.size.height * 1.15
                        )
                        .clipped()
                        .position(
                            x: proxy.size.width * 0.442,
                            y: proxy.size.height * 0.569
                        )
                }

                LinearGradient(
                    colors: [
                        Color(hex: 0x12070E).opacity(0.60),
                        Color(hex: 0x260913).opacity(0.28),
                        Color(hex: 0x10060C).opacity(0.58)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.08),
                        Color(hex: 0x210711).opacity(0.12),
                        Color.black.opacity(0.30)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
        }
        .ignoresSafeArea()
    }
}

private enum JoyArtwork {
    static let backgroundImage: NSImage? = {
        if let bundledURL = Bundle.main.url(
            forResource: "132970571_p0",
            withExtension: "png"
        ) {
            return NSImage(contentsOf: bundledURL)
        }

        // Keep `swift run` and local source builds useful outside the app bundle.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/132970571_p0.png")
        return NSImage(contentsOf: sourceURL)
    }()
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}
