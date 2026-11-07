import AssistantPlugin
import Foundation
import PluginKit
import PluginKitUI
import SwiftUI

/// The Assistant's face: Craft's floating bubble at the window's bottom right, which grows into the chat panel
/// (`assistant.toggle`, ⌘J). Everything goes through the `assistant` service, so `assistant.*` does the same.
public final class AssistantUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "assistant-ui",
        name: "Assistant Panel",
        version: "0.1.0",
        description: "The Assistant's bubble and chat panel, as Craft's.",
        icon: "sparkles",
        requires: ["assistant"],
        permissions: ["ui", "vault.read"]
    )

    /// Internal: lets the tests reach the model. Not a contract.
    static var modelKey: ServiceKey<AssistantModel> { ServiceKey("assistant-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let engine = context.service(.assistant) else { throw AssistantUIError.serviceMissing }
        let model = AssistantModel(engine: engine)
        context.effect { MainActor.assumeIsolated { model.close() } }
        model.defaultAgent = {
            let settings = engine.settings()
            return (engine.catalog.defaultAgent(setting: settings.agent), settings.model, settings.agentMode)
        }
        model.openNote = { [weak context] path in context?.workspace?.open(.file(path), placement: .replace) }
        model.openSettings = { [weak context] in context?.openSettings(pluginID: "assistant") }
        model.listFolders = { [weak context] in
            ((try? context?.vault.list("")) ?? [])
                .filter { $0.isFolder && !$0.path.hasPrefix(".") }
                .map(\.path)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        model.listNotes = { [weak context] in (try? context?.vault.markdownPaths()) ?? [] }
        model.setActiveNote(Self.notePath(context.workspace?.activeResource))
        model.pickPrompt = { [weak context, weak model] in
            guard let model else { return "none" }
            model.refreshPrompts()
            let prompts = model.prompts
            guard !prompts.isEmpty else {
                context?.toasts?.show("No saved prompts yet: add one in Settings > Assistant.", kind: .info)
                return "none"
            }
            context?.quickPick?.show(
                placeholder: "Run a saved prompt",
                items: { query in
                    Fuzzy.rank(prompts, query: query) { $0.label }
                        .map { QuickPickItem(id: $0.id, title: $0.label, subtitle: $0.prompt, symbol: "text.bubble") }
                }
            ) { [weak model] item in
                guard let model, let prompt = prompts.first(where: { $0.id == item.id }) else { return }
                if !model.isOpen { model.open() }
                model.send(prompt.prompt)
            }
            return "picking"
        }
        try context.provide(Self.modelKey, model)

        try context.addSettingsSection(SettingsSection(
            id: "assistant.agents", pluginID: "assistant", title: "Agents",
            subtitle: "The coding agents on this Mac. Each uses its own sign-in and plan; Loam never sees them.",
            order: 0
        ) { AnyView(AgentsSettings(model: model)) })
        try context.addSettingsSection(SettingsSection(
            id: "assistant.prompts", pluginID: "assistant", title: "Saved Prompts",
            subtitle: "Save up to \(PromptStore.maxPrompts) prompts with up to \(PromptStore.maxLength) characters each.",
            order: 1
        ) { AnyView(SavedPromptsSettings(model: model)) })
        try context.addSettingsSection(SettingsSection(
            id: "assistant.instructions", pluginID: "assistant", title: "Instructions",
            subtitle: "Added to every chat. Kept in .loam/ai/instructions.md.",
            order: 2
        ) { AnyView(InstructionsSettings(model: model)) })

        try context.addWindowOverlay(WindowOverlay(id: "assistant.bubble", corner: .bottomTrailing) {
            AnyView(AssistantOverlay(model: model))
        })

        context.on(EditorSelectionChanged.self) { [weak model] event in
            let (path, text) = (event.path, event.text)
            onMain { model?.selectionChanged(path: path, text: text) }
        }
        context.on(ActiveResourceChanged.self) { [weak model] event in
            let path = Self.notePath(event.resource)
            onMain { model?.setActiveNote(path) }
        }

        try context.registerCommand(Command(
            id: "assistant.toggle",
            title: "Assistant",
            summary: "Opens or closes the Assistant panel at the window's bottom right. Returns open or closed.",
            shortcut: KeyShortcut("j", [.command])
        ) { _ in
            await MainActor.run {
                model.toggle()
                return model.isOpen ? "open" : "closed"
            }
        })

        try context.registerCommand(Command(
            id: "assistant.new-chat",
            title: "New Assistant Chat",
            summary: "Opens the Assistant panel on a new, empty chat."
        ) { _ in
            await MainActor.run {
                model.startNewChat()
                if !model.isOpen { model.open() }
                return model.chat.id
            }
        })

        try context.registerCommand(Command(
            id: "assistant.run-prompt",
            title: "Run Saved Prompt…",
            summary: "Picks one of the saved prompts (.loam/ai/prompts/) and sends it in the Assistant panel, with the "
                + "open note as context."
        ) { _ in
            await MainActor.run { model.pickPrompt() }
        })
    }

    /// The vault path of a Markdown note, or nil for anything else.
    static func notePath(_ resource: Resource?) -> String? {
        guard let resource, resource.kind == .file, resource.path.lowercased().hasSuffix(".md") else { return nil }
        return resource.path
    }
}

enum AssistantUIError: Error {
    case serviceMissing
}

/// Runs main-actor code from an event listener; the kernel calls them on the main thread.
private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}
