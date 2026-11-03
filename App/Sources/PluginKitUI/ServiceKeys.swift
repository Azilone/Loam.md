// Keys of the UI services. The first ones are host services: the shell provides them in the kernel's service
// registry before any plugin activates, so a plugin never needs to list them in `requires`. `editor` comes from
// a plugin.
//
// The service types are existentials (`any ViewRegistry`): the registry stores values as `Any` and casts back
// with `as? S`, which works for an existential `S` (tested in PluginKitUITests).

public extension ServiceKey where Service == any ViewRegistry {
    static var views: ServiceKey<any ViewRegistry> { ServiceKey<any ViewRegistry>("ui.views") }
}

public extension ServiceKey where Service == any PanelRegistry {
    static var panels: ServiceKey<any PanelRegistry> { ServiceKey<any PanelRegistry>("ui.panels") }
}

public extension ServiceKey where Service == any Workspace {
    static var workspace: ServiceKey<any Workspace> { ServiceKey<any Workspace>("ui.workspace") }
}

public extension ServiceKey where Service == any QuickPick {
    static var quickPick: ServiceKey<any QuickPick> { ServiceKey<any QuickPick>("ui.quick-pick") }
}

public extension ServiceKey where Service == any Toasts {
    static var toasts: ServiceKey<any Toasts> { ServiceKey<any Toasts>("ui.toasts") }
}

public extension ServiceKey where Service == any CommandLauncher {
    static var commands: ServiceKey<any CommandLauncher> { ServiceKey<any CommandLauncher>("ui.commands") }
}

public extension ServiceKey where Service == any EditorService {
    static var editor: ServiceKey<any EditorService> { ServiceKey<any EditorService>("editor") }
}
