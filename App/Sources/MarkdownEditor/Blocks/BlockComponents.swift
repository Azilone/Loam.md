import AppKit

/// The block editor's diagrams and live blocks: a fenced code block of a language a plugin draws (` ```mermaid `) or
/// shows as a live view (` ```base `) is one character in the page, its code kept in its block, as a table is. The
/// picture or the view takes the room under it; the code is edited on the code page (`PictureViewer`), never as
/// text in the page, so a click never shows it.
extension EditorController {
    /// The languages shown as components now: the block editor's storage holds their blocks as one character.
    var componentLanguages: Set<String> { Set(pictureRenderers.keys).union(liveBlockProviders.keys) }

    /// The plugins' languages changed: the page is read again so their blocks become (or stop being) components.
    func componentLanguagesChanged() {
        guard let blockSession else { return }
        BlockStorage.componentLanguages = componentLanguages
        blockSession.reload()
        undo.removeAllActions()
    }

    /// Shows every diagram block of the page, after each styling: its picture when it is drawn (asked for when it is
    /// not), a card until then.
    func applyBlockPictures() {
        guard let textView, let storage = textView.textStorage, !pictureRenderers.isEmpty, storage.length > 0 else { return }
        let appearance = textView.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colors = theme.pictureColors(in: appearance)
        let available = textView.columnWidth
        storage.beginEditing()
        defer { storage.endEditing() }
        for (block, content) in componentBlocks(in: storage) {
            guard case .code(let written) = block.kind else { continue }
            let language = written.lowercased()
            guard let renderer = pictureRenderers[language], liveBlockProviders[language] == nil else { continue }
            let request = PictureRequest(
                language: language, code: EditorController.code(of: block), isDark: isDark, colors: colors,
                fontFamily: theme.cssFontFamily, fontSize: theme.fontSize
            )
            let image = pictures.image(for: request)
            if image == nil, pictures.needs(request), !drawingPictures.contains(request) { drawBlockPicture(request, with: renderer) }
            guard let image else {
                if pictures.failed.contains(request) {
                    storage.addAttribute(.blockPlaceholder, value: "Diagram: its code does not draw. Click to edit it".uiLocalized, range: content)
                }
                continue
            }
            let scale = min(1, available / max(image.size.width, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            showComponent(at: content, height: size.height, in: storage)
            storage.setIfChanged(
                [.markdownPicture: PictureMark(image: image, size: size, caret: content.location, zoomable: true)],
                range: content
            )
        }
    }

    /// Shows every live block of the page (a collection), after each styling. Views follow their block: matched by
    /// their code, else by their rank.
    func applyBlockLiveBlocks() {
        guard let textView, let storage = textView.textStorage else { return }
        var found: [(content: NSRange, language: String, code: String)] = []
        if !liveBlockProviders.isEmpty, storage.length > 0 {
            for (block, content) in componentBlocks(in: storage) {
                guard case .code(let written) = block.kind, liveBlockProviders[written.lowercased()] != nil else { continue }
                found.append((content, written.lowercased(), EditorController.code(of: block)))
            }
        }
        var old = liveBlocks
        var kept: [LiveBlock?] = found.map { entry in
            guard let index = old.firstIndex(where: { $0.handle.language == entry.language && $0.handle.code == entry.code }) else { return nil }
            return old.remove(at: index)
        }
        for index in kept.indices where kept[index] == nil {
            if let reuse = old.firstIndex(where: { $0.handle.language == found[index].language }) { kept[index] = old.remove(at: reuse) }
        }
        for gone in old { gone.outer?.removeFromSuperview() }
        var blocks: [LiveBlock] = []
        storage.beginEditing()
        for (index, entry) in found.enumerated() {
            let block = kept[index] ?? {
                let handle = LiveBlockHandle(language: entry.language, code: entry.code, isEditingCode: false,
                                             blockRange: entry.content, codeRange: entry.content)
                handle.controller = self
                return LiveBlock(handle: handle, provider: liveBlockProviders[entry.language]!)
            }()
            block.handle.blockRange = entry.content
            block.handle.codeRange = entry.content
            block.handle.update(code: entry.code, isEditingCode: false)
            blocks.append(block)
            showComponent(at: entry.content, height: block.height, in: storage)
            mark(block, in: storage)
        }
        storage.endEditing()
        liveBlocks = blocks
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.positionLiveViews() } }
    }

    /// The component blocks of the page and their one character.
    private func componentBlocks(in storage: NSTextStorage) -> [(NoteBlock, NSRange)] {
        var result: [(NoteBlock, NSRange)] = []
        var seen = Set<ObjectIdentifier>()
        let ns = storage.string as NSString
        storage.enumerateAttribute(.noteBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attribute = value as? BlockAttribute, case .code = attribute.block.kind,
                  BlockStorage.isAtomic(attribute.block.kind), seen.insert(ObjectIdentifier(attribute)).inserted else { return }
            let content = BlockStorage.content(of: ns.paragraphRange(for: range), in: storage)
            if content.length == 1 { result.append((attribute.block, content)) }
        }
        return result
    }

    /// The character takes no room and the card goes; the paragraph's spacing below it is the component's room.
    private func showComponent(at content: NSRange, height: CGFloat, in storage: NSTextStorage) {
        storage.setIfChanged(MarkdownTheme.concealed, range: content)
        storage.removeIfPresent(.blockPlaceholder, range: content)
        let paragraph = (storage.string as NSString).paragraphRange(for: content)
        let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.minimumLineHeight = 0
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = height + 2 * PictureMark.margin
        storage.setIfChanged([.paragraphStyle: style], range: paragraph)
    }

    /// The code of a component block, its lines joined by line breaks.
    static func code(of block: NoteBlock) -> String {
        block.text.string.replacingOccurrences(of: String(InlineText.lineBreak), with: "\n")
    }

    /// Asks the host for a diagram's picture; the page's components are shown again when it comes.
    private func drawBlockPicture(_ request: PictureRequest, with renderer: @escaping PictureRenderer) {
        drawingPictures.insert(request)
        let pictures = pictures
        Task { [weak self] in
            let image = await renderer(request)
            pictures.store(image, for: request)
            guard let self else { return }
            self.drawingPictures.remove(request)
            self.blockSession?.componentsChanged()
        }
    }

    // MARK: The code page

    /// The code page of the component block at `location`: its code, its picture drawn again as it changes (none for
    /// a live block), and each change written into the block as one undoable edit.
    func blockCodeEditing(at location: Int) -> PictureViewer.CodeEditing? {
        guard let textView, let storage = textView.textStorage, location < storage.length else { return nil }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        guard let block = BlockStorage.block(in: storage, paragraph: paragraph), case .code(let written) = block.kind else { return nil }
        let language = written.lowercased()
        let renderer = liveBlockProviders[language] == nil ? pictureRenderers[language] : nil
        let id = block.id
        return PictureViewer.CodeEditing(
            code: Self.code(of: block),
            render: { [weak self] code in
                guard let self, let renderer, let textView = self.textView else { return nil }
                let appearance = textView.effectiveAppearance
                let request = PictureRequest(
                    language: language, code: code, isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                    colors: self.theme.pictureColors(in: appearance), fontFamily: self.theme.cssFontFamily, fontSize: self.theme.fontSize
                )
                if let image = self.pictures.image(for: request) { return image }
                let image = await renderer(request)
                self.pictures.store(image, for: request)
                return image
            },
            commit: { [weak self] code in self?.setCode(code, ofBlock: id) }
        )
    }

    /// The component block `id` holds `code` now: one undoable edit, the caret where it was.
    func setCode(_ code: String, ofBlock id: NoteBlock.ID) {
        guard let textView, let storage = textView.textStorage, let blockSession else { return }
        for paragraph in BlockStorage.paragraphs(of: storage) where paragraph.length > 0 {
            guard var block = BlockStorage.block(in: storage, paragraph: paragraph), block.id == id else { continue }
            let text = code.replacingOccurrences(of: "\n", with: String(InlineText.lineBreak))
            guard block.text.string != text else { return }
            block.text = InlineText(text)
            let selection = textView.selectedRange()
            blockSession.apply(BlockEdit(range: paragraph, replacement: BlockStorage.paragraph(of: block), selection: selection))
            return
        }
    }

    /// Opens the code page of the component block at `location`, over a picture of it when there is one.
    func openBlockCodePage(at location: Int) {
        guard let textView, let editing = blockCodeEditing(at: location) else { return }
        textView.openCodePage(editing, picture: textView.pictureFrames().first { $0.0.caret == location }?.0.image)
    }
}

extension NSTextStorage {
    /// Removes `key` from `range` only when it is there: a removal lays the paragraph out again even when nothing goes.
    func removeIfPresent(_ key: NSAttributedString.Key, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= length else { return }
        var present = false
        enumerateAttribute(key, in: range) { value, _, stop in
            if value != nil { present = true; stop.pointee = true }
        }
        if present { removeAttribute(key, range: range) }
    }
}

extension EditorTextView {
    /// The code page of a component, at once: over its picture, or over an empty one (a collection, a diagram that
    /// does not draw).
    func openCodePage(_ editing: PictureViewer.CodeEditing, picture: NSImage?) {
        guard viewer == nil, let host = enclosingScrollView?.superview ?? enclosingScrollView else { return }
        let viewer = PictureViewer(image: picture ?? NSImage(size: NSSize(width: 1, height: 1)))
        viewer.background = backgroundColor
        viewer.codeBackground = theme.codeBackgroundColor
        viewer.codeEditing = editing
        viewer.onClose = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.onViewerChange(nil)
        }
        viewer.show(over: host)
        self.viewer = viewer
        onViewerChange { [weak viewer] in viewer?.close() }
        viewer.editCode()
    }
}
