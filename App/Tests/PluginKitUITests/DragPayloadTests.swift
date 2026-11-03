import Foundation
import PluginKitUI
import XCTest

final class DragPayloadTests: XCTestCase {
    func testPayloadsRoundTripThroughTheirString() {
        let payloads: [DragPayload] = [
            .resource(.file("Folder/Note.md")),
            .resource(.file("A note with spaces/and:colons.md")),
            .resource(.folder("Projects/2026")),
            .resource(.virtual("calendar:2026-10")),
            .tab(UUID()),
        ]
        for payload in payloads {
            XCTAssertEqual(DragPayload(string: payload.string), payload, payload.string)
        }
    }

    func testTheStringFormIsReadable() {
        XCTAssertEqual(DragPayload.resource(.file("a/b.md")).string, "loam-resource:file/a/b.md")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(DragPayload.tab(id).string, "loam-tab:00000000-0000-0000-0000-000000000001")
    }

    func testJunkIsRejected() {
        for junk in [
            "", "hello", "loam-tab:", "loam-tab:not-a-uuid", "loam-resource:", "loam-resource:file", "loam-resource:file/",
            "loam-resource:note/a.md", "loam-resource:/a.md", "LOAM-TAB:00000000-0000-0000-0000-000000000001",
            " loam-resource:file/a.md",
        ] {
            XCTAssertNil(DragPayload(string: junk), junk)
        }
    }

    func testTheItemProviderCarriesThePayloadUnderAPrivateType() async {
        let payload = DragPayload.resource(.file("Note.md"))
        let provider = payload.itemProvider()
        XCTAssertEqual(provider.registeredTypeIdentifiers, [DragPayload.type.identifier])
        XCTAssertFalse(DragPayload.type.conforms(to: .plainText), "the editor would take a plain text drop")
        let loaded = await withCheckedContinuation { continuation in
            DragPayload.load(from: provider) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(loaded, payload)
    }

    func testAProviderWithoutThePayloadLoadsNothing() async {
        let provider = NSItemProvider(object: "loam-tab:00000000-0000-0000-0000-000000000001" as NSString)
        let loaded = await withCheckedContinuation { continuation in
            DragPayload.load(from: provider) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(loaded)
    }
}
