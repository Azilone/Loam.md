import Foundation
import PluginKitUI
import SwiftUI

/// Registers one of everything a UI plugin can: a view for `test:` pages, a panel, a command and a slash item.
final class SampleUIPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.ui", name: "Test UI", version: "1.0", optionalRequires: ["editor"])
    @MainActor static var deactivations = 0

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        try context.registerView(ViewType(
            id: "test.view",
            title: "Test page",
            canOpen: { $0.kind == .virtual && $0.path.hasPrefix("test:") },
            makeView: { context in AnyView(Text(context.resource.name)) }
        ))
        try context.registerPanel(Panel(id: "test.panel", title: "Test", symbol: "star", slot: .trailing) {
            AnyView(Text("Panel"))
        })
        try context.registerCommand(Command(
            id: "test.hello",
            title: "Hello",
            summary: "Says hello, to check that commands reach the command center."
        ) { _ in "hello" })
        context.addSlashItem(SlashItem(id: "test.slash", title: "Stamp", symbol: "seal") { _, trigger in
            TextChange(range: trigger, replacement: "stamp", selection: NSRange(location: trigger.location + 5, length: 0))
        })
        context.addCodeBlockView(CodeBlockView(id: "test.live", languages: ["Live"]) { block in AnyView(Text(block.code)) })
    }

    @MainActor func deactivateUI() {
        Self.deactivations += 1
    }
}

protocol Greeter: AnyObject {
    func greet() -> String
}

extension ServiceKey where Service == any Greeter {
    static var greeter: ServiceKey<any Greeter> { ServiceKey<any Greeter>("test.greeter") }
}

/// A logic plugin providing a service.
final class GreeterPlugin: Plugin, Greeter {
    static let manifest = PluginManifest(id: "test.greeter-provider", name: "Greeter", version: "1.0", provides: ["test.greeter"])

    init() {}

    func activate(context: PluginContext) throws {
        try context.provide(.greeter, self)
    }

    func greet() -> String { "hi" }
}

/// A UI plugin that requires the greeter, so it goes down with its provider.
final class GreetingViewPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.greeting-view", name: "Greeting view", version: "1.0", requires: ["test.greeter"])

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        guard let greeter = context.service(.greeter) else { return }
        let text = greeter.greet()
        try context.registerView(ViewType(
            id: "test.greeting",
            title: "Greeting",
            priority: 5,
            canOpen: { $0.path == "greeting:" },
            makeView: { _ in AnyView(Text(text)) }
        ))
    }
}

/// Opens a resource as soon as it starts, to check the workspace reaches plugins.
final class OpenerPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.opener", name: "Opener", version: "1.0")

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        context.workspace?.open(.virtual("test:welcome"), placement: .beside)
    }
}
