import XCTest
import AttachmentsPlugin
import LoamCore
import PluginKit
import PluginKitTesting
@testable import ExcalidrawPlugin

final class ExcalidrawTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testLZStringMatchesTheJavaScriptLibrary() {
        // Produced by lz-string 1.5.0's compressToBase64.
        let vectors = [
            ("a", "IZA="),
            ("hello", "BYUwNmD2Q==="),
            ("aaaaaaaaaaaaaaaa", "IY1/EA=="),
            ("hello hello hello world", "BYUwNmD2AEoTcrQO6QE5gCZA"),
            ("Café ☕ 日本語 😀", "MIQwZglwBIqGRYp6aBpzQeVFULwbgAPaA==="),
            (#"{"type":"excalidraw","version":2,"elements":[{"id":"aB3dE5fG","type":"text","text":"Hello"}]}"#,
             "N4IgLgngDgpiBcIYA8DGBDANgSwCYCd0B3EAGhADcZ8BnbAewDsEAmcmTGAWxkbBoQBtUHgQh0AIQDMuAKIBWAGYBxMuGhxEYFGDXbkuxAAkOmeiAC+AXQtA"),
        ]
        for (text, packed) in vectors {
            XCTAssertEqual(LZString.compressToBase64(text), packed, text)
            XCTAssertEqual(LZString.decompressFromBase64(packed), text, text)
            XCTAssertEqual(LZString.decompressFromBase64(packed.prefix(5) + "\n\n" + packed.dropFirst(5)), text,
                           "line breaks are skipped")
        }
        let long = String(repeating: "Excalidraw drawings in Loam ✏️ ", count: 400)
        XCTAssertEqual(LZString.decompressFromBase64(LZString.compressToBase64(long)), long)
        XCTAssertNil(LZString.decompressFromBase64(""))
    }

    func testReadsTheObsidianPluginsFile() throws {
        let document = try ExcalidrawDocument(text: ObsidianFixture.compressed, format: .markdown)
        XCTAssertTrue(document.compressed)
        XCTAssertEqual(document.texts.map(\.text), ["Hello [[Roadmap]]"])
        XCTAssertEqual(document.links.map(\.link), ["[[Ideas]]"])
        XCTAssertEqual(document.embeddedFiles.map(\.link), ["photo.png"])
        XCTAssertEqual(document.imageFileIDs, ["f0a1b2c3d4"])
        XCTAssertEqual(document.elements.count, 3)

        let text = document.text
        XCTAssertTrue(text.hasPrefix("---\n\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n\n---\n==⚠"),
                      "the frontmatter and the text above the data stay")
        XCTAssertTrue(text.contains("Notes written above the drawing.\n\n# Excalidraw Data\n\n## Text Elements\n"
            + "Hello [[Roadmap]] ^aB3dE5fG\n\n## Element Links\nRk7mQ2pZ: [[Ideas]]\n\n## Embedded Files\n"
            + "f0a1b2c3d4: [[photo.png]]\n\n%%\n## Drawing\n```compressed-json\n"))
        XCTAssertTrue(text.hasSuffix("```\n%%\n"))
        let again = try ExcalidrawDocument(text: text, format: .markdown)
        XCTAssertEqual(again.text, text, "reading what was written changes nothing")
        XCTAssertEqual(again.texts.map(\.text), ["Hello [[Roadmap]]"])
    }

    func testWritesJSONAndTheEditedSectionsWin() throws {
        var document = try ExcalidrawDocument(text: ObsidianFixture.compressed, format: .markdown)
        document.compressed = false
        let text = document.text
        XCTAssertTrue(text.contains("```json\n{\n"))
        XCTAssertFalse(text.contains("dataURL"))

        // An agent (or a link rewrite) changes the text in its section: the element follows.
        let edited = text.replacingOccurrences(of: "Hello [[Roadmap]] ^aB3dE5fG", with: "Bye [[Plan]] ^aB3dE5fG")
            .replacingOccurrences(of: "Rk7mQ2pZ: [[Ideas]]", with: "Rk7mQ2pZ: [[Other]]")
        let read = try ExcalidrawDocument(text: edited, format: .markdown)
        let element = try XCTUnwrap(read.elements.first { $0["id"] as? String == "aB3dE5fG" })
        XCTAssertEqual(element["rawText"] as? String, "Bye [[Plan]]")
        XCTAssertEqual(element["text"] as? String, "Bye [[Plan]]")
        XCTAssertEqual(read.links.map(\.link), ["[[Other]]"])
        XCTAssertEqual(try ExcalidrawDocument(text: read.text, format: .markdown).text, read.text)
    }

    func testKeepsUnknownSectionsAndPlainFiles() throws {
        let note = """
        ---
        excalidraw-plugin: parsed
        ---

        # Excalidraw Data

        ## Text Elements
        Two
        lines ^abcdefgh

        ## Something New
        kept: yes

        ## Drawing
        ```json
        {"type":"excalidraw","version":2,"elements":[{"id":"abcdefgh","type":"text","text":"Two\\nlines","originalText":"Two\\nlines"}],"appState":{},"files":{}}
        ```
        %%
        """
        let document = try ExcalidrawDocument(text: note, format: .markdown)
        XCTAssertEqual(document.texts.map(\.text), ["Two\nlines"])
        XCTAssertTrue(document.text.contains("## Something New\nkept: yes\n\n%%\n## Drawing"))

        let plain = #"{"type":"excalidraw","version":2,"elements":[],"appState":{},"files":{"x":{"dataURL":"data:image/png;base64,AA=="}}}"#
        let file = try ExcalidrawDocument(text: plain, format: .plain)
        XCTAssertTrue(file.text.contains("data:image/png;base64,AA=="), "a plain file keeps its images inside")
        XCTAssertThrowsError(try ExcalidrawDocument(text: "{", format: .plain))
    }

    func testAnAgentCreatesAndReadsADrawing() async throws {
        let harness = try PluginTestHarness([ExcalidrawPlugin.self], files: [
            "Note.md": "# Note\n", "Fixture.excalidraw.md": ObsidianFixture.compressed, "Old.excalidraw": "{}",
        ])
        let created = try json(await harness.run("excalidraw.new", ["title": "Plan"]))
        XCTAssertEqual(created["path"] as? String, "Inbox/Plan.excalidraw.md")
        let second = try json(await harness.run("excalidraw.new", ["title": "Plan"]))
        XCTAssertEqual(second["path"] as? String, "Inbox/Plan 2.excalidraw.md")
        XCTAssertTrue(try harness.vault.read("Inbox/Plan.excalidraw.md").hasPrefix("---\nexcalidraw-plugin: parsed\n"))

        let list = try await harness.run("excalidraw.list")
        XCTAssertTrue(list.contains("Fixture.excalidraw.md") && list.contains("Old.excalidraw")
            && list.contains("Inbox/Plan.excalidraw.md"))
        XCTAssertFalse(list.contains("Note.md"))

        let read = try json(await harness.run("excalidraw.read", ["path": "Fixture.excalidraw.md"]))
        XCTAssertEqual((read["texts"] as? [[String: String]])?.first?["text"], "Hello [[Roadmap]]")
        XCTAssertEqual((read["images"] as? [[String: String]])?.first?["path"], "photo.png")
        XCTAssertEqual(read["elements"] as? Int, 3)
        await XCTAssertThrowsAsync(try await harness.run("excalidraw.read", ["path": "Note.md"]))
        await XCTAssertThrowsAsync(try await harness.run("excalidraw.new", ["title": "../escape"]))
    }

    func testAnAgentDrawsShapesJoinedByAnArrow() async throws {
        let harness = try PluginTestHarness([ExcalidrawPlugin.self])
        let path = try json(await harness.run("excalidraw.new", ["title": "Flow"]))["path"] as! String
        let client = try json(await harness.run("excalidraw.add-shape", ["path": path, "text": "Client", "color": "blue"]))["id"] as! String
        let server = try json(await harness.run("excalidraw.add-shape", ["path": path, "text": "Server", "type": "ellipse"]))["id"] as! String
        let arrow = try json(await harness.run("excalidraw.connect", ["path": path, "from": client, "to": server, "label": "HTTP"]))["id"] as! String

        let document = try XCTUnwrap(harness.kernel.services.service(.excalidraw)).read(path)
        XCTAssertEqual(document.shapes.map(\.text), ["Client", "Server"])
        XCTAssertEqual(document.shapes.map(\.type), ["rectangle", "ellipse"])
        let elements = try XCTUnwrap(document.scene["elements"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(byID[client]?["backgroundColor"] as? String, "#a5d8ff")
        XCTAssertGreaterThan(byID[server]?["x"] as! Double, byID[client]?["x"] as! Double, "the next shape goes right")
        XCTAssertEqual((byID[arrow]?["startBinding"] as? [String: Any])?["elementId"] as? String, client)
        XCTAssertEqual((byID[arrow]?["endBinding"] as? [String: Any])?["elementId"] as? String, server)
        XCTAssertTrue((byID[server]?["boundElements"] as? [[String: Any]])?.contains { $0["id"] as? String == arrow } == true)
        XCTAssertTrue(try harness.vault.read(path).contains("## Text Elements\nClient ^"), "the texts stay searchable")
        await XCTAssertThrowsAsync(try await harness.run("excalidraw.connect", ["path": path, "from": client, "to": "nope"]))
        await XCTAssertThrowsAsync(try await harness.run("excalidraw.add-shape", ["path": path, "text": "x", "type": "star"]))
    }

    func testTheEditorsImagesBecomeVaultFiles() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self, ExcalidrawPlugin.self], files: [
            "Fixture.excalidraw.md": ObsidianFixture.compressed,
        ])
        try harness.vault.writeData("Pictures/photo.png", Data([1, 2, 3]))
        let service = try XCTUnwrap(harness.kernel.services.service(.excalidraw))

        // Opening: the image linked by its bare name is found and sent with its bytes.
        var scene = try json(service.scene("Fixture.excalidraw.md"))
        let file = try XCTUnwrap((scene["files"] as? [String: Any])?["f0a1b2c3d4"] as? [String: Any])
        XCTAssertEqual(file["dataURL"] as? String, "data:image/png;base64,AQID")
        XCTAssertEqual(file["mimeType"] as? String, "image/png")

        // Saving: a pasted image goes into the attachments folder and is listed by path.
        var elements = try XCTUnwrap(scene["elements"] as? [[String: Any]])
        elements.append(["id": "Ne8wIm4g", "type": "image", "fileId": "newfile123", "isDeleted": false])
        scene["elements"] = elements
        var files = try XCTUnwrap(scene["files"] as? [String: Any])
        files["newfile123"] = ["id": "newfile123", "mimeType": "image/jpeg", "dataURL": "data:image/jpeg;base64,/9j/"]
        scene["files"] = files
        let data = try JSONSerialization.data(withJSONObject: scene)
        try await service.save("Fixture.excalidraw.md", scene: String(decoding: data, as: UTF8.self))

        let saved = try harness.vault.read("Fixture.excalidraw.md")
        XCTAssertTrue(saved.contains("f0a1b2c3d4: [[photo.png]]\nnewfile123: [[Attachments/Fixture newfile1.jpg]]\n"), saved)
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/Fixture newfile1.jpg")), Data([0xFF, 0xD8, 0xFF]))
        XCTAssertFalse(saved.contains("base64"), "images are not kept inside the note")
        XCTAssertTrue(saved.contains("```compressed-json"), "a compressed drawing stays compressed")

        // Saving the same scene again writes nothing new.
        try await service.save("Fixture.excalidraw.md", scene: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(try harness.vault.read("Fixture.excalidraw.md"), saved)

        // The image moves: the drawing follows.
        try harness.vault.move("Attachments/Fixture newfile1.jpg", to: "Pictures/new.jpg")
        harness.kernel.events.emit(NotesMoved(moves: ["Attachments/Fixture newfile1.jpg": "Pictures/new.jpg"]))
        XCTAssertTrue(try harness.vault.read("Fixture.excalidraw.md").contains("newfile123: [[Pictures/new.jpg]]"))
        XCTAssertTrue(service.isDrawing("Fixture.excalidraw.md"))
    }
}

private func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath,
                                     line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
