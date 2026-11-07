import AppKit
import SwiftUI

/// Craft's colours for a select's options, by position: red, yellow, green, blue, purple, pink, orange, grey, then
/// again. Values that are not options are grey.
public enum OptionPalette {
    public struct Swatch: Equatable, Sendable {
        /// Behind a pill.
        public let fill: Color
        /// The pill's text.
        public let text: Color
        /// Behind a board's column, much lighter than the pill.
        public let tint: Color
    }

    private static func swatch(_ red: Double, _ green: Double, _ blue: Double) -> Swatch {
        let color = Color(red: red, green: green, blue: blue)
        // The text is the colour darkened on a light page and lightened to a pastel on a dark one: the darkened red
        // on a dark page read at about 2:1.
        let text = adaptive(light: (red * 0.62, green * 0.55, blue * 0.55),
                            dark: (red + (1 - red) * 0.5, green + (1 - green) * 0.5, blue + (1 - blue) * 0.5))
        return Swatch(fill: adaptiveFill(color), text: text, tint: color.opacity(0.06))
    }

    /// `light` or `dark` by the appearance the colour is drawn in.
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
    }

    /// The pill's ground: a bit stronger on a dark page, where 16 % of the colour is barely there.
    private static func adaptiveFill(_ color: Color) -> Color {
        let light = NSColor(color.opacity(0.16)), dark = NSColor(color.opacity(0.22))
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    public static let swatches: [Swatch] = [
        swatch(0.93, 0.33, 0.31),  // red
        swatch(0.93, 0.74, 0.12),  // yellow
        swatch(0.30, 0.76, 0.40),  // green
        swatch(0.25, 0.55, 0.95),  // blue
        swatch(0.62, 0.40, 0.90),  // purple
        swatch(0.93, 0.36, 0.64),  // pink
        swatch(0.96, 0.55, 0.20),  // orange
    ]

    public static let grey = Swatch(fill: adaptiveFill(.gray), text: adaptive(light: (0.38, 0.38, 0.38), dark: (0.72, 0.72, 0.72)),
                                    tint: Color.gray.opacity(0.06))

    /// The swatch of `value` among `options`.
    public static func swatch(for value: String, in options: [String]) -> Swatch {
        guard let index = options.firstIndex(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            return grey
        }
        return swatches[index % swatches.count]
    }
}

/// A select value as Craft draws it: a small rounded pill in the option's colour.
public struct OptionPill: View {
    let text: String
    let swatch: OptionPalette.Swatch
    let size: CGFloat

    public init(_ text: String, options: [String], size: CGFloat = 12) {
        self.text = text
        self.swatch = OptionPalette.swatch(for: text, in: options)
        self.size = size
    }

    public var body: some View {
        Text(text)
            .font(.ui(size: size, weight: .medium))
            .foregroundStyle(swatch.text)
            .lineLimit(1)
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, size * 0.2)
            .background(RoundedRectangle(cornerRadius: Corners.r(6)).fill(swatch.fill))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(6)).strokeBorder(swatch.text.opacity(0.12)))
    }
}

/// The SF Symbol of a field's kind, for table headers and menus.
public func propertyKindSymbol(_ kind: PropertyKind, isTitle: Bool = false) -> String {
    if isTitle { return "textformat" }
    switch kind {
    case .text: return "text.alignleft"
    case .number: return "number"
    case .checkbox: return "checkmark.square"
    case .date: return "calendar"
    case .url: return "link"
    case .select: return "circle.dashed"
    case .multiselect: return "list.bullet"
    @unknown default: return "text.alignleft"
    }
}

/// A value shown read-only: text, a number, a checkmark, a date, a link or pills.
public struct PropertyValueView: View {
    let value: PropertyValue?
    let kind: PropertyKind
    let options: [String]
    @Environment(\.themeTokens) private var theme

    public init(_ value: PropertyValue?, kind: PropertyKind, options: [String] = []) {
        self.value = value
        self.kind = kind
        self.options = options
    }

    public var body: some View {
        switch (kind, value) {
        case (_, nil):
            Color.clear.frame(height: 1)
        case (.checkbox, let value?):
            Image(symbol: value == .bool(true) ? "checkmark.square.fill" : "square")
                .foregroundStyle(value == .bool(true) ? theme.accent : theme.secondaryText)
        case (.select, let value?), (.multiselect, let value?):
            // Whole pills at their own width, cut by the cell rather than squeezed to "…".
            HStack(spacing: 4) {
                ForEach(Array(Self.items(value).enumerated()), id: \.offset) { _, item in
                    OptionPill(item, options: options)
                }
            }
            .fixedSize()
        case (.url, let value?):
            Text(CollectionViewModel.text(value)).foregroundStyle(theme.link).lineLimit(1)
        case (.date, let value?) where DateValuePill.label(CollectionViewModel.text(value)) != nil:
            DateValuePill(day: CollectionViewModel.text(value))
        default:
            Text(CollectionViewModel.text(value!)).foregroundStyle(theme.text).lineLimit(1)
        }
    }

    public static func items(_ value: PropertyValue) -> [String] {
        if case .list(let items) = value { return items.map(CollectionViewModel.text).filter { !$0.isEmpty } }
        let text = CollectionViewModel.text(value)
        return text.isEmpty ? [] : [text]
    }
}

/// A value that edits in place, as Craft's table cells do: a click opens a text field, a checkbox toggles, a select
/// opens its options (with "New option…"). Changes go through `model.set`.
public struct PropertyValueEditor: View {
    let model: CollectionViewModel
    let ref: PropertyRef
    let entry: NoteRecord
    @State private var editing = false
    @State private var draft = ""
    @State private var newOption = ""
    @State private var addingOption = false
    @State private var pickingDate = false
    @FocusState private var focused: Bool
    @Environment(\.themeTokens) private var theme

    public init(model: CollectionViewModel, ref: PropertyRef, entry: NoteRecord) {
        self.model = model
        self.ref = ref
        self.entry = entry
    }

    private var kind: PropertyKind { model.kind(ref) }
    private var options: [String] { model.property(ref).options }
    private var value: PropertyValue? { model.value(ref, of: entry) }

    public var body: some View {
        Group {
            switch kind {
            case .checkbox:
                Button { model.set(ref, to: .bool(value != .bool(true)), on: entry.path) } label: {
                    PropertyValueView(value ?? .bool(false), kind: .checkbox)
                }
                .buttonStyle(.plain)
            case .select, .multiselect:
                // The menu is made when the cell is clicked: a SwiftUI menu in every cell of a table made each row
                // slow to build.
                PropertyValueView(value, kind: kind, options: options)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { choicesMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
                .alert("New option", isPresented: $addingOption) {
                    TextField("Name", text: $newOption)
                    Button("Add") { add(newOption) }
                    Button("Cancel", role: .cancel) {}
                }
            case .date:
                PropertyValueView(value, kind: kind, options: options)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { pickingDate = true }
                    .popover(isPresented: $pickingDate, arrowEdge: .bottom) { datePicker }
            default:
                if editing {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                        .onAppear { focused = true }
                } else {
                    PropertyValueView(value, kind: kind, options: options)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            draft = value.map(CollectionViewModel.text) ?? ""
                            editing = true
                        }
                }
            }
        }
    }

    private var datePicker: some View {
        PropertyDatePicker(model: model, ref: ref, path: entry.path) { pickingDate = false }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The day a value starts with (`2026-10-21`, `2026-10-21T09:00`).
    static func day(from text: String) -> Date? {
        dayFormatter.date(from: String(text.prefix(10)))
    }

    private func choicesMenu() -> NSMenu {
        PropertyEdits.choicesMenu(model: model, ref: ref, path: entry.path, value: value) {
            newOption = ""
            addingOption = true
        }
    }

    private func add(_ option: String) {
        PropertyEdits.addOption(option, model: model, ref: ref, path: entry.path, value: value)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        PropertyEdits.commitText(draft, model: model, ref: ref, path: entry.path, value: value)
    }
}

/// The edits a value's cell makes, shared by the SwiftUI editor and the table's AppKit cells.
@MainActor
public enum PropertyEdits {
    /// The options, the current ones ticked, then "New option…" and "Clear", as an AppKit menu.
    public static func choicesMenu(model: CollectionViewModel, ref: PropertyRef, path: String, value: PropertyValue?,
                                   newOption: @escaping () -> Void) -> NSMenu {
        let options = model.property(ref).options
        let current = value.map(PropertyValueView.items) ?? []
        let menu = NSMenu()
        let others = current.filter { item in !options.contains { $0.caseInsensitiveCompare(item) == .orderedSame } }
        for option in options + others {
            let isOn = current.contains { $0.caseInsensitiveCompare(option) == .orderedSame }
            let item = ActionMenuItem(option) { choose(option, isOn: isOn, current: current, model: model, ref: ref, path: path) }
            item.state = isOn ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(String(localized: "New option…"), run: newOption))
        if value != nil {
            menu.addItem(ActionMenuItem(String(localized: "Clear")) { model.set(ref, to: nil, on: path) })
        }
        return menu
    }

    static func choose(_ option: String, isOn: Bool, current: [String], model: CollectionViewModel, ref: PropertyRef, path: String) {
        if model.kind(ref) == .multiselect {
            var items = current.filter { $0.caseInsensitiveCompare(option) != .orderedSame }
            if !isOn { items.append(option) }
            model.set(ref, to: items.isEmpty ? nil : .list(items.map { .string($0) }), on: path)
        } else {
            model.set(ref, to: isOn ? nil : .string(option), on: path)
        }
    }

    /// Adds `option` to the field's options and picks it.
    public static func addOption(_ option: String, model: CollectionViewModel, ref: PropertyRef, path: String, value: PropertyValue?) {
        let option = option.trimmingCharacters(in: .whitespaces)
        guard !option.isEmpty else { return }
        model.addOption(option, to: ref)
        choose(option, isOn: false, current: value.map(PropertyValueView.items) ?? [], model: model, ref: ref, path: path)
    }

    /// Writes a text typed in a cell: nothing when unchanged, no value when empty, a number for a number field.
    public static func commitText(_ draft: String, model: CollectionViewModel, ref: PropertyRef, path: String, value: PropertyValue?) {
        let text = draft.trimmingCharacters(in: .whitespaces)
        let old = value.map(CollectionViewModel.text) ?? ""
        guard text != old else { return }
        if text.isEmpty { return model.set(ref, to: nil, on: path) }
        if model.kind(ref) == .number, let number = Double(text) { return model.set(ref, to: .number(number), on: path) }
        model.set(ref, to: .string(text), on: path)
    }
}

/// A calendar, as Craft's date field: a day picked is written as `YYYY-MM-DD`, the format agents and Obsidian read;
/// "Clear" removes the value. `close` runs once a choice is made.
public struct PropertyDatePicker: View {
    let model: CollectionViewModel
    let ref: PropertyRef
    let path: String
    let close: () -> Void

    public init(model: CollectionViewModel, ref: PropertyRef, path: String, close: @escaping () -> Void) {
        self.model = model
        self.ref = ref
        self.path = path
        self.close = close
    }

    private var value: PropertyValue? {
        model.entries.first { $0.path == path }.flatMap { model.value(ref, of: $0) }
    }

    public var body: some View {
        let current = value.map(CollectionViewModel.text).flatMap(PropertyValueEditor.day(from:))
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("", selection: Binding(
                get: { current ?? Date() },
                set: { day in set(.string(PropertyValueEditor.dayFormatter.string(from: day))) }
            ), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            HStack {
                Button("Today") { set(.string(PropertyValueEditor.dayFormatter.string(from: Date()))) }
                Spacer()
                if value != nil {
                    Button("Clear") { set(nil) }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func set(_ value: PropertyValue?) {
        model.set(ref, to: value, on: path)
        close()
    }
}

/// A date as the editor draws one in a note: a tinted pill, a calendar and "Today", "Tomorrow" or "Wed, Nov 11"
/// (the year when it is not this one). Blue, grey once past.
public struct DateValuePill: View {
    let day: String
    @Environment(\.themeTokens) private var theme

    public init(day: String) {
        self.day = day
    }

    public var body: some View {
        let past = String(day.prefix(10)) < Self.today()
        let colour = past ? theme.secondaryText : theme.link
        HStack(spacing: 4) {
            Image(symbol: "calendar").font(.ui(size: 11))
            Text(Self.label(day) ?? day).lineLimit(1)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous).fill(colour.opacity(past ? 0.1 : 0.12)))
        .help(day)
    }

    /// "Today", "Tomorrow", "Yesterday", else "Wed, Nov 11", or "Nov 11, 2027" in another year; nil for a text that
    /// is not a `YYYY-MM-DD` day.
    public static func label(_ text: String, today: String = today()) -> String? {
        let day = String(text.prefix(10))
        guard let date = formatter("yyyy-MM-dd").date(from: day),
              let base = formatter("yyyy-MM-dd").date(from: today) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        switch calendar.dateComponents([.day], from: base, to: date).day {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return formatter(day.prefix(4) == today.prefix(4) ? "EEE, MMM d" : "MMM d, yyyy").string(from: date)
        }
    }

    /// Today in the user's time zone, `YYYY-MM-DD`.
    public static func today() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One formatter per format, made once: making one took a board of 110 dated cards ~40 ms. Used on the main
    /// thread only.
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ format: String) -> DateFormatter {
        if let made = formatters[format] { return made }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        formatters[format] = formatter
        return formatter
    }
}
