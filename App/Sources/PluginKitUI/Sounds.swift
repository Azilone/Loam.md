import Foundation

/// A short sound the app plays when something the user did lands: a task checked, a note thrown away, a block
/// dropped. A cue names the moment, not the sound: the plugin that plays them picks the sound, and a vault without
/// that plugin stays silent.
///
/// Only for moments that finish something, at most a few times a minute. Never for typing, hovering, scrolling,
/// opening a menu or passing a slot while dragging: those come back too often to stay pleasant.
public enum SoundCue: String, CaseIterable, Sendable {
    /// A task or a habit marked done.
    case done
    /// The last open task of the vault, or the last habit of a day, marked done: played instead of `done`.
    case allDone
    /// A task or a habit marked not done again; quieter than `done`.
    case undone
    /// A note, a folder or a card made.
    case created
    /// Something moved to the trash.
    case trashed
    /// Something brought back from the trash.
    case restored
    /// The trash emptied for good.
    case emptied
    /// A block, a card or a row picked up to drag it.
    case pickedUp
    /// A dragged block, card, note or tab let go in a new place.
    case dropped
    /// Something put on the clipboard: a link, a path.
    case copied
    /// A file (a picture, a PDF) dropped or pasted into a note.
    case attached
    /// Work that ran on its own finished well: a success toast (a picture optimized).
    case succeeded
    /// Something the user asked for could not be done.
    case failed
    /// A recording started.
    case recordingStarted
    /// A recording stopped and its note is ready.
    case recordingFinished
    /// Text highlighted: a marker's stroke, played as the highlight draws itself across the words.
    case highlighted
}

/// Plays the cues. The sounds plugin installs one in `Sounds.player`; nothing is played without it.
@MainActor
public protocol SoundPlayer: AnyObject {
    func play(_ cue: SoundCue)
}

/// Where any part of the app plays a cue, from a plugin or from the editor, the way `Haptics` gives its ticks:
///
///     Sounds.play(.done)
///
/// Cues closer together than `minimumGap` are dropped, so a command that checks twenty tasks at once plays once.
@MainActor
public enum Sounds {
    /// The player of the sounds plugin while it is active; nil, and every cue silent, otherwise.
    public static var player: (any SoundPlayer)?

    static let minimumGap: TimeInterval = 0.06
    private static var last: TimeInterval = -.infinity

    /// Whether the vault still has an open task; the tasks plugin answers it while active. Without it a check is
    /// never the last one.
    public static var openTasksLeft: (() -> Bool)?

    /// A task checked (`done`, or `allDone` when no open task is left in the vault) or unchecked (`undone`).
    public static func taskChecked(done: Bool) {
        play(!done ? .undone : openTasksLeft?() ?? true ? .done : .allDone)
    }

    public static func play(_ cue: SoundCue) {
        guard let player else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= minimumGap else { return }
        last = now
        player.play(cue)
    }
}
