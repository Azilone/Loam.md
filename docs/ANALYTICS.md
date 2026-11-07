# Anonymous analytics

Loam counts how it is used on its own [Umami](https://umami.is) server (`pulse.personalize.design`): no third party,
no cookie, **no identifier**. Two events of the same person cannot be tied together, except by the server's own daily
session (a hash of the address and the agent, not stored). So there is no retention curve; there are counts.

- **What can leave**: only the events below, with plain properties: Loam's version, the macOS version, a count as a
  range ("50-199 notes"), the id of a built-in plugin, command or theme. Never a note, a file name, a vault path, a
  name the user typed, or the name of a third-party plugin, command or theme. The server derives a country from the
  request's IP address and does not store the address.
- **Enforced in code**: `AppAnalytics.allowedEvents` is the whole list (a plugin cannot add to it), and
  `AppAnalytics.sanitized` drops every property that is not an identifier or a number (letters, digits, `. _ - + , :`,
  64 characters). A property named `<x>_count` is turned into a range before it leaves (`ranged`).
- **On by default**, off with Settings > About > Send anonymous analytics. Nothing leaves in the first two minutes of
  a run: what happens meanwhile waits, and is dropped if the user turned analytics off in the meantime (the first
  launch plays an intro, where they can). Stored as `sendAnonymousAnalytics` in `UserDefaults`.
- **Release builds only**: `scripts/build-app.sh` writes `LoamAnalyticsURL` and `LoamAnalyticsWebsiteID` to Info.plist
  when `LOAM_RELEASE=1`. A development build or a test run has neither, so it sends nothing
  (`LOAM_ANALYTICS_URL` and `LOAM_ANALYTICS_WEBSITE_ID` point a release at another server).

## The events

| Event | When | Properties |
| --- | --- | --- |
| `app_launch` | 2 minutes after the start | `version`, `build`, `previous_version` (after an update), `macos`, `arch`, `appearance`, `theme` (built-in only), `channel`, `auto_update`, `first_run`, `has_obsidian`, `safe_mode`, `location` (icloud, documents, desktop, cloud_storage, external, other), `vaults` and `notes` and `plugins_vault` (ranges), `plugins_off` and `plugins_failed` (built-in plugin ids) |
| `session_end` | at quit, after at least two minutes | `duration`, `commands_used` and `notes_created` (ranges) |
| `command_used` | the first time a command Loam ships runs in a run | `command` |
| `plugin_toggled` | a built-in plugin turned on or off | `plugin`, `enabled` |
| `theme_changed` | a built-in theme picked | `theme` |
| `onboarding_step` | a card done, skipped, left by Back or moved to another folder | `step`, `action`, and the choice: `folder` (kind only), `preset`, `look`, `tools`, `prompt_copied`, `obsidian` |
| `onboarding_finished` | the last card done | `prompt_copied` |
| `import_finished` | an Obsidian import ends | `source`, `ok`, `notes_count` (range), `agent` |
| `update_ready`, `update_failed` | the update check downloaded a release, or failed | `version` |
| `safe_mode_entered` | the vault started in safe mode on its own, after crashes | none |

`notes_created` counts new `.md` files that arrive a few at a time (someone writing); an import or a sync is not
counted.

## Adding an event

1. Add its name to `AppAnalytics.allowedEvents`.
2. From the app: `analytics.track("name", ["key": "value"], once: "key")` (`once` counts it once per run).
   From a plugin: `context.emit(UsageEvent("name", ["key": "value"]))` (`PluginKitUI`); the app listens in
   `AppModel+Analytics.listenForUsage`.
3. Properties are ids or numbers. A number goes in a key ending `_count`, so it leaves as a range.
4. Add a row to the table above, and to the website's Privacy Policy when the kind of data is new.

## Where it lives

`App/Sources/NotebookApp/Analytics/AppAnalytics.swift` (sending, queue, anonymity) and `AppModel+Analytics.swift` (the
facts and the commands); tests in `AppAnalyticsTests`.

- **Server side**: Umami runs in the `analytics` namespace on vps-prod. The site `Loam — app (macOS)` takes these
  events, `Loam — landing` takes the website's page views (`loam.getpawtrait.com`).
- The agent string is browser-shaped (`Mozilla/5.0 … Loam/<version>`): Umami answers `{"beep":"boop"}` and drops the
  event when it takes the client for a bot.

The website (`landing-page-loam`) has the same box in its cookie banner, and says so in its Privacy Policy.
