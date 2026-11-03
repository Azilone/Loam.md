# Plugin permissions

What a plugin says it does, shown to the user before it runs. How plugins are loaded:
[PLUGIN-LOADING.md](PLUGIN-LOADING.md).

## Declared and shown, not enforced

Be clear about what this is. **A plugin runs in the app's process, with the app's access**: it can read and write any
file the app can, open network connections and start programs, whatever it declares. Swift has no sandbox inside a
process, and the plugin's code is not checked against its list.

So permissions are for **informed consent**: the plugin manager lists them, riskiest first, before the user turns a
plugin from the vault on, and keeps showing them on its row. A plugin that lies about them is a malicious plugin;
the list does not stop it. Enforcing them would need one of:

- out-of-process plugins (an XPC service or a helper per plugin, with its own sandbox profile), at the cost of
  passing every call across a process boundary;
- checks on the code before it is listed: static analysis of the imported modules and calls in the community
  catalog (see [ROADMAP.md](ROADMAP.md)), which can flag a plugin that declares `vault.read` and imports `Network`.

Until then: "Plugins from this vault run with the same access as the app. Only enable plugins you trust." The plugin
manager says this above the list. Safe mode never loads a plugin from the vault.

## The vocabulary

`PluginPermission` in PluginKit. A manifest lists raw values.

| Value | Shown as | Risk |
|---|---|---|
| `vault.read` | Read your notes | low |
| `vault.write` | Change your notes | medium |
| `disk.read` | Read files outside this vault | medium |
| `local-service` | Talk to programs running on your Mac (a local socket or port) | medium |
| `network` | Talk to servers on the internet | high |
| `shell` | Run programs on your Mac | high |
| `audio` | Record or play sound | medium |
| `clipboard` | Read and change the clipboard | medium |
| `ui` | Add views, panels and commands to the window | low |

A value the app does not know (a newer SDK, a typo) is kept, shown as "Unknown permission: x" and treated as high
risk. `DeclaredPermission` holds one entry (`.known` or `.unknown`); `DeclaredPermission.list` sorts a list riskiest
first and drops duplicates.

## Where they are declared

- **A plugin from the vault**: `permissions` in `.loam/plugins/<id>/plugin.json`, read before any code is loaded
  (`ThirdPartyPluginManifest.permissions`, the raw strings, and `declaredPermissions`).

  ```json
  { "id": "hello", "name": "Hello", "version": "0.1.0", "library": "HelloPlugin", "permissions": ["vault.read"] }
  ```

- **A built-in plugin**: `permissions:` in its `PluginManifest`, for the same list in the plugin manager. Every
  first-party plugin declares them honestly: `BuiltinPluginsTests` and `BuiltinUIPluginsTests` keep a list of the
  plugins that write notes and check it against `vault.write` (and that a command whose summary says it writes
  belongs to one of them). Add a permission when a plugin starts doing something new.

Declare what the plugin's own code does, including through services it calls: a UI plugin that moves notes through
the `files` service declares `vault.write`.

## In the plugin manager

Settings > Plugins lists the built-in plugins in two groups, Features (with an interface) and Services (what features
build on), then the vault's own, each row with its icon, its name, what it does (or why it is not running) and its
switch. A row opens the plugin's page: its switch, its settings, its permissions each with its icon and label (high
risk in orange), what it needs and provides, and its id. A vault plugin's page also has its folder, the load error in
words ("Built for another version of the app. Rebuild it."), Build or Rebuild, Reveal in Finder and Remove; under the
vault's list, a field installs one from a Git URL.

Turning a vault plugin on opens a sheet listing its permissions with their descriptions, the high-risk ones
highlighted, and Enable / Cancel; nothing is written to `.loam/config.json` before Enable. After `plugins.install`, the
same sheet asks "Enable it now?" (installing never enables). Rebuild runs `plugins.build` and shows the end of the
log when it fails; a plugin rebuilt while its old code is loaded runs only after a relaunch (code cannot be
unloaded), so the manager offers Relaunch. Remove asks first, then runs `plugins.remove` (to the Trash).

The buttons call the commands by id (`plugins.build`, `plugins.install`, `plugins.remove`). When the app has
no such command, the button is disabled and its tooltip says so. The model is `PluginManagerModel`
(`PluginManagerModel+Vault.swift`), tested in `PluginManagerVaultTests` with fake commands.
