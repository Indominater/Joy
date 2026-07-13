import AppKit
import SwiftUI

final class JoyPanel: NSPanel {
    private weak var arrowTrackingView: NSView?
    private var arrowTrackingArea: NSTrackingArea?
    var undoLastClear: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if joyIsUndoShortcut(event), undoLastClear?() == true {
            return true
        }
        if joyIsPasteShortcut(event),
           let field = joyURLTextField(for: firstResponder) {
            if field.fullText.isEmpty {
                field.paste(nil)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           !eventTargetsURLTextField(event) {
            clearPasteTarget()
        }

        super.sendEvent(event)

        switch event.type {
        case .cursorUpdate, .mouseEntered, .mouseMoved,
             .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            enforceArrowCursor()
        default:
            break
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        enforceArrowCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        enforceArrowCursor()
    }

    override func resignKey() {
        clearPasteTarget()
        super.resignKey()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let didChangeResponder = super.makeFirstResponder(responder)
        if didChangeResponder {
            enforceArrowCursor()
        }
        return didChangeResponder
    }

    private func enforceArrowCursor() {
        setArrowIfMouseIsInside()

        // SwiftUI descendants can update the cursor once more after the current
        // event finishes, so make the arrow the final cursor for the panel.
        DispatchQueue.main.async { [weak self] in
            self?.setArrowIfMouseIsInside()
        }
    }

    func installArrowOnlyCursorPolicy() {
        installArrowTrackingAreaIfNeeded()
        resetCursorRects()
        enforceArrowCursor()
    }

    private func setArrowIfMouseIsInside() {
        guard frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.arrow.set()
    }

    private func installArrowTrackingAreaIfNeeded() {
        guard let contentView, arrowTrackingView !== contentView else { return }

        if let arrowTrackingArea, let arrowTrackingView {
            arrowTrackingView.removeTrackingArea(arrowTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect,
                .enabledDuringMouseDrag
            ],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        arrowTrackingView = contentView
        arrowTrackingArea = area
    }

    private func eventTargetsURLTextField(_ event: NSEvent) -> Bool {
        guard let contentView else { return false }
        return containsURLTextField(
            contentView,
            at: event.locationInWindow
        )
    }

    private func containsURLTextField(_ view: NSView, at location: NSPoint) -> Bool {
        if let field = view as? JoyNativeTextField {
            return field.convert(field.bounds, to: nil).contains(location)
        }
        return view.subviews.contains { child in
            containsURLTextField(child, at: location)
        }
    }

    private func clearPasteTarget() {
        guard let field = joyURLTextField(for: firstResponder) else { return }
        field.deactivatePasteTarget()
    }

    deinit {
        if let arrowTrackingArea, let arrowTrackingView {
            arrowTrackingView.removeTrackingArea(arrowTrackingArea)
        }
    }

    override func performZoom(_ sender: Any?) {}

    override func toggleFullScreen(_ sender: Any?) {}

    override func cancelOperation(_ sender: Any?) {
        // Escape should never dismiss the utility panel. Child controls such as
        // the prompt search field still handle Escape before it reaches here.
    }
}

final class JoyArrowHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {
        addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
    }
}

func joyIsUndoShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(
        .deviceIndependentFlagsMask
    )
    return modifiers == .command
        && event.charactersIgnoringModifiers?.lowercased() == "z"
}

enum JoyPanelLayout {
    static let frameHeight: CGFloat = 224
    static let aspectRatio: CGFloat = 3 / 2
    static let frameSize = NSSize(
        width: (frameHeight * aspectRatio).rounded(),
        height: frameHeight
    )
    static let contentSize = NSSize(
        width: frameSize.width - 2,
        height: 212
    )
}

@MainActor
final class JoyPanelController: NSWindowController {
    init(store: MonitorStore) {
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .fullSizeContentView,
            .nonactivatingPanel
        ]
        let panelSize = JoyPanelLayout.frameSize

        let panel = JoyPanel(
            contentRect: NSRect(origin: .zero, size: JoyPanelLayout.contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        panel.title = "Joy"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.canHide = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.animationBehavior = .utilityWindow
        panel.undoLastClear = { store.undoLastClear() }
        let hostingView = JoyArrowHostingView(rootView: JoyView(store: store))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.installArrowOnlyCursorPolicy()

        var compactFrame = panel.frame
        compactFrame.size = panelSize
        panel.setFrame(compactFrame, display: false)
        panel.minSize = panelSize
        panel.maxSize = panelSize
        panel.standardWindowButton(.zoomButton)?.isEnabled = false

        let compactFrameName = "JoyThreeTwoFrameV8"
        let transitionalFrameName = "JoyFourThreeFrameV8"
        let legacyFrameName = "JoyGoldenFrameV7"
        let restoredSavedFrame = panel.setFrameUsingName(
            compactFrameName,
            force: true
        ) || panel.setFrameUsingName(
            transitionalFrameName,
            force: true
        ) || panel.setFrameUsingName(legacyFrameName, force: true)
        if restoredSavedFrame {
            var restoredFrame = panel.frame
            let topEdge = restoredFrame.maxY
            restoredFrame.size = panelSize
            restoredFrame.origin.y = topEdge - panelSize.height
            panel.setFrame(restoredFrame, display: false)
        } else {
            panel.center()
        }
        panel.setFrameAutosaveName(compactFrameName)

        super.init(window: panel)
        shouldCascadeWindows = false
        windowFrameAutosaveName = compactFrameName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if window?.isMiniaturized == true {
            window?.deminiaturize(sender)
        }
        // NSWindowController.showWindow makes an eligible panel key. Keep Joy
        // passive so WindowServer can treat it as a cross-application overlay;
        // a clicked link row can still request key status for Paste.
        window?.orderFrontRegardless()
        (window as? JoyPanel)?.installArrowOnlyCursorPolicy()
    }
}
