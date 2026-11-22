import SwiftUI

#if os(iOS)
import UIKit

/// A text field that finishes what you're typing. The suggested rest of the address sits
/// highlighted after the cursor: keep typing and it follows along, Backspace drops it, moving
/// the cursor past it keeps it, Return goes there.
///
/// SwiftUI's TextField can't style part of its text, so this wraps UITextField. The
/// suggestion is drawn, not selected, so no selection handles flash up while you type.
struct CompletingTextField: UIViewRepresentable {
    let placeholder: String
    /// What you typed, without the suggestion.
    @Binding var text: String
    /// True after a deletion, so the field doesn't fill straight back in what you just removed.
    @Binding var isDeleting: Bool
    /// The rest of the suggestion, shown after `text`. Empty for none.
    let suffix: String
    let textColor: Color
    let tint: Color
    /// Behind the suggestion. Matches the top hit row it leads to.
    let highlight: Color
    var onCancel: () -> Void = {}
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .never
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The bar opens ready to type.
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.textColor = UIColor(textColor)
        field.tintColor = UIColor(tint)

        // Leave the field alone while a keyboard is composing (Japanese, Chinese, and so on).
        guard field.markedTextRange == nil else { return }
        guard field.text != text + suffix || coordinator.suffix != suffix else { return }
        coordinator.show(text, suffix: suffix, in: field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CompletingTextField
        /// What the field shows as typed, and the suggestion drawn after it.
        private(set) var typed = ""
        private(set) var suffix = ""
        /// True while this code sets the text or cursor, so its own changes aren't read as yours.
        private var isApplying = false

        init(parent: CompletingTextField) { self.parent = parent }

        func show(_ typed: String, suffix: String, in field: UITextField) {
            isApplying = true
            defer { isApplying = false }
            let base: [NSAttributedString.Key: Any] = [
                .font: field.font ?? UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor(parent.textColor),
            ]
            let shown = NSMutableAttributedString(string: typed, attributes: base)
            if !suffix.isEmpty {
                var suggested = base
                suggested[.backgroundColor] = UIColor(parent.highlight)
                shown.append(NSAttributedString(string: suffix, attributes: suggested))
            }
            field.attributedText = shown
            field.typingAttributes = base
            // The cursor waits after what you typed, before the suggestion.
            if let at = field.position(from: field.beginningOfDocument, offset: typed.utf16.count) {
                field.selectedTextRange = field.textRange(from: at, to: at)
            }
            self.typed = typed
            self.suffix = suffix
        }

        /// Plain typing with no suggestion showing.
        @objc func editingChanged(_ field: UITextField) {
            guard !isApplying, field.markedTextRange == nil else { return }
            let now = field.text ?? ""
            let deleted = now.count < typed.count
            typed = now
            suffix = ""
            report(now, deleted: deleted)
        }

        /// While a suggestion shows, edits land in what you typed and the suggestion is redrawn.
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard !suffix.isEmpty, !isApplying else { return true }
            if string.isEmpty {
                // The first Backspace takes back the suggestion, and only that.
                show(typed, suffix: "", in: field)
                report(typed, deleted: true)
                return false
            }
            let length = (typed as NSString).length
            let start = min(range.location, length)
            let end = min(range.location + range.length, length)
            let next = (typed as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: string)
            // Typing the suggestion's next letters keeps the rest up, so it doesn't flicker
            // while the bar works out the new one.
            let typedAlong = start == length && suffix.lowercased().hasPrefix(string.lowercased())
            show(next, suffix: typedAlong ? String(suffix.dropFirst(string.count)) : "", in: field)
            report(next, deleted: false)
            return false
        }

        func textFieldDidChangeSelection(_ field: UITextField) {
            guard !isApplying, !suffix.isEmpty, field.markedTextRange == nil,
                  let selection = field.selectedTextRange else { return }
            let cursor = field.offset(from: field.beginningOfDocument, to: selection.start)
            if selection.isEmpty, cursor == typed.utf16.count { return }
            // Moving the cursor into or past the suggestion keeps it as typed text.
            let accepted = typed + suffix
            show(accepted, suffix: "", in: field)
            if let at = field.position(from: field.beginningOfDocument, offset: min(cursor, accepted.utf16.count)) {
                field.selectedTextRange = field.textRange(from: at, to: at)
            }
            report(accepted, deleted: true)
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        private func report(_ text: String, deleted: Bool) {
            parent.isDeleting = deleted
            parent.text = text
        }
    }
}
#else
import AppKit

/// The Mac keeps the same field contract, with an NSTextField underneath. The inline suggestion
/// is drawn by the results list here; the field itself stays plain, and Return runs the top hit.
struct CompletingTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isDeleting: Bool
    let suffix: String
    let textColor: Color
    let tint: Color
    let highlight: Color
    var onCancel: () -> Void = {}
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = NSColor(textColor)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        // The bar opens ready to type.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.textColor = NSColor(textColor)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = NSColor(tint)
        } else if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingTextField

        init(parent: CompletingTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let now = field.stringValue
            let deleted = now.count < parent.text.count
            parent.isDeleting = deleted
            parent.text = now
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
#endif
