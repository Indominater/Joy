import SwiftUI

struct JoyView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ZStack {
            ArtworkBackground()

            VStack(spacing: 6) {
                ForEach(store.slots) { slot in
                    ChatRow(
                        slot: slot,
                        state: store.state(for: slot),
                        now: store.now,
                        updateURL: { store.updateURL(for: slot.id, to: $0) },
                        clear: {
                            store.clearURL(for: slot.id)
                            NSApp.windows
                                .first(where: { $0 is JoyPanel })?
                                .makeKey()
                        },
                        focus: { store.focus(slot) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}

private struct ChatRow: View {
    let slot: ChatSlot
    let state: ChatState
    let now: Date
    let updateURL: (String) -> Void
    let clear: () -> Void
    let focus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            JoyTextField(
                text: slot.url,
                onPaste: updateURL
            )
            .frame(
                maxWidth: .infinity,
                minHeight: 42,
                maxHeight: 42,
                alignment: .leading
            )

            HStack(spacing: 10) {
                if !slot.url.isEmpty {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color(hex: 0xEAC5BB).opacity(0.78))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: focus) {
                    StatusPill(state: state, now: now)
                }
                .buttonStyle(.plain)
                .disabled(state == .unconfigured || state == .invalid)
                .help("Open this chat")
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
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color(hex: 0xFFAA80).opacity(0.22), lineWidth: 1)
        }
    }
}

private struct StatusPill: View {
    let state: ChatState
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accentColor)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(labelColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: 70, alignment: .leading)
        .background(accentColor.opacity(0.10), in: Capsule())
        .overlay { Capsule().stroke(accentColor.opacity(0.26), lineWidth: 1) }
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

    private var label: String {
        switch state {
        case .unconfigured: "Ready"
        case .invalid: "Invalid"
        case .closed: "Closed"
        case .idle: "Idle"
        case .running(let startedAt): "Run \(format(max(0, now.timeIntervalSince(startedAt))))"
        case .finished(let duration): duration.map { "Done \(format($0))" } ?? "Done"
        case .failed: "Failed"
        }
    }

    private var accentColor: Color {
        switch state {
        case .running: Color(hex: 0x4DE2EA)
        case .finished: Color(hex: 0x78DFAF)
        case .failed, .invalid: Color(hex: 0xFF795F)
        case .closed: Color(hex: 0xC69AA8)
        case .unconfigured, .idle: Color(hex: 0xE9A98F)
        }
    }

    private var labelColor: Color {
        switch state {
        case .running: Color(hex: 0xBDF7F5)
        case .finished: Color(hex: 0xC4F1D8)
        case .failed, .invalid: Color(hex: 0xFFC0B0)
        case .closed: Color(hex: 0xE2C7CF)
        case .unconfigured, .idle: Color(hex: 0xF1D4C7)
        }
    }

    private func format(_ value: TimeInterval) -> String {
        let seconds = Int(value.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
