import AppKit
import AVFoundation
import PluginKitUI
import SwiftUI

/// Plays the intro: every other app hidden, Loam's windows put away, a borderless window above
/// everything on the main screen drawing `IntroScene` over the live desktop, with its music. Return, Escape or "Skip
/// Intro" jumps to the welcome page, and again closes it; it also closes a few seconds after the welcome settles.
/// Afterwards the hidden apps and Loam's windows come back.
@MainActor
final class IntroPlayer {
    static let shared = IntroPlayer()

    /// How long the welcome page stays before the intro hands over to Loam.
    static let holdAfterWelcome: Double = 3.0

    private var window: IntroWindow?
    private var hiddenApps: [NSRunningApplication] = []
    private var loamWindows: [NSWindow] = []
    private var music: AVAudioPlayer?
    private let clock = IntroClock()
    /// The first launch's choices, which keep the welcome window up until one is made.
    private var onboarding: IntroOnboarding?

    var isPlaying: Bool { window != nil }
    /// The intro's window, for a sheet (the folder panel) to come down from.
    var sheetWindow: NSWindow? { window }

    /// Plays from `time` (0: the start; `IntroScene.welcomeStart`: the welcome page, without the music).
    func play(onboarding: IntroOnboarding? = nil, at time: Double = 0) {
        if let window, let onboarding { return handOver(to: onboarding, in: window) }
        guard window == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        self.onboarding = onboarding
        onboarding?.finish = { [weak self] in self?.finish() }
        let assets = IntroAssets.shared

        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0 != NSRunningApplication.current
        }
        hiddenApps.forEach { $0.hide() }
        loamWindows = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        loamWindows.forEach { $0.orderOut(nil) }

        let window = IntroWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.onKey = { [weak self] escape in
            if escape, let onboarding = self?.onboarding, self?.clock.time ?? 0 >= IntroScene.welcomeStart {
                onboarding.back()
            } else {
                self?.advance()
            }
        }
        window.onArrow = { [weak self] dx, dy in
            guard let self, clock.time >= IntroScene.settled else { return }
            self.onboarding?.arrow(dx: dx, dy: dy)
        }
        window.contentView = NSHostingView(rootView: IntroRoot(
            clock: clock, assets: assets, onboarding: onboarding,
            skip: { [weak self] in self?.advance() },
            toggleMute: { [weak self] in self?.toggleMute() }
        ))
        window.setFrame(screen.frame, display: true)
        self.window = window

        // Reduce Motion: no camera, the welcome page fades in at once.
        clock.start(at: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? IntroScene.welcomeStart : time)
        if time == 0, let url = assets.music, let player = try? AVAudioPlayer(contentsOf: url) {
            player.currentTime = clock.time
            player.play()
            music = player
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        scheduleEnd()
    }

    /// The onboarding of the vault that just opened in place of the last one (another folder picked): it takes the
    /// welcome window as it is, so nothing closes or flashes, and the vault's new window waits behind it.
    private func handOver(to onboarding: IntroOnboarding, in window: IntroWindow) {
        self.onboarding = onboarding
        onboarding.finish = { [weak self] in self?.finish() }
        let fresh = NSApp.windows.filter { $0.isVisible && $0 !== window && !($0 is NSPanel) }
        fresh.forEach { $0.orderOut(nil) }
        loamWindows = loamWindows.filter(\.isVisible) + fresh
        window.contentView = NSHostingView(rootView: IntroRoot(
            clock: clock, assets: .shared, onboarding: onboarding,
            skip: { [weak self] in self?.advance() },
            toggleMute: { [weak self] in self?.toggleMute() }
        ))
        focus()
    }

    /// Before the welcome page: jump to it. On it: close, or during onboarding take its main choice.
    func advance() {
        guard window != nil else { return }
        if clock.time < IntroScene.welcomeStart {
            clock.jump(to: IntroScene.welcomeStart)
            music?.setVolume(0, fadeDuration: 1.2)
            scheduleEnd()
        } else if let onboarding {
            if clock.time >= IntroScene.settled { onboarding.primary() }
        } else {
            finish()
        }
    }

    private func toggleMute() {
        guard let music else { return }
        music.volume = music.volume > 0 ? 0 : 1
        clock.isMuted = music.volume == 0
    }

    private var endTask: Task<Void, Never>?

    private func scheduleEnd() {
        endTask?.cancel()
        // Onboarding waits for the user's choice.
        guard onboarding == nil else { return }
        let remaining = IntroScene.settled + Self.holdAfterWelcome - clock.time
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(remaining, 0)))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// Takes the keyboard back, so Return still reaches the intro after Loam opened a page behind it.
    func focus() {
        guard let window, !window.isKeyWindow else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the intro at once, its window gone without the fade: the vault is about to change under it.
    func stop() {
        guard let window else { return }
        finish()
        window.orderOut(nil)
    }

    private func finish() {
        guard let window else { return }
        endTask?.cancel()
        self.window = nil
        onboarding = nil
        music?.setVolume(0, fadeDuration: 0.5)
        hiddenApps.forEach { $0.unhide() }
        hiddenApps = []
        for loamWindow in loamWindows.reversed() { loamWindow.orderFront(nil) }
        loamWindows.first?.makeKeyAndOrderFront(nil)
        loamWindows = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                window.orderOut(nil)
                self?.music?.stop()
                self?.music = nil
            }
        }
    }
}

/// The intro's time, shared by the window's view and the player.
@MainActor @Observable
final class IntroClock {
    private var origin = Date()
    var isMuted = false

    var time: Double { Date().timeIntervalSince(origin) }

    func start(at time: Double) { origin = Date().addingTimeInterval(-time) }
    func jump(to time: Double) { origin = Date().addingTimeInterval(-time) }
}

/// The scene redrawn every frame, with two controls: the sound at the bottom left, "Skip Intro" at the
/// bottom right, both gone once the welcome page is there.
private struct IntroRoot: View {
    let clock: IntroClock
    let assets: IntroAssets
    let onboarding: IntroOnboarding?
    let skip: () -> Void
    let toggleMute: () -> Void

    var body: some View {
        TimelineView(.animation) { _ in
            let time = clock.time
            ZStack(alignment: .bottom) {
                IntroScene(time: time, assets: assets, onboarding: onboarding.map { AnyView(IntroOnboardingView(model: $0)) })
                HStack {
                    Button(action: toggleMute) {
                        Image(symbol: clock.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.ui(size: 11))
                            .frame(width: 26, height: 22)
                    }
                    Spacer()
                    Button(action: skip) {
                        HStack(spacing: 6) {
                            Text("Skip Intro")
                            Image(symbol: "return")
                        }
                        .font(.ui(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                    }
                }
                .buttonStyle(IntroChipStyle())
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .opacity(chrome(time))
                .allowsHitTesting(time < IntroScene.settled)
            }
        }
    }

    private func chrome(_ time: Double) -> Double {
        min(max((time - 0.8) / 0.8, 0), 1) * (1 - min(max((time - IntroScene.welcomeStart) / 1.0, 0), 1))
    }
}

private struct IntroChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.85))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous))
            .environment(\.colorScheme, .dark)
            .scaleEffect(configuration.isPressed ? Motion.Metrics.pressScale : 1)
    }
}

/// A borderless window that takes the keyboard, so Return and Escape reach the intro.
final class IntroWindow: NSWindow {
    /// Return or Enter, or Escape (true).
    var onKey: ((Bool) -> Void)?
    /// An arrow key: -1 or 1 across, or down (1) and up (-1).
    var onArrow: ((Int, Int) -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        // Return, Enter, Escape.
        case 36, 76, 53: onKey?(event.keyCode == 53)
        case 123: onArrow?(-1, 0)
        case 124: onArrow?(1, 0)
        case 125: onArrow?(0, 1)
        case 126: onArrow?(0, -1)
        default: super.keyDown(with: event)
        }
    }
}
