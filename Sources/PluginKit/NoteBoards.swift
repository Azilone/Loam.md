import Foundation

/// Which boards show a note: the boards (JSON Canvas `.canvas` files) with a card for it. A board is not a link in
/// the note graph, so the inspector and the backlinks list ask this service, provided by the canvas plugin, to say
/// "on these boards" as Heptabase does.
public protocol NoteBoardsService: AnyObject {
    /// The vault paths of the boards with a card showing `path`, sorted.
    func boards(showing path: String) throws -> [String]
}

public extension ServiceKey where Service == NoteBoardsService {
    static var noteBoards: ServiceKey<NoteBoardsService> { ServiceKey<NoteBoardsService>("note-boards") }
}
