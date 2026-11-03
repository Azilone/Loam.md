import PluginKitUI
import XCTest

final class ResourceTests: XCTestCase {
    func testNameAndExtension() {
        XCTAssertEqual(Resource.file("Projects/Plan.md").name, "Plan")
        XCTAssertEqual(Resource.file("Projects/Plan.md").pathExtension, "md")
        XCTAssertEqual(Resource.file("img/Photo.PNG").pathExtension, "png")
        XCTAssertEqual(Resource.file("img/Photo.PNG").name, "Photo", "any file's tab drops its extension")
        XCTAssertEqual(Resource.file("Boards/Road map.canvas").name, "Road map")
        XCTAssertEqual(Resource.file("Archive/v1.2.canvas").name, "v1.2", "only the last extension goes")
        XCTAssertEqual(Resource.file("README").name, "README")
        XCTAssertEqual(Resource.file(".env").name, ".env", "a leading dot is not an extension")
        XCTAssertEqual(Resource.file("README").pathExtension, "")
        XCTAssertEqual(Resource.folder("Projects/Archive").name, "Archive")
        XCTAssertEqual(Resource.folder("Projects.d").pathExtension, "")
        XCTAssertEqual(Resource.virtual("calendar:2026-10").name, "2026-10")
        XCTAssertEqual(Resource.virtual("calendar:").name, "Calendar", "no rest: named by its scheme")
        XCTAssertEqual(Resource.virtual("kanban:Boards/Projects.md").name, "Projects · Kanban")
        XCTAssertEqual(Resource.virtual("mindmap:Welcome.md").name, "Welcome · Mindmap")
        XCTAssertEqual(Resource.virtual("board:Boards/Plan.canvas").name, "Plan · Board")
        XCTAssertEqual(Resource.virtual("calendar:2026-10").pathExtension, "")
        XCTAssertEqual(Resource.virtual("calendar:2026-10").kind, .virtual)
    }
}
