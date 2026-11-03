# Updates

How Loam and the plugins people write for it stay up to date on other people's Macs, with no server of our own:
every file is static, on GitHub.

## Installing Loam

`curl -fsSL https://loam.md/install.sh | bash` (the landing page's `public/install.sh`) reads the stable feed,
downloads the release zip with curl, checks its SHA-256, puts Loam.app in `/Applications` (or `~/Applications`),
links `loam` into `~/.local/bin` and opens the app.

The app is signed with the Apple Development certificate when the build Mac has one (ad hoc otherwise), not with a
Developer ID, and it is not notarized. A file a browser
downloads is quarantined, and macOS then refuses to open an app that is not notarized until the user allows it in
System Settings > Privacy & Security ("Open Anyway"). A download made by curl is not quarantined, so the script's
install opens at once. A zip downloaded from a browser still works, through "Open Anyway". Notarization (Apple
Developer Program) removes that step; nothing else here changes with it.

## The app: `AppUpdater`

- A feed per channel, `stable.json` and `beta.json`, at `LoamUpdateFeed` (Info.plist): version, build number, zip
  URL, size, SHA-256, Ed25519 signature, minimum macOS, notes. A higher build number is an update.
- Every zip is checked against the Ed25519 public key built into the app (`App/Resources/update-public-key.txt`,
  `LoamUpdatePublicKey`): only a release signed with the project's private key installs.
- Checked 30 s after launch, then daily (Settings > About: channel, automatic checks, Check Now, Restart to
  Update; the app menu's Check for Updates…). A newer release is downloaded, verified and unpacked in the background;
  Restart to Update closes the vault, a small script swaps the bundle once the app has quit, and the new version
  opens on the same vault.
- Only a release build (`LOAM_RELEASE=1`) carries the feed and the key: a development build never updates itself.

Releasing: `scripts/release.sh <version> [--beta] [--publish]` builds the app (build number = commit count), zips
it, signs it with the key at `~/.config/loam/update-ed25519.key` and writes `dist/feed/{stable,beta}.json`. A stable
release goes to both channels. `--publish` makes a GitHub release of the public `Azilone/loam-releases` and commits
the feed there. `swift scripts/update-key.swift` makes and reads the key. Losing the private key means shipping a
release with a new public key by hand: keep a copy of it somewhere safe.

`make dist` is the other path: `scripts/notarize.sh` signs with a Developer ID certificate under the hardened runtime,
notarizes and staples the app, and writes `dist/Loam-<version>.zip`. It needs that certificate, `LOAM_SIGN_IDENTITY`
set to it, and a `loam-notary` notarytool profile (the script's header says how to create them).

## Third-party plugins: from their git repository

- `plugins.install` from git takes the highest release tag (`v1.2.0`; `ref=` picks another) and writes
  `.loam/plugins/<id>/.loam-origin.json`: source, ref, commit, catalog, autoUpdate. Without tags a plugin follows
  its default branch, commit by commit. A plugin installed before origins existed gets one from its clone's git.
- `minSDK` in plugin.json: a version that needs a newer app is shown as such and never installed.
- `plugins.outdated` asks `git ls-remote` for newer tags (no download). `plugins.update` clones the new version into
  staging, builds it in place of the old one, keeps the old one in `.loam/cache/previous/<id>/` and puts it back
  when the build fails. `plugins.rollback` swaps the two again.
- An update that asks for new permissions disables the plugin: it runs again only once the user enables it after
  seeing them. `same-permissions=true` skips such an update instead (what automatic updates use).
- The app checks a minute after a vault opens, then daily: plugins set to update automatically
  (`plugins.auto-update`) are updated, a toast announces the others; Settings > Plugins shows an Update badge, and a
  plugin's page has Update, Update automatically and Roll Back.
- CLI: `loam plugin outdated | update <id> | update --all | rollback <id>`.

## The catalog

- A public repository, `Azilone/loam-community`, whose `index.json` lists plugins and their versions, each pinned to
  a commit (`Examples/PluginCatalog` is its template: README, `check.py`, the CI workflow). A plugin or a version is
  added by pull request; `check.py` verifies that each tag points to its commit and that plugin.json matches.
- `plugins.catalog` lists it, `plugins.install id=` installs from it and refuses any commit the catalog did not pin
  (a moved tag, a taken-over repository); updates of a catalog plugin follow the catalog, not the repository's tags.
  Settings > Plugins shows the catalog's plugins with Install. `LOAM_PLUGIN_CATALOG` points at another catalog.
- Not yet: the catalog file is fetched over HTTPS from GitHub but not signed; plugins are still compiled on each Mac,
  so a logic plugin needs Swift 5.10 or later and a UI plugin needs Swift 6.2 (prebuilt libraries per SDK version would remove that).
