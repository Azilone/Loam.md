import AppKit
import PluginKitUI

/// Interface sounds: a short, quiet sound when something the user did lands (a task checked, a note thrown away, a
/// block dropped, a recording done). It installs the player behind `Sounds.play`, so the editor and the other plugins
/// name a moment (`SoundCue`) and this plugin picks the sound; turned off or removed, the app is silent again.
///
/// It also follows the Mac: no sound when "Play user interface sound effects" is off in System Settings > Sound.
public final class SoundsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "sounds-ui",
        name: "Sounds",
        version: "0.1.0",
        description: "Short, quiet sounds when a task is checked, a note trashed or a block dropped.",
        icon: "speaker.wave.2",
        permissions: ["ui", "vault.read"],
        settings: [
            SettingDescription(
                "enabled", title: "Play sounds", help: "Also off when the Mac's interface sound effects are off.",
                default: .bool(true)
            ),
            SettingDescription(
                "volume", title: "Volume", help: "From 0 (silent) to 1 (the sounds as recorded).", default: .number(1)
            ),
        ]
    )

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let player = CuePlayer()
        player.apply(context.settings.value(default: SoundsSettings()))
        Sounds.player = player
        context.effect {
            MainThread.run { if Sounds.player === player { Sounds.player = nil } }
        }

        let id = Self.manifest.id
        context.on(PluginSettingsChanged.self) { [weak player, weak context] event in
            guard event.pluginID == id, let settings = context?.settings.value(default: SoundsSettings()) else { return }
            MainThread.run { player?.apply(settings) }
        }
    }
}

struct SoundsSettings: Codable, Equatable {
    var enabled = true
    var volume = 1.0
}

/// The sound of each cue, a file in `Resources/Sounds`.
extension SoundCue {
    var soundName: String {
        switch self {
        case .done: "latch1"
        case .allDone: "welcome"
        case .undone: "pressToggle"
        case .created: "mechNavigate"
        case .trashed: "pressClose"
        case .restored: "pressLoading"
        case .emptied: "mechCount"
        case .pickedUp: "drag"
        case .dropped: "drop"
        case .copied: "copied"
        case .attached: "land"
        case .succeeded: "bubbleSuccess"
        case .failed: "bubbleError"
        case .recordingStarted: "ready"
        case .recordingFinished: "chime"
        case .highlighted: "highlighted"
        }
    }
}

/// Plays the cues with `NSSound`, each loaded once, on first use.
@MainActor
final class CuePlayer: SoundPlayer {
    private(set) var enabled = true
    private(set) var volume: Float = 1
    /// The cues played, newest last: what the tests read.
    private(set) var played: [SoundCue] = []
    private var sounds: [SoundCue: NSSound] = [:]

    /// Whether the Mac plays interface sound effects (System Settings > Sound); on when never set.
    var systemAllows: () -> Bool = {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }

    func apply(_ settings: SoundsSettings) {
        enabled = settings.enabled
        volume = Float(min(max(settings.volume, 0), 1))
    }

    func play(_ cue: SoundCue) {
        guard enabled, volume > 0, systemAllows() else { return }
        played.append(cue)
        guard let sound = sound(for: cue) else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    private func sound(for cue: SoundCue) -> NSSound? {
        if let sound = sounds[cue] { return sound }
        guard let url = Self.url(of: cue),
              let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        sounds[cue] = sound
        return sound
    }

    /// The file of `cue`'s sound in `Resources/Sounds`, a `.wav` or an `.m4a`.
    static func url(of cue: SoundCue) -> URL? {
        ["wav", "m4a"].lazy.compactMap { bundle?.url(forResource: cue.soundName, withExtension: $0, subdirectory: "Sounds") }.first
    }

    /// This module's resources, looked up where SwiftPM's `Bundle.module` looks (the app's resources, next to the
    /// library, the build folder) without its `fatalError` when they are missing; nil, and silence, then.
    static let bundle: Bundle? = {
        let name = "LoamApp_SoundsUI.bundle"
        let library = Bundle(for: CuePlayer.self)
        let places = [Bundle.main.resourceURL, library.resourceURL, Bundle.main.bundleURL, library.bundleURL.deletingLastPathComponent()]
        for case let place? in places {
            if let bundle = Bundle(url: place.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()
}

