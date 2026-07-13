import AppKit
import SwiftUI

final class JoyPanel: NSPanel {
    private var ownsCursorRectDisable = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
        installArrowOnlyCursorPolicy()

        // SwiftUI descendants can update the cursor once more after the current
        // event finishes, so make the arrow the final cursor for the panel.
        DispatchQueue.main.async { [weak self] in
            self?.setArrowIfMouseIsInside()
        }
    }

    func installArrowOnlyCursorPolicy() {
        // The links are display-only, so keep an arrow over the whole panel.
        if !ownsCursorRectDisable {
            disableCursorRects()
            ownsCursorRectDisable = true
        }
        setArrowIfMouseIsInside()
    }

    private func setArrowIfMouseIsInside() {
        guard frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.arrow.set()
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
        if ownsCursorRectDisable {
            enableCursorRects()
        }
    }

    override func performZoom(_ sender: Any?) {}

    override func toggleFullScreen(_ sender: Any?) {}

    override func cancelOperation(_ sender: Any?) {
        // Escape should never dismiss the utility panel. Child controls such as
        // the prompt search field still handle Escape before it reaches here.
    }
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
        let goldenRatio = (1 + CGFloat(5).squareRoot()) / 2
        let goldenHeight: CGFloat = 224
        let goldenSize = NSSize(
            width: (goldenHeight * goldenRatio).rounded(),
            height: goldenHeight
        )
        let contentHeight: CGFloat = 212

        let panel = JoyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: contentHeight),
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
        let hostingView = NSHostingView(rootView: JoyView(store: store))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.installArrowOnlyCursorPolicy()

        var goldenFrame = panel.frame
        goldenFrame.size = goldenSize
        panel.setFrame(goldenFrame, display: false)
        panel.minSize = goldenSize
        panel.maxSize = goldenSize
        panel.standardWindowButton(.zoomButton)?.isEnabled = false

        let compactFrameName = "JoyGoldenFrameV7"
        if panel.setFrameUsingName(compactFrameName, force: true) {
            var restoredFrame = panel.frame
            let topEdge = restoredFrame.maxY
            restoredFrame.size = goldenSize
            restoredFrame.origin.y = topEdge - goldenSize.height
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
