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
        return Swatch(fill: color.opacity(0.16), text: Color(red: red * 0.62, green: green * 0.55, blue: blue * 0.55),
                      tint: color.opacity(0.06))
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

    public static let grey = Swatch(fill: Color.gray.opacity(0.16), text: Color(white: 0.38), tint: Color.gray.opacity(0.06))

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
            HStack(spacing: 4) {
                ForEach(Array(Self.items(value).enumerated()), id: \.offset) { _, item in
                    OptionPill(item, options: options)
                }
            }
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
                Menu {
                    choices
                } label: {
                    PropertyValueView(value, kind: kind, options: options)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
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

    /// A calendar, as Craft's date field: a day picked is written as `YYYY-MM-DD`, the format agents and Obsidian
    /// read; "Clear" removes the value.
    private var datePicker: some View {
        let current = value.map(CollectionViewModel.text).flatMap(Self.day(from:))
        return VStack(alignment: .leading, spacing: 8) {
            DatePicker("", selection: Binding(
                get: { current ?? Date() },
                set: { day in
                    model.set(ref, to: .string(Self.dayFormatter.string(from: day)), on: entry.path)
                    pickingDate = false
                }
            ), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            HStack {
                Button("Today") {
                    model.set(ref, to: .string(Self.dayFormatter.string(from: Date())), on: entry.path)
                    pickingDate = false
                }
                Spacer()
                if value != nil {
                    Button("Clear") {
                        model.set(ref, to: nil, on: entry.path)
                        pickingDate = false
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private static let dayFormatter: DateFormatter = {
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

    @ViewBuilder private var choices: some View {
        let current = value.map(PropertyValueView.items) ?? []
        ForEach(options, id: \.self) { option in
            let isOn = current.contains { $0.caseInsensitiveCompare(option) == .orderedSame }
            Button {
                choose(option, isOn: isOn, current: current)
            } label: {
                if isOn { Label(option, symbol: "checkmark") } else { Text(option) }
            }
        }
        ForEach(current.filter { item in !options.contains { $0.caseInsensitiveCompare(item) == .orderedSame } }, id: \.self) { other in
            Button { choose(other, isOn: true, current: current) } label: { Label(other, symbol: "checkmark") }
        }
        Divider()
        Button("New option…") {
            newOption = ""
            addingOption = true
        }
        if value != nil {
            Button("Clear") { model.set(ref, to: nil, on: entry.path) }
        }
    }

    private func choose(_ option: String, isOn: Bool, current: [String]) {
        if kind == .multiselect {
            var items = current.filter { $0.caseInsensitiveCompare(option) != .orderedSame }
            if !isOn { items.append(option) }
            model.set(ref, to: items.isEmpty ? nil : .list(items.map { .string($0) }), on: entry.path)
        } else {
            model.set(ref, to: isOn ? nil : .string(option), on: entry.path)
        }
    }

    private func add(_ option: String) {
        let option = option.trimmingCharacters(in: .whitespaces)
        guard !option.isEmpty else { return }
        model.addOption(option, to: ref)
        choose(option, isOn: false, current: value.map(PropertyValueView.items) ?? [])
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let text = draft.trimmingCharacters(in: .whitespaces)
        let old = value.map(CollectionViewModel.text) ?? ""
        guard text != old else { return }
        if text.isEmpty { return model.set(ref, to: nil, on: entry.path) }
        if kind == .number, let number = Double(text) { return model.set(ref, to: .number(number), on: entry.path) }
        model.set(ref, to: .string(text), on: entry.path)
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

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
