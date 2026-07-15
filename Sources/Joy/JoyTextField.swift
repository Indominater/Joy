import AppKit
import QuartzCore
import SwiftUI

private func joyTextFieldTextColor() -> NSColor {
    NSColor(
        red: 1,
        green: 241 / 255,
        blue: 232 / 255,
        alpha: 1
    )
}

private func joyTextFieldAccentColor() -> NSColor {
    NSColor(
        red: 67 / 255,
        green: 221 / 255,
        blue: 230 / 255,
        alpha: 1
    )
}

private func applyJoyTextEditorAppearance(_ editor: NSTextView) {
    editor.insertionPointColor = joyTextFieldAccentColor()
    editor.updateInsertionPointStateAndRestartTimer(true)
}

private func applyJoyTextEditorGeometry(_ editor: NSTextView) {
    // These are the same field-editor metrics Joy used before link editing was
    // removed. AppKit therefore draws its native insertion point at the exact
    // original position and with the system blink behavior.
    editor.textContainerInset = NSSize(width: 2, height: 0)
    editor.textContainer?.lineFragmentPadding = 0
}

func joyIsPasteShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(
        .deviceIndependentFlagsMask
    )
    return modifiers == .command
        && event.charactersIgnoringModifiers?.lowercased() == "v"
}

enum JoyLinkDisplayFormatter {
    static let suffixCount = 6
    static let ellipsis = "\u{2026}"
    static let semanticSeparator = "\u{00B7}"

    private struct SemanticLabel {
        let service: String
        let compactService: String
        let identifier: String

        var text: String {
            let characters = Array(identifier)
            let suffix = String(characters.suffix(suffixCount))
            return "\(service) \(semanticSeparator) \(suffix)"
        }
    }

    static func displayText(
        for fullText: String,
        fits: (String) -> Bool
    ) -> String {
        guard !fullText.isEmpty else { return fullText }

        if let label = semanticLabel(for: fullText) {
            guard !fits(label.text) else { return label.text }

            let suffix = String(Array(label.identifier).suffix(suffixCount))
            let spacedCompact = "\(label.compactService) "
                + semanticSeparator
                + " \(suffix)"
            if fits(spacedCompact) {
                return spacedCompact
            }

            let compact = label.compactService + semanticSeparator + suffix
            if fits(compact) {
                return compact
            }

            let serviceCharacters = Array(label.compactService)
            for candidateCount in stride(
                from: serviceCharacters.count - 1,
                through: 1,
                by: -1
            ) {
                let candidate = String(serviceCharacters.prefix(candidateCount))
                    + semanticSeparator
                    + suffix
                if fits(candidate) {
                    return candidate
                }
            }
            return suffix
        }

        guard !fits(fullText) else { return fullText }

        let characters = Array(fullText)
        let preservedSuffixCount = min(suffixCount, characters.count)
        let suffix = String(characters.suffix(preservedSuffixCount))
        let prefixCharacters = Array(
            characters.dropLast(preservedSuffixCount)
        )

        for candidateCount in stride(
            from: prefixCharacters.count,
            through: 0,
            by: -1
        ) {
            let candidate = String(prefixCharacters.prefix(candidateCount))
                + ellipsis
                + suffix
            if fits(candidate) {
                return candidate
            }
        }

        return ellipsis + suffix
    }

    private static func semanticLabel(for fullText: String) -> SemanticLabel? {
        guard let target = URLNormalizer.target(fullText) else { return nil }

        switch target {
        case .chatGPT(_, let conversationID):
            return SemanticLabel(
                service: "ChatGPT",
                compactService: "Chat",
                identifier: conversationID
            )
        case .codex(let threadID):
            return SemanticLabel(
                service: "Codex",
                compactService: "Codex",
                identifier: threadID
            )
        }
    }
}

struct JoyClickDragTracker {
    static let defaultThreshold: CGFloat = 4

    private let origin: NSPoint
    private let thresholdSquared: CGFloat
    private var isFinished = false

    init(
        origin: NSPoint,
        threshold: CGFloat = defaultThreshold
    ) {
        self.origin = origin
        thresholdSquared = max(0, threshold) * max(0, threshold)
    }

    mutating func registerDrag(to location: NSPoint) -> Bool {
        guard !isFinished else { return false }
        let deltaX = location.x - origin.x
        let deltaY = location.y - origin.y
        guard deltaX * deltaX + deltaY * deltaY >= thresholdSquared else {
            return false
        }
        isFinished = true
        return true
    }

    mutating func registerMouseUp() -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
}

enum JoyLinkPaste {
    static func text(from pasteboard: NSPasteboard) -> String? {
        sanitizedText(
            pasteboard.string(forType: .string)
                ?? pasteboard.string(forType: .URL)
        )
    }

    static func sanitizedText(_ pastedText: String?) -> String? {
        guard let pastedText else { return nil }
        let trimmedText = pastedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmedText.isEmpty ? nil : trimmedText
    }
}

private final class JoyPasteOnlyFieldEditor: NSTextView {
    weak var ownerField: JoyNativeTextField?

    override func resetCursorRects() {
        addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
    }

    override func keyDown(with event: NSEvent) {
        if joyIsPasteShortcut(event) {
            ownerField?.paste(nil)
        }
        // Empty link rows are paste targets, not text editors. All other input
        // is ignored before AppKit can insert or navigate anything.
    }

    override func insertText(
        _ insertString: Any,
        replacementRange: NSRange
    ) {
        // Input methods can call insertText directly without keyDown.
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        // Do not let input methods display an intermediate composition string.
    }

    override func paste(_ sender: Any?) {
        ownerField?.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        false
    }

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        false
    }
}

private final class JoyTextFieldCell: NSTextFieldCell {
    private let leadingInset: CGFloat = 10
    private let trailingInset: CGFloat = 4
    private var pasteOnlyFieldEditor: JoyPasteOnlyFieldEditor?

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.drawingRect(forBounds: rect)
        textRect.origin.x = rect.minX + leadingInset
        textRect.size.width = max(0, rect.width - leadingInset - trailingInset)

        let textHeight = cellSize(forBounds: textRect).height
        if textHeight < textRect.height {
            textRect.origin.y += ((textRect.height - textHeight) / 2).rounded(.down)
            textRect.size.height = textHeight
        }
        return textRect
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        start selectionStart: Int,
        length selectionLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            start: selectionStart,
            length: selectionLength
        )
    }

    override func setUpFieldEditorAttributes(_ textObject: NSText) -> NSText {
        let configuredEditor = super.setUpFieldEditorAttributes(textObject)
        if let editor = configuredEditor as? NSTextView {
            applyJoyTextEditorGeometry(editor)
            applyJoyTextEditorAppearance(editor)
        }
        return configuredEditor
    }

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let field = controlView as? JoyNativeTextField else { return nil }

        let editor: JoyPasteOnlyFieldEditor
        if let pasteOnlyFieldEditor {
            editor = pasteOnlyFieldEditor
        } else {
            editor = JoyPasteOnlyFieldEditor.fieldEditor()
            editor.isRichText = false
            editor.importsGraphics = false
            editor.allowsUndo = false
            pasteOnlyFieldEditor = editor
        }
        editor.ownerField = field
        return editor
    }
}

final class JoyNativeTextField: NSTextField {
    var onPaste: ((String) -> Void)?
    var onOpen: (() -> Void)?
    private var isExplicitPasteTarget = false

    var fullText = "" {
        didSet {
            guard fullText != oldValue else { return }
            if !fullText.isEmpty {
                deactivatePasteTarget()
            }
            updateEditingEligibility()
            updateDisplayedText()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var needsPanelToBecomeKey: Bool { fullText.isEmpty }
    override var acceptsFirstResponder: Bool {
        fullText.isEmpty && isExplicitPasteTarget
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard copyableText != nil else { return super.menu(for: event) }

        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(copyLink(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)
        return menu
    }

    override func accessibilityValue() -> String? {
        fullText
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        // The native field editor exists only to supply AppKit's insertion
        // point. Accessibility clients must use the same paste-only contract
        // as keyboard users instead of replacing the displayed value directly.
    }

    override func accessibilityLabel() -> String? {
        switch URLNormalizer.target(fullText) {
        case .chatGPT: "ChatGPT link"
        case .codex: "Codex link"
        case nil: "ChatGPT or Codex link"
        }
    }

    override func accessibilityHelp() -> String? {
        if fullText.isEmpty {
            "Click this empty row, then press Command-V to paste a link."
        } else if URLNormalizer.target(fullText) == nil {
            "Unsupported link. Clear it before pasting another link."
        } else {
            "Click to open, drag to move Joy, or right-click to copy the full link."
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard URLNormalizer.target(fullText) != nil, let onOpen else {
            return false
        }
        onOpen()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        if widthChanged {
            updateDisplayedText()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            deactivatePasteTarget()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard fullText.isEmpty else {
            trackConfiguredLinkGesture(from: event)
            return
        }

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let previousField = joyURLTextField(for: window?.firstResponder),
           previousField !== self {
            previousField.deactivatePasteTarget()
        }
        window?.makeKey()
        isExplicitPasteTarget = true
        updateEditingEligibility()
        super.mouseDown(with: event)

        guard let editor = currentEditor() as? NSTextView else { return }
        applyJoyTextEditorGeometry(editor)
        applyJoyTextEditorAppearance(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        if joyIsPasteShortcut(event) {
            paste(nil)
        }
        // All other key input is intentionally ignored. Links can only be
        // replaced by paste or removed with the row's clear button.
    }

    @objc func paste(_ sender: Any?) {
        guard fullText.isEmpty,
              let pastedText = JoyLinkPaste.text(from: .general)
        else { return }

        acceptPastedText(pastedText)
    }

    @objc private func copyLink(_ sender: Any?) {
        writeFullText(to: .general)
    }

    func writeFullText(to pasteboard: NSPasteboard) {
        guard let copyableText else { return }
        pasteboard.clearContents()
        pasteboard.setString(copyableText, forType: .string)
    }

    var copyableText: String? {
        fullText.isEmpty ? nil : fullText
    }

    func acceptPastedText(_ pastedText: String) {
        guard fullText.isEmpty else { return }

        // Close the paste gate synchronously so repeated key events cannot
        // replace this link before SwiftUI publishes the model update.
        deactivatePasteTarget()
        fullText = pastedText
        onPaste?(pastedText)
    }

    func updateDisplayedText() {
        let textRect = (cell as? JoyTextFieldCell)?.drawingRect(forBounds: bounds)
            ?? bounds
        let backingScale = max(window?.backingScaleFactor ?? 2, 1)
        let widthBudget = max(
            (textRect.width * backingScale).rounded(.down) / backingScale
                - (0.5 / backingScale),
            0
        )
        let displayFont = font ?? NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: displayFont]
        let displayedText = JoyLinkDisplayFormatter.displayText(for: fullText) {
            candidate in
            (candidate as NSString).size(withAttributes: attributes).width
                <= widthBudget
        }

        if stringValue != displayedText {
            stringValue = displayedText
        }
        toolTip = fullText.isEmpty ? nil : fullText
    }

    func deactivatePasteTarget() {
        isExplicitPasteTarget = false
        if let editor = currentEditor(),
           window?.firstResponder === editor {
            window?.endEditing(for: self)
        }
    }

    private func updateEditingEligibility() {
        isEditable = fullText.isEmpty
        isSelectable = fullText.isEmpty
    }

    private func trackConfiguredLinkGesture(from mouseDownEvent: NSEvent) {
        guard let window else { return }

        var tracker = JoyClickDragTracker(origin: mouseDownEvent.locationInWindow)
        let canOpen = URLNormalizer.target(fullText) != nil
        var shouldDrag = false
        var shouldOpen = false
        if canOpen {
            setConfiguredLinkPressed(true)
        }

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] event, stop in
            guard let event else {
                stop.pointee = true
                return
            }

            if event.type == .leftMouseDragged {
                guard tracker.registerDrag(to: event.locationInWindow) else {
                    return
                }
                shouldDrag = true
                stop.pointee = true
            } else {
                let isClick = tracker.registerMouseUp()
                if let self {
                    let location = convert(event.locationInWindow, from: nil)
                    shouldOpen = isClick && bounds.contains(location)
                }
                stop.pointee = true
            }
        }

        if canOpen {
            setConfiguredLinkPressed(false)
        }
        if shouldDrag {
            window.performDrag(with: mouseDownEvent)
            return
        }
        guard shouldOpen, canOpen else { return }
        onOpen?()
    }

    private func setConfiguredLinkPressed(_ isPressed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isPressed ? 0.07 : 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = isPressed ? 0.72 : 1
        }
    }
}

func joyURLTextField(for responder: NSResponder?) -> JoyNativeTextField? {
    if let field = responder as? JoyNativeTextField {
        return field
    }
    guard let editor = responder as? JoyPasteOnlyFieldEditor,
          let field = editor.ownerField,
          field.currentEditor() === editor
    else { return nil }
    return field
}

@MainActor
struct JoyTextField: NSViewRepresentable {
    let text: String
    let onPaste: (String) -> Void
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste, onOpen: onOpen)
    }

    func makeNSView(context: Context) -> JoyNativeTextField {
        let field = JoyNativeTextField(frame: .zero)
        field.cell = JoyTextFieldCell(textCell: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = false
        field.cell?.wraps = false
        field.font = Self.font
        field.textColor = joyTextFieldTextColor()
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.onPaste = context.coordinator.handlePaste
        field.onOpen = context.coordinator.handleOpen
        field.fullText = text
        return field
    }

    func updateNSView(_ field: JoyNativeTextField, context: Context) {
        context.coordinator.onPaste = onPaste
        context.coordinator.onOpen = onOpen
        field.onPaste = context.coordinator.handlePaste
        field.onOpen = context.coordinator.handleOpen
        field.fullText = text
        field.updateDisplayedText()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: JoyNativeTextField,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(
            width: width,
            height: proposal.height ?? JoyRowLayout.height
        )
    }

    private static let font: NSFont = {
        let fallback = NSFont.systemFont(ofSize: 12, weight: .medium)
        guard let descriptor = fallback.fontDescriptor.withDesign(.rounded) else {
            return fallback
        }
        return NSFont(descriptor: descriptor, size: 12) ?? fallback
    }()

    final class Coordinator {
        var onPaste: (String) -> Void
        var onOpen: () -> Void

        init(
            onPaste: @escaping (String) -> Void,
            onOpen: @escaping () -> Void
        ) {
            self.onPaste = onPaste
            self.onOpen = onOpen
        }

        func handlePaste(_ text: String) {
            onPaste(text)
        }

        func handleOpen() {
            onOpen()
        }
    }
}
