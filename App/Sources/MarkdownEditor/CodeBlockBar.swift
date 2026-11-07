import AppKit
import PluginKitUI

/// The small bar at the top right of a code block, as Craft's and Notion's: the block's language, which a menu
/// changes (the fence's info string, ` ```swift `), and a button that copies the code. It shows while the pointer
/// is over the block or the caret is in it, and fades in and out (`Motion.hover`).
@MainActor
final class CodeBlockBar: NSView {
    /// The languages the menu offers, as `(fence name, shown name)`; any other name the fence holds shows as it is.
    static let languages: [(id: String, title: String)] = [
        ("bash", "Bash"), ("c", "C"), ("cpp", "C++"), ("csharp", "C#"), ("css", "CSS"), ("dart", "Dart"),
        ("diff", "Diff"), ("dockerfile", "Dockerfile"), ("go", "Go"), ("graphql", "GraphQL"), ("html", "HTML"),
        ("java", "Java"), ("javascript", "JavaScript"), ("json", "JSON"), ("kotlin", "Kotlin"), ("markdown", "Markdown"),
        ("mermaid", "Mermaid"), ("objectivec", "Objective-C"), ("php", "PHP"), ("python", "Python"), ("ruby", "Ruby"),
        ("rust", "Rust"), ("sql", "SQL"), ("swift", "Swift"), ("toml", "TOML"), ("typescript", "TypeScript"),
        ("xml", "XML"), ("yaml", "YAML"),
    ]

    /// The name shown for a fence's language: its usual spelling, "Plain text" for none.
    static func title(of language: String) -> String {
        if language.isEmpty { return "Plain text" }
        return languages.first { $0.id == language.lowercased() }?.title ?? language
    }

    /// Where the block starts: what the bar acts on.
    private(set) var block: NSRange?
    /// Sets the fence's language of the block starting at the given offset ("" for none).
    var onSetLanguage: ((Int, String) -> Void)?
    /// Copies the block's code.
    var onCopy: ((NSRange) -> Void)?

    private let language = NSPopUpButton(frame: .zero, pullsDown: true)
    private let copy = NSButton()
    private let background = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Corners.r(8)
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        language.isBordered = false
        language.font = .systemFont(ofSize: 11.5, weight: .medium)
        language.contentTintColor = .secondaryLabelColor
        (language.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        language.setAccessibilityLabel("Language")
        language.target = self
        language.action = #selector(chooseLanguage(_:))

        copy.image = NSImage.symbol("doc.on.doc", accessibilityDescription: "Copy Code")
        copy.isBordered = false
        copy.bezelStyle = .accessoryBarAction
        copy.contentTintColor = .secondaryLabelColor
        copy.toolTip = "Copy Code"
        copy.target = self
        copy.action = #selector(copyCode)
        copy.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let stack = NSStackView(views: [language, copy])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Shows the bar for the block at `block`, in `language`, at the top right corner of `card` (text view points).
    func show(block: NSRange, language current: String, card: NSRect) {
        if self.block != block || language.titleOfSelectedItem != Self.title(of: current) {
            rebuildMenu(current: current)
        }
        self.block = block
        layoutSubtreeIfNeeded()
        let size = fittingSize
        frame = NSRect(x: card.maxX - size.width - 8, y: card.minY + 6, width: size.width, height: 24)
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.12)
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        block = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.12)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.block == nil { self?.isHidden = true }
            }
        }
    }

    private func rebuildMenu(current: String) {
        language.removeAllItems()
        // A pull-down's first item is its title.
        language.addItem(withTitle: Self.title(of: current))
        let plain = NSMenuItem(title: "Plain text", action: nil, keyEquivalent: "")
        plain.representedObject = ""
        plain.state = current.isEmpty ? .on : .off
        language.menu?.addItem(plain)
        language.menu?.addItem(.separator())
        for entry in Self.languages {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.representedObject = entry.id
            item.state = entry.id == current.lowercased() ? .on : .off
            language.menu?.addItem(item)
        }
    }

    @objc private func chooseLanguage(_ sender: NSPopUpButton) {
        guard let block, let id = sender.selectedItem?.representedObject as? String else { return }
        onSetLanguage?(block.location, id)
    }

    @objc private func copyCode() {
        guard let block else { return }
        onCopy?(block)
        copy.image = NSImage.symbol("checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.copy.image = NSImage.symbol("doc.on.doc", accessibilityDescription: "Copy Code")
            }
        }
    }
}
