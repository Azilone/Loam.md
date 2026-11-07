import AppKit
import CapturePlugin
import PluginKitUI
import SwiftUI

/// The capture window: what was copied, a field for a few words, Enter. Glass like the Assistant's panel, 440 pt wide.
struct CaptureView: View {
    @Bindable var model: CaptureModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Capture").font(.ui(size: 13, weight: .semibold))
                Spacer()
                Text("esc").font(.ui(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if let existing = model.existing {
                AlreadySavedCard(title: existing.title, age: existing.age, collection: model.store.collectionName)
            } else if model.drafts.isEmpty {
                EmptyCapture(message: model.emptyMessage, shortcut: model.shortcutText())
            } else {
                VStack(spacing: 6) {
                    ForEach(model.drafts) { draft in
                        DraftRow(draft: draft, compact: model.drafts.count > 1) { model.remove(draft) }
                    }
                }
            }
            TextField(placeholder, text: $model.note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.ui(size: 14))
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .onSubmit { model.confirm() }
            HStack(spacing: 10) {
                Text(footer).font(.ui(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if model.existing != nil {
                    Button("Save as new") { model.confirm(asNew: true) }
                    .buttonStyle(.plain)
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                }
                Button(action: { model.confirm() }) {
                    HStack(spacing: 6) {
                        Text(saveTitle)
                        Text("⏎").opacity(0.7)
                    }
                    .font(.ui(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(model.canSave ? Color.accentColor : Color.primary.opacity(0.1)))
                    .foregroundStyle(model.canSave ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSave)
            }
        }
        .padding(16)
        .frame(width: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onAppear { focused = true }
        .onChange(of: model.isOpen) { _, open in if open { focused = true } }
        .onExitCommand { model.close() }
    }

    private var placeholder: String {
        model.drafts.count > 1 ? "Add a note… (added to the \(model.drafts.count) items)" : "Add a note…"
    }

    private var saveTitle: String {
        if model.existing != nil { return "Done" }
        return model.drafts.count > 1 ? "Save \(model.drafts.count) items" : "Save"
    }

    private var footer: String {
        if model.existing != nil { return model.note.isEmpty ? "Nothing new to save" : "Your note joins it" }
        if !model.canSave { return "Nothing to save yet · ⌘V to paste" }
        return "Goes into \(model.store.collectionName)"
    }
}

private struct DraftRow: View {
    let draft: CaptureDraft
    let compact: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let preview = draft.preview, !compact {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: draft.symbol)
                    .font(.ui(size: 15))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(size: 13, weight: .medium)).lineLimit(compact ? 1 : 3)
                if !compact {
                    Text(draft.detail).font(.ui(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark").font(.ui(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var title: String {
        if case .text(let text) = draft.content, !compact {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 220 ? String(trimmed.prefix(219)) + "…" : trimmed
        }
        return draft.title
    }
}

private struct EmptyCapture: View {
    let message: String?
    let shortcut: String

    var body: some View {
        VStack(spacing: 4) {
            Text(message ?? "Copy something, then press \(shortcut).")
                .font(.ui(size: 13, weight: .medium))
            Text("A link, an image, a PDF, text or a file.")
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 72)
    }
}

private struct AlreadySavedCard: View {
    let title: String
    let age: String
    let collection: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.ui(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Already in your notebook").font(.ui(size: 13, weight: .semibold))
                Text(title).font(.ui(size: 13)).lineLimit(2)
                if !age.isEmpty { Text(age).font(.ui(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// The one line after Enter: what happened, where it went, Open and Undo. Top centre of the screen, never takes
/// the keyboard.
struct CaptureLineView: View {
    @Bindable var model: CaptureModel

    var body: some View {
        Group {
            if let line = model.line {
                HStack(spacing: 10) {
                    icon(line)
                    Text(text(line)).font(.ui(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    if case .notSorted(_, _, true) = line {
                        LineButton(title: "Try again") { model.retry() }
                    }
                    if !model.outcomes.isEmpty {
                        LineButton(title: "Open") { model.openFirst() }
                    }
                    if model.canUndo, isSettled(line) {
                        LineButton(title: "Undo") { model.undo() }
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(height: 40)
                .frame(minWidth: 280, maxWidth: 520)
                .glassEffect(.regular, in: .capsule)
                .padding(6)
                .fixedSize()
                .onHover { model.isHoveringLine = $0 }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.resolved(Motion.Spring.overlay.animation), value: model.line)
    }

    private func isSettled(_ line: CaptureModel.Line) -> Bool {
        switch line {
        case .saved, .sorting, .failed, .already: false
        default: true
        }
    }

    @ViewBuilder
    private func icon(_ line: CaptureModel.Line) -> some View {
        switch line {
        case .sorting: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
        default: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func text(_ line: CaptureModel.Line) -> String {
        switch line {
        case .saved(let place): "Saved in “\(place)”"
        case .sorting(let place): "Saved in “\(place)” · sorting…"
        case let .done(title, detail): "\(title) · \(detail)"
        case .merged(let into): "Merged into “\(into)”"
        case .already(let title): "Already saved · \(title)"
        case let .notSorted(place, reason, _): "Saved in “\(place)” · \(reason)"
        case .failed(let message): message
        }
    }
}

private struct LineButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.primary.opacity(hovered ? 0.12 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
    }
}
