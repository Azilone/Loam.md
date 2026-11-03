import AppKit
import PluginKitUI
import SwiftUI

/// What the board needs from the rest of the app to delete a card and take the deletion back.
struct BoardServices {
    /// Moves the note into the vault's trash; returns its path there.
    var trash: (String) throws -> String
    /// Brings a trashed note back; returns its path.
    var restore: (String) throws -> String
    /// Says why something failed.
    var report: (String) -> Void
    /// The note's checklist, done / total task lines, nil without any: shown on its card.
    var checklist: @MainActor (NoteRecord) -> BoardChecklist? = { _ in nil }
}

enum BoardError: Error, CustomStringConvertible {
    case unavailable(String)

    var description: String {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

private struct BoardColumnInfo: Identifiable {
    let index: Int
    let id: String
    let group: CollectionGroup
    let name: String
    let swatch: OptionPalette.Swatch
}

private struct BoardItem: Identifiable {
    let entry: NoteRecord
    let column: Int
    let index: Int
    var id: String { entry.path }
}

private struct BoardUndo: Equatable {
    let title: String
    let trashPath: String
    let id = UUID()
}

/// The board view of collections (`type: kanban`), as Craft draws it: one tinted column per option of the field it
/// groups by (a pill and a count on top), white cards with the shown fields, "+" under each column to add an entry
/// there, "+" on the right to add a column.
///
/// A card is taken with the pointer and follows it above the board while the others part to open a gap at the
/// insertion index; letting go drops it into the gap, and the order the cards are left in is kept in the view
/// (`CollectionViewModel.moveEntry`). Dropping on another column writes that field in the note.
struct CollectionBoardView: View {
    let model: CollectionViewModel
    let services: BoardServices
    @State private var drag = BoardDragModel()
    @State private var position = ScrollPosition(edge: .leading)
    @State private var addingColumn = false
    @State private var columnName = ""
    @State private var adding: Int?
    @State private var title = ""
    /// How long the neighbours of a removed card wait before they close the gap, so the eye follows the card out.
    @State private var closeDelay = 0.0
    @State private var undo: BoardUndo?
    @State private var undoTimer: Task<Void, Never>?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if let groupBy = model.view?.groupBy, let groups = model.groups {
            board(field: groupBy.property, groups: groups)
                .environment(\.boardChecklist, services.checklist)
        } else {
            EmptyState("Choose a field to group by", symbol: "rectangle.split.3x1",
                       message: "A board shows one column per value of a field: pick it under View settings.")
        }
    }

    // MARK: Board

    private func board(field: PropertyRef, groups: [CollectionGroup]) -> some View {
        let options = model.property(field).options
        // A column keeps its identity by its value, so it stays put while cards come and go.
        let columns = groups.enumerated().map { index, group in
            let name = group.value.map(CollectionViewModel.text) ?? "No \(model.title(of: field))"
            return BoardColumnInfo(
                index: index, id: group.value.map(CollectionViewModel.text) ?? "", group: group, name: name,
                swatch: group.value == nil ? OptionPalette.grey : OptionPalette.swatch(for: name, in: options))
        }
        let lists = arranged(groups)
        let items = lists.enumerated().flatMap { column, entries in
            entries.enumerated().map { BoardItem(entry: $1, column: column, index: $0) }
        }
        let held = items.first { $0.entry.path == drag.heldPath }?.entry
        let signature = lists.map { $0.map(\.path) }

        return ScrollView(.horizontal) {
            BoardLayout {
                ForEach(columns) { column in
                    BoardColumnBackground(swatch: column.swatch, targeted: drag.gap?.column == column.index)
                        .boardRole(.background(column: column.index))
                        .motionTransition(Self.columnEnter)
                }
                ForEach(columns) { column in
                    BoardColumnHeader(
                        name: column.name, options: column.group.value == nil ? [] : options, count: column.group.entries.count)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drag.headerHeight = $0 }
                        .boardRole(.header(column: column.index))
                        .motionTransition(Self.columnEnter)
                }
                ForEach(items) { item in
                    BoardCardView(
                        model: model, entry: item.entry, drag: drag,
                        tint: columns[min(item.column, columns.count - 1)].swatch.text,
                        moves: moves(of: item.entry, columns: columns, field: field),
                        delete: { delete(item.entry) })
                        .boardRole(.card(column: item.column, index: item.index))
                        .motionTransition(Self.cardTransition)
                }
                if let open = adding, open < columns.count {
                    BoardAddField(title: $title, commit: { commitAdd(columns[open], field: field) }, cancel: cancelAdd)
                        .boardRole(.field(column: open))
                        .transition(.opacity.animation(Motion.exit))
                }
                ForEach(columns) { column in
                    BoardPlusButton(swatch: column.swatch, help: "Add an entry in \(column.name)") {
                        title = ""
                        Motion.with(Motion.Spring.standard.animation) { adding = column.index }
                    }
                    .boardRole(.plus(column: column.index))
                    .motionTransition(Self.columnEnter)
                }
                Button {
                    columnName = ""
                    addingColumn = true
                } label: {
                    Image(symbol: "plus").font(.ui(size: 15)).foregroundStyle(theme.secondaryText)
                        .frame(width: 32, height: 32).collectionHover(cornerRadius: Corners.r(16), strength: 0.07)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a column: a new option of \(model.title(of: field))")
                .boardRole(.addColumn)
            }
            .coordinateSpace(BoardSpace.content)
            .motion(Motion.Spring.standard.animation.delay(closeDelay), value: signature)
            .overlay(alignment: .topLeading) {
                if let held {
                    HeldCardLayer(model: model, entry: held, drag: drag)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: BoardSpace.viewport)
                    .onChanged { value in
                        drag.changed(
                            start: value.startLocation, location: value.location, velocity: value.velocity,
                            columns: model.groups?.map { $0.entries.map(\.path) } ?? [])
                    }
                    .onEnded { value in drag.ended(velocity: value.velocity) })
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: BoardScroll.self) { geometry in
            BoardScroll(offset: geometry.contentOffset.x, content: geometry.contentSize.width, viewport: geometry.containerSize.width)
        } action: { _, scroll in
            drag.scroll = scroll
        }
        .coordinateSpace(BoardSpace.viewport)
        .softScrollEdges(.horizontal)
        .background { FrameDriver(isRunning: drag.needsFrames) { now, dt in drag.tick(now: now, dt: dt) } }
        .overlay(alignment: .bottom) {
            if let undo {
                BoardUndoBar(title: undo.title) { restore(undo) }
                    .transition(Motion.toast.animation(Motion.Spring.pop.animation))
            }
        }
        .onAppear {
            drag.scrollTo = { x in position.scrollTo(x: x) }
            drag.commitMove = { [model] path, column, index in
                guard let groups = model.groups, column < groups.count, let field = model.view?.groupBy?.property else { return }
                model.moveEntry(path, to: groups[column].value, in: field, at: index)
            }
        }
        .onChange(of: signature) { closeDelay = 0 }
        .onChange(of: items.map(\.id)) {
            // The card in the hand went away under it (the note was deleted or moved elsewhere).
            if let path = drag.heldPath, !items.contains(where: { $0.id == path }) { drag.cancel() }
        }
        .alert("New column", isPresented: $addingColumn) {
            TextField("Name", text: $columnName)
            Button("Add") { addColumn(columnName, field: field) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The columns' cards with the one in the hand taken out of its column and put at the gap: the board lays out
    /// this, so the ghost is where the card would land and the others have parted for it.
    private func arranged(_ groups: [CollectionGroup]) -> [[NoteRecord]] {
        var lists = groups.map(\.entries)
        guard let path = drag.heldPath, let gap = drag.gap, gap.column < lists.count else { return lists }
        var held: NoteRecord?
        for column in lists.indices {
            if let index = lists[column].firstIndex(where: { $0.path == path }) { held = lists[column].remove(at: index) }
        }
        if let held { lists[gap.column].insert(held, at: min(gap.index, lists[gap.column].count)) }
        return lists
    }

    private static var columnEnter: AnyTransition {
        .opacity.combined(with: .offset(x: 24))
    }

    private static var cardTransition: AnyTransition {
        .asymmetric(
            insertion: Motion.enter(from: .top),
            removal: .opacity.combined(with: .scale(scale: Motion.Metrics.enterScale)).animation(Motion.exit))
    }

    // MARK: Acting

    private func moves(of entry: NoteRecord, columns: [BoardColumnInfo], field: PropertyRef) -> [BoardMove] {
        columns.compactMap { column in
            guard !column.group.entries.contains(where: { $0.path == entry.path }) else { return nil }
            return BoardMove(name: column.name) {
                Motion.with(Motion.Spring.standard.animation) {
                    model.moveEntry(entry.path, to: column.group.value, in: field, at: .max)
                }
            }
        }
    }

    private func commitAdd(_ column: BoardColumnInfo, field: PropertyRef) {
        let title = title.trimmingCharacters(in: .whitespaces)
        var values: [String: PropertyValue] = [:]
        if let value = column.group.value, field.namespace == .note { values[field.name] = value }
        // The field becomes the card: it leaves, the card arrives at its frame, "+" goes down, in one move.
        Motion.with(Motion.Spring.standard.animation) {
            adding = nil
            guard !title.isEmpty, let path = model.newEntry(title: title, values: values) else { return }
            // A new card goes under the others, wherever its name would sort.
            model.moveEntry(path, to: column.group.value, in: field, at: .max)
        }
    }

    private func cancelAdd() {
        Motion.with(Motion.Spring.standard.animation) { adding = nil }
    }

    private func addColumn(_ name: String, field: PropertyRef) {
        Motion.with(Motion.Spring.standard.animation) { model.addOption(name, to: field) }
        Task { @MainActor in
            await Task.yield()
            withAnimation(Motion.resolved(Motion.Spring.smooth.animation)) { position.scrollTo(edge: .trailing) }
        }
    }

    private func delete(_ entry: NoteRecord) {
        closeDelay = 0.06
        do {
            let trashed = try Motion.with(Motion.Spring.standard.animation) { () throws -> String in
                let path = try services.trash(entry.path)
                model.reload()
                return path
            }
            show(BoardUndo(title: entry.title, trashPath: trashed))
        } catch {
            closeDelay = 0
            services.report("Could not delete “\(entry.title)”: \(error)")
        }
    }

    private func show(_ bar: BoardUndo) {
        undoTimer?.cancel()
        withAnimation(Motion.resolved(Motion.Spring.pop.animation)) { undo = bar }
        undoTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.exit) { undo = nil }
        }
    }

    private func restore(_ bar: BoardUndo) {
        undoTimer?.cancel()
        withAnimation(Motion.exit) { undo = nil }
        do {
            // The reverse of the deletion: the card comes back to the index it left, the gap reopens first.
            try Motion.with(Motion.Spring.standard.animation) {
                _ = try services.restore(bar.trashPath)
                model.reload()
            }
        } catch {
            services.report("Could not restore “\(bar.title)”: \(error)")
        }
    }
}
