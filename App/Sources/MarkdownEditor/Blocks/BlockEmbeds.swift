import AppKit
import Markdown

/// The block editor's embeds: an embed block (`![alt](destination)` alone on its line) shows its picture or its
/// player, as an image line does in the old editor, through the same `EmbedProvider` and drawing. Its one character
/// takes no room; the paragraph's spacing below it is the picture's room.
extension EditorController {
    /// The link an embed block's Markdown makes.
    static func embedLink(of markdown: String) -> EmbedLink? {
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        guard let paragraph = document.child(at: 0) as? Paragraph,
              let image = paragraph.children.first(where: { $0 is Image }) as? Image else { return nil }
        return EmbedLink(destination: image.source ?? "", alt: image.plainText)
    }

    /// Shows every embed block of the page: called after each styling, with all of them, as the views of those
    /// gone are taken away.
    func applyBlockEmbeds() {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
        var spans: [StyleSpan] = []
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.noteBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attribute = value as? BlockAttribute, attribute.block.kind == .embed,
                  seen.insert(ObjectIdentifier(attribute)).inserted else { return }
            let paragraph = (storage.string as NSString).paragraphRange(for: range)
            let content = BlockStorage.content(of: paragraph, in: storage)
            guard content.length > 0, let link = Self.embedLink(of: attribute.block.text.string) else { return }
            spans.append(StyleSpan(.embed(destination: link.destination, alt: link.alt), content))
        }
        storage.beginEditing()
        applyEmbeds(spans, to: storage, revealing: textView.selectedRange())
        for span in spans where storage.attribute(.markdownPicture, at: span.range.location, effectiveRange: nil) != nil {
            // Shown: no card, and no line height but the picture's room under the hidden character.
            storage.removeIfPresent(.blockPlaceholder, range: span.range)
            let paragraph = (storage.string as NSString).paragraphRange(for: span.range)
            if let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle, style.minimumLineHeight != 0 || style.paragraphSpacingBefore != 0 {
                style.minimumLineHeight = 0
                style.paragraphSpacingBefore = 0
                storage.setIfChanged([.paragraphStyle: style], range: paragraph)
            }
        }
        storage.endEditing()
    }

    /// Cmd-K and the format bar's link button in the block editor: the link field over the selection or the link at
    /// the caret; a selected address becomes a link at once. False when there is nothing to link.
    func beginBlockLinkEdit() -> Bool {
        guard let blockSession, let textView, let window = textView.window else { return false }
        let selection = textView.selectedRange()
        let existing = blockSession.existingLink(near: selection)
        let text = textView.string as NSString
        if existing == nil {
            guard selection.length > 0, !text.substring(with: selection).contains("\n") else { return false }
            let label = text.substring(with: selection).trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("http://") || label.hasPrefix("https://"), !label.contains(" ") {
                blockSession.setLink(label, over: selection)
                return true
            }
        }
        let range = existing?.range ?? selection
        let panel = linkEditorPanel ?? LinkEditorPanel()
        linkEditorPanel = panel
        let first = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: min(1, range.length)), actualRange: nil)
        let last = textView.firstRect(forCharacterRange: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: min(1, range.length)), actualRange: nil)
        let area = textView.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? window.contentLayoutRect
        hideFormatBar()
        panel.model.text = existing?.destination ?? ""
        panel.model.isExisting = existing != nil
        let close: () -> Void = { [weak self, weak panel] in
            panel?.hide()
            self?.textView?.window?.makeFirstResponder(self?.textView)
        }
        panel.model.onCancel = { close() }
        panel.model.onCommit = { [weak blockSession] destination in
            close()
            let trimmed = destination.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            blockSession?.setLink(trimmed, over: range)
        }
        panel.model.onRemove = { [weak blockSession] in
            close()
            blockSession?.setLink(nil, over: range)
        }
        panel.show(below: last, above: first, within: window.convertToScreen(area), in: window)
        return true
    }

    /// A picture's handle let go in the block editor: its width goes into the embed's Markdown (`![alt|300](...)`),
    /// as one edit.
    func finishResizingBlockPicture(at location: Int, width: CGFloat) {
        guard let blockSession, let storage = textView?.textStorage, location < storage.length else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        guard var block = BlockStorage.block(in: storage, paragraph: paragraph), block.kind == .embed else { return }
        let markdown = block.text.string
        guard let alt = ImageSize.altRange(inImageLine: markdown) else { return }
        let replacement = ImageSize.alt(String(markdown[alt]), width: Int(width.rounded()))
        block.text = InlineText(markdown.replacingCharacters(in: alt, with: replacement))
        guard block.text.string != markdown else { return blockSession.restyle() }
        let selection = textView?.selectedRange() ?? NSRange(location: location, length: 0)
        blockSession.apply(BlockEdit(range: paragraph, replacement: BlockStorage.paragraph(of: block), selection: selection))
    }
}
