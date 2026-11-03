# Loading third-party plugins

How the app and `loam` load a plugin built outside them: the runtime libraries, the build id and the loader, the SDK in
the app bundle, and `loam plugin new|build|install|remove`.

## A plugin

A plugin is a Swift package built as a dynamic library. It exports one C function returning its plugin types:

```swift
@_cdecl("loam_plugin_entry")
public func loamPluginEntry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(PluginEntry(plugins: [HelloPlugin.self])).toOpaque()
}
```

It is installed in the vault, so the vault stays portable:

```
.loam/plugins/<id>/plugin.json                 what the app lists (installed = this file exists)
.loam/cache/plugins/<id>/lib<Library>.dylib    its compiled code (.so on Linux); disposable, rebuilt from sources
```

```json
{ "id": "hello", "name": "Hello", "version": "0.1.0", "library": "HelloPlugin", "permissions": ["vault.read"] }
```

`id` must equal the folder name; every plugin type the entry returns must have that id or start with it and a dot
(`hello.extra`). `permissions` are stored; the plugin manager shows them before enabling ([PERMISSIONS.md](PERMISSIONS.md)).

`Examples/HelloPlugin` is a complete one: its `hello.count` command uses the `note-graph` service. Try it:

```bash
make app                                            # the app, with its `loam` and its SDK
loam="App/build/Loam.app/Contents/Helpers/loam"
mkdir -p /tmp/PluginVault
"$loam" --vault /tmp/PluginVault plugin install Examples/HelloPlugin   # copies, builds, installs (disabled)
"$loam" --vault /tmp/PluginVault plugin enable hello
"$loam" --vault /tmp/PluginVault hello.count
open "App/build/Loam.app" --args --vault /tmp/PluginVault
```

`scripts/build-example-plugin.sh <vault>` (`make example-plugin`) still builds the example from the checkout, for
`ExamplePluginTests`.

## Making, building and installing a plugin: `loam plugin`

The `plugins.new`, `plugins.build`, `plugins.install` and `plugins.remove` core commands (`Runtime+PluginPackages.swift`),
in the CLI, the palette and for agents; the CLI also spells them `loam plugin <verb>`:

| Command | Does | Returns |
|---|---|---|
| `loam plugin new <id> [--ui]` (`plugins.new id= name= ui=true`) | writes a package in `.loam/plugins/<id>/` (`PluginTemplate`) | `{id, path}` |
| `loam plugin build <id>` / `--all` (`plugins.build id=` / `all=true`) | compiles it into `.loam/cache/plugins/<id>/` | `{id, ok, library, log}` (an array for all) |
| `loam plugin install <url>` (`plugins.install url= build=false`) | `git clone --depth 1` (or copies a folder), checks plugin.json, moves it to `.loam/plugins/<id>/`, builds it | `{id, path, version, permissions, built, log}` |
| `loam plugin remove <id>` (`plugins.remove id=`) | moves `.loam/plugins/<id>` to `.trash/plugins/<id>` (`<id> 2`, ... when taken), deletes its cache, writes `"enabled": false` | `{id, trashedTo}` |
| `loam plugin list`, `loam plugin enable|disable <id>` | `plugins.list`, `plugins.enable`, `plugins.disable` | |

None of them enables a plugin (install even turns off a leftover `"enabled": true`): the user enables it after seeing
its permissions. Install refuses a source without a valid plugin.json and an id that is installed or built in.
They are registered with `thirdPartyPlugins` (the app and `loam`). Builds take a minute or more: the handlers wait for
them off the main actor and only hop to it to refresh the plugin list. A plugin already loaded keeps its old code until
the app relaunches (its row's `loadError` says so).

The generated package:

```
.loam/plugins/<id>/
  plugin.json                          id, name, version 0.1.0, library <Name>Plugin, permissions []
  Package.swift                        logic: tools 5.10, macOS 13 (builds on Linux); UI: tools 6.2, macOS 26
  Sources/<Name>/<Name>Plugin.swift    a command (`<id>.hello`), plus a panel for --ui; the C entry point
  Tests/<Name>Tests/                   one test, on PluginTestHarness or UIPluginHarness
  README.md, .gitignore
```

Its manifest finds the SDK with `ProcessInfo.processInfo.environment["LOAM_SDK"]`, defaulting to the SDK of
`/Applications/Loam.app` (so the package opens in Xcode), and links only the runtime products:
`LoamRuntime` from `.package(path: sdk)`, plus `LoamUIRuntime` from `.package(path: sdk + "/App")`
for a UI plugin. `Examples/HelloPlugin` uses the same convention, defaulting to this checkout.

## The SDK

A plugin compiles against the sources of the runtime that ships it; on macOS it then runs on later releases too
("Plugin SDK version"). `scripts/build-app.sh` ships them:

```
Loam.app/Contents/
  MacOS/Loam, Helpers/loam                   the app and its command line, both on ../Frameworks
  Frameworks/libLoam{,UI}Runtime.dylib
  Resources/SDK/loam/          about 1 MB: Package.swift, Package.resolved, Sources/,
                                         App/Package.swift, App/Package.resolved, App/Sources/
```

The snapshot gets its own stamped copy of `PluginRuntimeBuildID.swift`, holding the build id of the shipped runtime.
The folder is named `loam`, the package identity plugins reference (and App/ refers to with `..`). Tests,
CLI/, App/Executable/ and build folders are left out. SwiftPM does not need a dependency's test folders.

`PluginSDK.locate` finds it, first match wins:

1. `$LOAM_SDK` (an SDK missing there is an error, not a fallback);
2. the bundle of the running executable, symlinks resolved: `Contents/Resources/SDK/loam`;
3. a source checkout containing the running executable (`CLI/.build/release/loam`), then the checkout
   `LoamCore` was compiled from, when it still exists (development builds and tests).

`loam` in the bundle is built from `CLI/` with the same stamped sources and runs on the bundle's runtime (its rpath is
`@executable_path/../Frameworks`; `check-single-copy.sh` checks it with the libraries). Put it on the PATH with
`ln -s "/Applications/Loam.app/Contents/Helpers/loam" /usr/local/bin/loam`: the CLI then matches the app's runtime
and finds its SDK.

## The build

`PluginBuilder` (LoamCore, Foundation and `Process`, so it runs on Linux too):

1. reads and checks `.loam/plugins/<id>/plugin.json`;
2. copies the SDK's `Package.resolved` pins (root and App) into the plugin's, keeping the plugin's other pins:
   SwiftPM ignores a path dependency's `Package.resolved`, and a newer swift-markdown would be another runtime;
3. from a checkout (not a snapshot), stamps it with `scripts/stamp-build-id.sh` for the build and puts `dev` back,
   unless the running runtime is an unstamped `dev` build;
4. runs `swift build -c release --product <library> --scratch-path .loam/cache/build/<id>` in the plugin's folder with
   `LOAM_SDK=<sdk>`, the log in `.loam/cache/build/<id>.log` (progress lines are left out of the returned tail);
5. on macOS, refuses a library that uses the runtime libraries outside the plugin SDK ("Plugin SDK version");
6. copies `lib<library>.dylib` (`.loam`) to `.loam/cache/plugins/<id>/` through a rename, so a process that mapped the old
   file keeps a valid one; on macOS it first deletes the absolute rpaths and signs it ad hoc.

Each plugin compiles the runtime once in its scratch folder (about a minute, a few hundred MB, disposable). The first
build fetches swift-markdown and Yams from GitHub (SwiftPM caches them afterwards).

**The toolchain.** The build uses the `swift` on the PATH (the app, launched from the Finder, sees `/usr/bin`, which
is Xcode's selected toolchain). On macOS any Swift with a stable ABI will do; on Linux it must be the one the app was
built with: the build id covers `swift --version`, so a plugin built by another compiler is refused at load time with
"built for another version of the app ...: rebuild it with `loam plugin build`".

## One copy of every type: the runtime libraries

A first attempt shared only PluginKit as a dynamic library. The app still linked a static copy through the
kernel, so the process held two copies of every PluginKit type: the plugin loaded and ran, but
`context.service(.noteGraph)` returned nil, because the protocol of one copy is not the protocol of the other (macOS
logs "Class … is implemented in both").

So everything a plugin may import lives in exactly one image:

| Image | Package | Holds |
|---|---|---|
| `libLoamRuntime` | root, its only product | PluginKit, LoamCore, PluginKitTesting, LoamCLI, BuiltinPlugins, every logic plugin, swift-markdown, Yams |
| `libLoamUIRuntime` | `App/`, its only product | PluginKitUI, PluginKitUITesting, MarkdownEditor, WorkspaceModel, DebugProtocol, NotebookApp (the shell), BuiltinUIPlugins and every UI plugin |
| `loam` | `CLI/` | `main.swift` only; links the runtime |
| `Loam` (the app) | `App/Executable/` | `main.swift` only; links both runtimes |
| a plugin | its own package | its code; links the runtime (and the UI runtime for a UI plugin) |

Rules that keep it so:

- **Executables have their own packages.** SwiftPM links an executable with the targets of its own package
  statically, and a package cannot depend on its own product. So `loam` lives in `CLI/` and the app executable in
  `App/Executable/`, each depending on the dynamic products by path.
- **Clients only see the runtime products.** The root package has no other product, so nothing can link PluginKit
  statically next to the runtime. App targets depend on `LoamRuntime` (swift-markdown reaches them through
  it, so there is one copy of it too).
- **Tests are the exception, safely.** A test bundle links its package's targets statically and never loads the
  runtime libraries next to them. The test that runs a real plugin (`ExamplePluginTests`) does it in a `loam` process.
- **Checked.** `scripts/check-single-copy.sh` fails when two images define the same Swift type, protocol or
  Objective-C class; `scripts/build-app.sh` runs it on the bundle.

At run time the plugin's reference to `@rpath/libLoamRuntime.dylib` resolves to the image already loaded
under that install name. `loam plugin build` (and `scripts/build-example-plugin.sh`) deletes the plugin's rpaths to its build folder (which
holds another copy of the runtime) so nothing else can match.

**Build system.** All of this builds with SwiftPM's default build system (swiftbuild, Swift 6.4) and with the native
one (Swift 6.0 on Linux), so the Makefile and scripts use the default. A failure with the default build system
was not reproduced with this layout (one dynamic product per package, executables in their own packages); if it
comes back, `--build-system native` is the fallback.

**Cost.** App targets can no longer be limited by the manifest to the logic module they may import: they all depend
on the runtime product. The import rules of ARCHITECTURE.md hold by review.

## Plugin SDK version

A plugin compiled once keeps running when the app is updated, as long as the plugin SDK, `PluginKit` and
`PluginKitUI`, only gained API. Both modules are built with library evolution (`-enable-library-evolution`, Apple
platforms only), as Apple builds its own frameworks: a plugin reaches their types, protocols and methods through
symbols and runtime layout instead of compiled-in offsets, so a release can add fields, methods, enum cases and
protocol requirements with a default without breaking it. Checked on 2026-10-21: the example plugin, built
once, crashed after three additive changes to PluginKit without library evolution, and ran with it.

- **The version.** `PluginSDKVersion.current` (`Sources/PluginKit/PluginSDKVersion.swift`), `major.minor`, is
  recorded in every plugin by `PluginEntry(plugins:)` (`@_alwaysEmitIntoClient`, so it is the value the plugin was
  compiled against). The loader accepts the app's major version and a minor version up to the app's: an older minor
  is fine, a newer one "needs a newer version of the app … update Loam", another major (or a plugin from before
  versions) is "built for another version of the app … rebuild it".
- **The rule.** Add, never break. A new method, a new field with a default, a protocol requirement with a default
  implementation, a new case of a non-frozen enum: bump the minor version. Removing, renaming or changing an API, or
  a requirement without a default: add the new API next to the old one instead (contracts get a new id, as
  ARCHITECTURE.md says). A real break bumps the major version, and every plugin then needs a rebuild.
- **Checked.** `scripts/check-plugin-api.sh`, run by `make test` on macOS, builds both modules in release (a debug
  build exposes internal declarations), dumps their ABI with `swift-api-digester` and compares it with the baseline in
  `api/` (gzipped JSON and the version it describes). It fails on a break without a major bump and on an addition
  without a version bump. After bumping `PluginSDKVersion.current`, `make plugin-api` records the new baseline;
  commit it with the change.
- **Frozen enums.** A plugin must handle cases a later release adds: switching over an SDK enum needs
  `@unknown default` outside the SDK modules (the compiler says so). Enums that can never grow are `@frozen`
  (`PropertyValue`, JSON's kinds; `DeclaredPermission`, known or not). A frozen type can never change again.
- **Only the SDK.** Everything else in the runtime libraries (the kernel, the shell, the editor, first-party
  plugins, swift-markdown) changes with every release. `loam plugin build` refuses, on macOS, a library that takes
  symbols from them outside PluginKit and PluginKitUI (`nm -m -u`): "the plugin uses LoamCore, which is not part of
  the plugin SDK…".
- **The compiler.** Swift's ABI is stable on Apple platforms, so a plugin built by another Swift version runs too.

### The build id, on Linux

Linux has no stable ABI and the SDK is built without library evolution there, so a plugin works only with the exact
runtime it was compiled against (`PluginLoader.requiresSameBuild`). `PluginRuntime.buildID` names a runtime build;
`PluginEntry(plugins:)` records it too, and on Linux the loader refuses another one: "built for another version of the
app …: rebuild it with `loam plugin build`".

- The id lives in `Sources/PluginKit/PluginRuntimeBuildID.swift`, committed as `dev`.
  `scripts/stamp-build-id.sh` writes `<git short revision>-<hash>` there, the hash covering the sources and manifests
  of the root package and `App/`, the resolved dependencies and `swift --version`. `make release`
  (`build-cli.sh`), `build-example-plugin.sh` and a `LOAM_RELEASE=1` app build stamp, build, and put `dev` back in a
  trap. Any other `build-app.sh` leaves the checkout as `dev` and stamps only its SDK snapshot (a debug build's stays
  `dev`): macOS never compares ids, and stamping a PluginKit file rebuilt the whole runtime on the next build. Same sources and compiler
  give the same id, so plugins and the app built from one checkout match.
- `PluginRuntime.buildID` and `PluginEntry.init(plugins:)` are `@_alwaysEmitIntoClient`: the literal is compiled into
  the plugin. A default argument would not do: it is evaluated by the runtime loaded at run time, which always
  matches.
- Trade-offs: a plain `swift build` or `swift test` uses `dev`, so two dev builds of different sources accept each
  other's plugins (only stamped builds are protected). Tests are not in the hash.

## The loader

`PluginLoader` (LoamCore, Foundation, `dlopen` from Darwin or Glibc):

- `discover()` reads every `.loam/plugins/<id>/plugin.json` (`ThirdPartyPluginManifest`) and loads nothing.
- `load(_:)` opens `.loam/cache/plugins/<id>/lib<library>.dylib` with `dlopen`, calls `loam_plugin_entry`,
  checks the SDK version (the build id on Linux) and the plugin ids, and returns a `LoadedPlugin { manifest, types, source }` or a
  `LoadFailure { id, reason }`: not built, cannot be loaded, not a plugin (no entry symbol), built for another
  version, ids that are not its own, plugin.json missing or wrong. A bad file never stops the app.
- A library is opened once per process, cached by path and modification date. A rebuilt library needs a relaunch.
  Code cannot be unloaded: disabling a plugin deactivates it; its code stays mapped until the app quits.

`Runtime(…, thirdPartyPlugins: true)` (the CLI, and the app through `ShellConfiguration.thirdPartyPlugins`):

- Lists the vault's plugins in `plugins.list` with `source: "vault"` (built-in ones say `"builtin"`) and `loadError`
  when they cannot load (shown even while off, for "not built").
- **Off by default.** A vault plugin runs only when `.loam/config.json` says `"enabled": true` for its id (a type
  `hello.extra` follows `hello` unless it has its own flag). Its library is opened only then, so a disabled plugin's
  code never runs. `plugins.enable id=hello` writes the flag and loads it.
- **Safe mode never opens a vault library**, not even to list it; its row says
  "safe mode: plugins from the vault are not loaded".
- A load failure of an enabled plugin is reported like a failed activation (`lastReport.failed`, the CLI's warning).

## Signing

- The app bundle is signed with the Apple Development certificate when the build Mac has one (`LOAM_SIGN_IDENTITY`
  picks another), else ad hoc: libraries first (`Contents/Frameworks`), then the app with
  `App/Loam.entitlements`. The executable's rpath is `@executable_path/../Frameworks`; the build folder's
  absolute rpaths are removed.
- The entitlement `com.apple.security.cs.disable-library-validation` is only checked under the hardened runtime,
  which notarized distribution needs. There, macOS refuses a library signed by another team or ad hoc ("mapping
  process and mapped file have different Team IDs") unless the app has it. It is harmless in the ad hoc build and is
  in place for notarization. It weakens one protection, so the app only loads plugins from `.loam/plugins/` of the open
  vault, built on the machine, enabled by the user (after seeing their permissions).
- The `loam` in the app bundle is signed with the app's identity, with no hardened runtime; only the standalone
  `make release` CLI keeps the linker's ad hoc signature. It loads plugins as is.

## Installing `loam`

`make release` builds `CLI/.build/release/loam` with `libLoamRuntime.dylib` (`.so` on Linux) next to it;
`loam` finds it beside itself (rpath `@loader_path`, `$ORIGIN` on Linux). To install, copy both files into one folder
on the PATH. On a Mac with the app, link the app's `loam` instead (see "The SDK"): it matches the app's runtime and
builds plugins against the app's SDK.

## Safety

- The plugin manager shows source, permissions and load errors, and asks before enabling
  ([PERMISSIONS.md](PERMISSIONS.md)).
- A plugin that crashes at startup is caught by safe mode: two launches in a row that do not stay up 5 seconds
  (`LaunchGuard`) open the vault in safe mode, which never opens a vault library (see [ARCHITECTURE.md](ARCHITECTURE.md)).
