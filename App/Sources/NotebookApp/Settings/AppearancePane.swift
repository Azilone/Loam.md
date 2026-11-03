import AppKit
import LoamCore
import PluginKitUI
import SwiftUI

/// The look of the vault: light or dark, the accent colour, and the theme, picked from one gallery (the system look,
/// the files of `.loam/themes/`, the built-in themes and the community's). Every choice is written to `.loam/config.json` and the window
/// follows at once. The language of the interface is kept with the app's preferences and applies on the next launch.
struct AppearancePane: View {
    let themes: ThemeStore
    @State private var notice: String?
    @State private var language = AppLanguage.chosen()
    /// The community catalog's themes, loaded when the pane opens; empty offline.
    @State private var community: [CommunityTheme] = []
    @AppStorage(WindowCanvas.transparencyKey) private var transparency = WindowCanvas.defaultTransparency

    /// The accent the window draws with when none is chosen: the theme's, else the design's blue.
    private var themeAccent: ThemeColor { themes.current?.colors.accent ?? Glass.defaultAccentColor }

    var body: some View {
        SettingsPage(title: String(localized: "Appearance")) {
            if let message = themes.error ?? notice {
                SettingsNotice(text: message, symbol: "exclamationmark.triangle")
            }
            AppearanceModes(
                selected: fixedAppearance ?? themes.appearance ?? .light,
                fixed: fixedAppearance
            ) { mode in
                save { try themes.setAppearance(mode) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .settingsGroup()
            SettingsSection(title: String(localized: "Accent Colour")) {
                AccentPicker(selected: themes.accent ?? themeAccent, defaultColor: themeAccent) { color in
                    save { try themes.setAccent(color == themeAccent ? nil : color) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            SettingsSection {
                SettingsRow(
                    title: String(localized: "Window Transparency"),
                    detail: String(localized: "The desktop shows through the sidebars, blurred.")
                ) {
                    Slider(value: $transparency, in: 0...WindowCanvas.maxTransparency)
                        .labelsHidden()
                        .frame(width: 160)
                }
            }
            SettingsSection {
                SettingsRow(
                    title: String(localized: "Language"),
                    detail: String(localized: "Loam restarts to use it.")
                ) {
                    Picker(String(localized: "Language"), selection: Binding(
                        get: { language ?? "" },
                        set: { chooseLanguage($0.isEmpty ? nil : $0) }
                    )) {
                        Text("System").tag("")
                        Divider()
                        ForEach(AppLanguage.codes.sorted { AppLanguage.name(of: $0) < AppLanguage.name(of: $1) }, id: \.self) { code in
                            Text(AppLanguage.name(of: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            SettingsSection(title: String(localized: "Theme")) {
                ThemeGallery(tiles: tiles, isDark: prefersDark)
                    .padding(12)
            }
            SettingsAction(title: String(localized: "Reveal Themes Folder"), symbol: "folder") { revealFolder() }
                .padding(.horizontal, 8)
                .padding(.top, -12)
        }
        .onAppear { themes.reload() }
        .task { community = await CommunityThemes.load() }
    }

    /// The appearance of a theme made for only light or only dark: the modes cannot change it.
    private var fixedAppearance: ThemeAppearance? {
        guard let appearance = themes.current?.appearance, themes.selectedName != nil, appearance != .auto else { return nil }
        return appearance
    }

    /// Whether a theme made for light and dark is drawn dark: the mode chosen here, the system's for System.
    private var prefersDark: Bool {
        switch themes.appearance {
        case .dark?: true
        case .auto?: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        case .light?, nil: false
        }
    }

    private func save(_ change: () throws -> Void) {
        do {
            notice = nil
            try change()
        } catch {
            notice = String(localized: "Could not save the appearance: \(String(describing: error))")
        }
    }

    /// Whether `entry` is in use: chosen, and no file of `.loam/themes/` has its name.
    private func isBuiltInSelected(_ entry: ThemeStore.Entry) -> Bool {
        guard let name = themes.selectedName, ThemeStore.entry(named: name, in: themes.entries) == nil else { return false }
        return ThemeStore.entry(named: name, in: BuiltInThemes.all)?.id == entry.id
    }

    private func chooseLanguage(_ code: String?) {
        guard code != language else { return }
        language = code
        AppLanguage.choose(code)
        AppLanguage.relaunch()
    }

    private func choose(_ name: String?) {
        do {
            notice = nil
            try themes.select(name)
        } catch {
            notice = String(localized: "Could not save the theme: \(String(describing: error))")
        }
    }

    /// Every theme in one list: the vault's files, the built-in ones, then the community's. A
    /// community theme stays where it is once installed; one not installed yet is downloaded and used in one click.
    private var tiles: [ThemeTile] {
        let selectedFile = themes.selectedName.flatMap { ThemeStore.entry(named: $0, in: themes.entries)?.id }
        func installed(_ id: String) -> ThemeStore.Entry? {
            themes.entries.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        }
        func file(_ entry: ThemeStore.Entry, name: String? = nil, id: String? = nil) -> ThemeTile {
            ThemeTile(id: id ?? "file:\(entry.id)", name: name ?? entry.displayName, theme: entry.theme,
                      isSelected: selectedFile == entry.id,
                      problem: entry.error.map { String(localized: "Cannot be used: \($0)") }) { choose(entry.id) }
        }
        let fromCommunity = Set(community.compactMap { installed($0.id)?.id })
        var tiles: [ThemeTile] = []
        tiles += themes.entries.filter { !fromCommunity.contains($0.id) }.map { file($0) }
        tiles += BuiltInThemes.all.map { entry in
            ThemeTile(id: "builtin:\(entry.id)", name: entry.displayName, theme: entry.theme,
                      isSelected: isBuiltInSelected(entry)) { choose(entry.id) }
        }
        tiles += community.map { item in
            if let entry = installed(item.id) { return file(entry, name: item.entry.name, id: "community:\(item.id)") }
            return ThemeTile(id: "community:\(item.id)", name: item.entry.name, theme: item.theme, isSelected: false,
                             isRemote: true) { installAndUse(item) }
        }
        return tiles
    }

    private func installAndUse(_ item: CommunityTheme) {
        do {
            notice = nil
            try themes.install(id: item.id, json: item.json)
            try themes.select(item.id)
        } catch {
            notice = String(localized: "Could not install the theme: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
    }

    private func revealFolder() {
        try? FileManager.default.createDirectory(at: themes.folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([themes.folderURL])
    }
}

/// System, Light or Dark, each drawn as a small window. With a theme made for one appearance the other two are dimmed.
private struct AppearanceModes: View {
    let selected: ThemeAppearance
    let fixed: ThemeAppearance?
    let choose: (ThemeAppearance) -> Void

    var body: some View {
        HStack(spacing: 18) {
            mode(.auto, "System")
            mode(.light, "Light")
            mode(.dark, "Dark")
        }
    }

    private func mode(_ appearance: ThemeAppearance, _ title: LocalizedStringKey) -> some View {
        let isSelected = appearance == selected
        return Button { choose(appearance) } label: {
            VStack(spacing: 8) {
                ModeThumbnail(appearance: appearance)
                    .frame(height: 96)
                    .overlay {
                        RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: isSelected ? 2 : 1)
                    }
                Text(title)
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(fixed.map { $0 != appearance } ?? false)
        .opacity(fixed.map { $0 != appearance } ?? false ? 0.35 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tiny window on a wallpaper: light, dark, or half of each for System.
private struct ModeThumbnail: View {
    let appearance: ThemeAppearance

    var body: some View {
        switch appearance {
        case .light: window(dark: false)
        case .dark: window(dark: true)
        case .auto:
            HStack(spacing: 0) {
                window(dark: false).frame(maxWidth: .infinity, alignment: .leading).clipped()
                window(dark: true).frame(maxWidth: .infinity, alignment: .trailing).clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
        }
    }

    private func window(dark: Bool) -> some View {
        let wallpaper = dark
            ? LinearGradient(colors: [Color(hex: 0x5A6582), Color(hex: 0x2B2F3E)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(hex: 0xC9D4FF), Color(hex: 0xFFD9EA)], startPoint: .topLeading, endPoint: .bottomTrailing)
        return RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
            .fill(wallpaper)
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: Corners.r(4)).fill(dark ? Color(hex: 0x2A2A30) : Color(hex: 0xF2F2F4)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        ThemeCapsule().fill(dark ? Color(hex: 0xF2F2F7) : Color(hex: 0x1C1C1E)).frame(width: 30, height: 4)
                        ThemeCapsule().fill(dark ? Color(hex: 0x48484A) : Color(hex: 0xD1D1D6)).frame(width: 52, height: 3)
                        ThemeCapsule().fill(dark ? Color(hex: 0x48484A) : Color(hex: 0xD1D1D6)).frame(width: 40, height: 3)
                        ThemeCapsule().fill(Color.accentColor).frame(width: 20, height: 3)
                    }
                    .padding(6)
                    Spacer(minLength: 0)
                }
                .padding(5)
                .frame(height: 66)
                .background(dark ? Color(hex: 0x1E1E22) : .white, in: UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7))
                .padding(.horizontal, 22)
            }
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
    }
}

/// The accent swatches: links, the selection, checked tasks. The first one is the accent the window uses when none is
/// chosen: the theme's, or the design's blue.
private struct AccentPicker: View {
    let selected: ThemeColor
    let defaultColor: ThemeColor
    let choose: (ThemeColor) -> Void

    private var swatches: [(name: String, color: ThemeColor)] {
        [(name: String(localized: "Default"), color: defaultColor)] + ThemeStore.accents.dropFirst()
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(swatches, id: \.name) { accent in
                let isSelected = accent.color == selected
                Button { choose(accent.color) } label: {
                    Circle()
                        .fill(Color(accent.color))
                        .frame(width: 28, height: 28)
                        .padding(3)
                        .overlay { if isSelected { Circle().strokeBorder(Color(accent.color), lineWidth: 2) } }
                }
                .buttonStyle(.plain)
                .help(accent.name)
                .accessibilityLabel(accent.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A theme of the community catalog, with its file already downloaded.
private struct CommunityTheme: Identifiable {
    let entry: ThemeCatalog.Entry
    let json: Data
    let theme: Theme

    var id: String { entry.id }
}

/// Reads the community catalog (docs/THEMES.md) and every theme's file, in the catalog's order; a theme whose file
/// cannot be read is left out, and nothing is returned offline.
private enum CommunityThemes {
    static func load() async -> [CommunityTheme] {
        guard let catalog = try? await ThemeCatalog.fetch() else { return [] }
        let found = await withTaskGroup(of: CommunityTheme?.self) { group in
            for entry in catalog.themes where ThemeCatalog.isValidID(entry.id) {
                group.addTask {
                    guard let json = try? await ThemeCatalog.fetchTheme(id: entry.id),
                          let theme = try? Theme.parse(json, fallbackName: entry.name) else { return nil }
                    return CommunityTheme(entry: entry, json: json, theme: theme)
                }
            }
            var found: [String: CommunityTheme] = [:]
            for await item in group { if let item { found[item.id] = item } }
            return found
        }
        return catalog.themes.compactMap { found[$0.id] }
    }
}

/// One theme of the gallery: what it looks like, its name, and what a click does.
private struct ThemeTile: Identifiable {
    let id: String
    let name: String
    /// nil is the system look.
    let theme: Theme?
    let isSelected: Bool
    var problem: String?
    /// From the community catalog, not installed yet.
    var isRemote = false
    let choose: () -> Void
}

/// The themes as a grid of small windows drawn in their own colours, the one in use ringed with the accent.
private struct ThemeGallery: View {
    let tiles: [ThemeTile]
    /// Whether the window is dark: a theme for light and dark is drawn as the window is.
    let isDark: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)], spacing: 14) {
            ForEach(tiles) { tile in ThemeTileView(tile: tile, isDark: isDark) }
        }
    }
}

private struct ThemeTileView: View {
    let tile: ThemeTile
    let isDark: Bool
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: tile.choose) {
            VStack(spacing: 6) {
                ThemePreview(theme: tile.theme, windowIsDark: isDark)
                    .aspectRatio(1.5, contentMode: .fit)
                    .opacity(tile.problem == nil ? 1 : 0.4)
                    .overlay {
                        RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                            .strokeBorder(tile.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
                            .padding(-4)
                    }
                    .overlay(alignment: .topTrailing) { badge.padding(5) }
                    .scaleEffect(isHovered && !tile.isSelected ? 1.03 : 1)
                Text(tile.name.uiLocalized)
                    .font(.ui(size: SettingsStyle.detailSize, weight: tile.isSelected ? .medium : .regular))
                    .foregroundStyle(tile.isSelected ? theme.accent : theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help(tile.problem ?? (tile.isRemote ? String(localized: "Install") : ""))
        .accessibilityLabel(tile.name)
        .accessibilityAddTraits(tile.isSelected ? .isSelected : [])
    }

    @ViewBuilder private var badge: some View {
        if tile.problem != nil {
            Image(symbol: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if tile.isRemote {
            Image(symbol: "arrow.down.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .tint)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
        }
    }
}

/// A tiny window drawn with a theme's own tokens: its sidebar, background, heading, text and accent. A theme for
/// light and dark is drawn as the window is; nil is the system look.
private struct ThemePreview: View {
    let theme: Theme?
    let windowIsDark: Bool

    var body: some View {
        let dark = switch theme?.appearance {
        case .dark?: true
        case .light?: false
        default: windowIsDark
        }
        let palette = theme?.palette(dark: dark) ?? ThemePalette()
        let background = palette.background.map(Color.init) ?? Color(nsColor: .textBackgroundColor)
        let sidebar = palette.sidebar.map(Color.init) ?? Color(nsColor: .windowBackgroundColor)
        let text = palette.text.map(Color.init) ?? Color(nsColor: .labelColor)
        let heading = palette.heading.map(Color.init) ?? text
        let secondary = palette.secondaryText.map(Color.init) ?? Color(nsColor: .secondaryLabelColor)
        let accent = palette.accent.map(Color.init) ?? ThemeTokens.standard.accent
        GeometryReader { size in
            let unit = size.size.width / 100
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4 * unit) {
                    ThemeCapsule().fill(accent).frame(width: 12 * unit, height: 2.5 * unit)
                    ThemeCapsule().fill(secondary.opacity(0.5)).frame(width: 10 * unit, height: 2.5 * unit)
                    ThemeCapsule().fill(secondary.opacity(0.5)).frame(width: 13 * unit, height: 2.5 * unit)
                }
                .padding(5 * unit)
                .frame(width: 24 * unit, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(sidebar)
                VStack(alignment: .leading, spacing: 4 * unit) {
                    ThemeCapsule().fill(heading).frame(width: 34 * unit, height: 5 * unit)
                    ThemeCapsule().fill(text.opacity(0.7)).frame(width: 52 * unit, height: 2.5 * unit)
                    ThemeCapsule().fill(text.opacity(0.7)).frame(width: 44 * unit, height: 2.5 * unit)
                    HStack(spacing: 3 * unit) {
                        Circle().fill(accent).frame(width: 5 * unit, height: 5 * unit)
                        ThemeCapsule().fill(secondary.opacity(0.6)).frame(width: 30 * unit, height: 2.5 * unit)
                    }
                }
                .padding(7 * unit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(background)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityHidden(true)
    }
}
