import AppKit
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

    static func displayText(
        for fullText: String,
        fits: (String) -> Bool
    ) -> String {
        guard !fullText.isEmpty, !fits(fullText) else { return fullText }

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
    private let horizontalInset: CGFloat = 12
    private let trailingInset: CGFloat = 12
    private var pasteOnlyFieldEditor: JoyPasteOnlyFieldEditor?

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.drawingRect(forBounds: rect)
        textRect.origin.x = rect.minX + horizontalInset
        textRect.size.width = max(0, rect.width - horizontalInset - trailingInset)

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

    override func accessibilityValue() -> String? {
        fullText
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        // The native field editor exists only to supply AppKit's insertion
        // point. Accessibility clients must use the same paste-only contract
        // as keyboard users instead of replacing the displayed value directly.
    }

    override func accessibilityLabel() -> String? {
        "ChatGPT or Codex link"
    }

    override func accessibilityHelp() -> String? {
        if fullText.isEmpty {
            "Click this empty row, then press Command-V to paste a link."
        } else {
            "Link configured. Clear it before pasting another link."
        }
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
            window?.performDrag(with: event)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
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
        field.fullText = text
        return field
    }

    func updateNSView(_ field: JoyNativeTextField, context: Context) {
        context.coordinator.onPaste = onPaste
        field.onPaste = context.coordinator.handlePaste
        field.fullText = text
        field.updateDisplayedText()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: JoyNativeTextField,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 42)
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

        init(onPaste: @escaping (String) -> Void) {
            self.onPaste = onPaste
        }

        func handlePaste(_ text: String) {
            onPaste(text)
        }
    }
}
