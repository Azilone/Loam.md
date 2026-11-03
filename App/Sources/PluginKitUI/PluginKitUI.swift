// The UI contracts plugins build against: what a view shows (`Resource`), how it is built (`ViewType`), where it
// goes (`Workspace`, `Panel`), how to ask the user to pick (`QuickPick`), the editor (`EditorService`) and the
// theme (`ThemeTokens`). The shell implements them; a plugin only sees these protocols, through its context.
// See docs/ARCHITECTURE.md, "Contracts".
//
// PluginKit is re-exported so a UI plugin needs a single import. It is a Swift 5 module whose types are not
// `Sendable`; the kernel is main-thread only, which is also the actor every UI contract here is isolated to.
// Where Swift 6 cannot see that (`UIPlugin`'s default `activate`), the code says so and checks it at run time.
@_exported import PluginKit
