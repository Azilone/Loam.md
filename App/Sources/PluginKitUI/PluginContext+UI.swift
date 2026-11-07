public enum UIContractError: Error, Equatable {
    /// The host service with this id is not in the kernel: the plugin runs outside the app or its test harness.
    case registryMissing(String)
}

/// UI registration through the plugin's context. Each helper registers the undo as an `effect`, so unloading
/// the plugin removes what it added; a plugin never cleans up by hand.
///
/// Effects run when the host disposes the plugin's scope, which the app does on the main thread; the
/// `assumeIsolated` in them states that rather than hopping, so a removal happens before `deactivate` returns.
@MainActor
public extension PluginContext {
    /// Registers a view type. Throws `UIContractError.registryMissing("ui.views")` without the shell.
    func registerView(_ type: ViewType) throws {
        guard let registry = service(.views) else {
            throw UIContractError.registryMissing(ServiceKey<any ViewRegistry>.views.id)
        }
        let remove = registry.register(type)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Registers a panel. Throws `UIContractError.registryMissing("ui.panels")` without the shell.
    func registerPanel(_ panel: Panel) throws {
        guard let registry = service(.panels) else {
            throw UIContractError.registryMissing(ServiceKey<any PanelRegistry>.panels.id)
        }
        let remove = registry.register(panel)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Adds a row to the navigation group at the top of the left sidebar. Throws
    /// `UIContractError.registryMissing("ui.panels")` without the shell.
    func addSidebarLink(_ link: SidebarLink) throws {
        guard let registry = service(.panels) else {
            throw UIContractError.registryMissing(ServiceKey<any PanelRegistry>.panels.id)
        }
        let remove = registry.register(link)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Adds a section (title and rows) to the left sidebar, under the navigation group. Throws
    /// `UIContractError.registryMissing("ui.panels")` without the shell.
    func addSidebarSection(_ section: SidebarSection) throws {
        guard let registry = service(.panels) else {
            throw UIContractError.registryMissing(ServiceKey<any PanelRegistry>.panels.id)
        }
        let remove = registry.register(section)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Offers a kind of note in the page toolbar's "+" menu and in folders' menus. Throws
    /// `UIContractError.registryMissing("ui.panels")` without the shell.
    func addNewItem(_ item: NewItem) throws {
        guard let registry = service(.panels) else {
            throw UIContractError.registryMissing(ServiceKey<any PanelRegistry>.panels.id)
        }
        let remove = registry.register(item)
        effect { MainActor.assumeIsolated { remove() } }
    }

    var workspace: (any Workspace)? { service(.workspace) }
    var quickPick: (any QuickPick)? { service(.quickPick) }
    var toasts: (any Toasts)? { service(.toasts) }
    /// Nil until an editor plugin is active. List `editor` in `optionalRequires` to be restarted when it comes.
    var editor: (any EditorService)? { service(.editor) }

    /// Adds an item to the `/` menu, removed on unload. Does nothing without an editor: slash items are an
    /// extra, so their absence is not an error.
    func addSlashItem(_ item: SlashItem) {
        guard let editor else { return }
        let remove = editor.addSlashItem(item)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Adds a section to the `@` menu, removed on unload. Does nothing without an editor, as `addSlashItem`.
    func addMentionSource(_ source: MentionSource) {
        guard let editor else { return }
        let remove = editor.addMentionSource(source)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Draws fenced code blocks of some languages as pictures, removed on unload. Does nothing without an editor
    /// (or with one that draws no pictures).
    func addCodeBlockRenderer(_ renderer: CodeBlockRenderer) {
        guard let editor else { return }
        let remove = editor.addCodeBlockRenderer(renderer)
        // The cards draw the note's blocks as the editor does.
        let removePreview = CodeBlockPreviews.shared.add(renderer)
        effect { MainActor.assumeIsolated { remove(); removePreview() } }
    }

    /// Takes the files dropped or pasted into notes, removed on unload. Does nothing without an editor.
    func addFileDropHandler(_ handler: FileDropHandler) {
        guard let editor else { return }
        let remove = editor.addFileDropHandler(handler)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Shows image links to some file types as embeds (pictures, players), removed on unload. Does nothing without
    /// an editor (or with one that shows no embeds).
    func addEmbedRenderer(_ renderer: EmbedRenderer) {
        guard let editor else { return }
        let remove = editor.addEmbedRenderer(renderer)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Shows fenced code blocks of some languages as live views, removed on unload. Does nothing without an editor
    /// (or with one that has no live views).
    func addCodeBlockView(_ view: CodeBlockView) {
        guard let editor else { return }
        let remove = editor.addCodeBlockView(view)
        let removePreview = CodeBlockPreviews.shared.addView(languages: view.languages)
        effect { MainActor.assumeIsolated { remove(); removePreview() } }
    }

    /// Lays a view over every note's page, removed on unload. Does nothing without an editor (or with one that has
    /// no page overlays).
    func addPageOverlay(_ overlay: PageOverlay) {
        guard let editor else { return }
        let remove = editor.addPageOverlay(overlay)
        effect { MainActor.assumeIsolated { remove() } }
    }
}
