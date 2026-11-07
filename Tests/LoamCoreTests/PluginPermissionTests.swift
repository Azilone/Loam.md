import Foundation
import PluginKit
import LoamCore
import XCTest

final class PluginPermissionTests: XCTestCase {
    func testEveryKnownPermissionHasASummaryAndRoundTrips() throws {
        for permission in PluginPermission.allCases {
            XCTAssertFalse(permission.summary.isEmpty, permission.rawValue)
            XCTAssertEqual(DeclaredPermission(permission.rawValue), .known(permission))
            let data = try JSONEncoder().encode(DeclaredPermission.known(permission))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(permission.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(DeclaredPermission.self, from: data), .known(permission))
        }
        XCTAssertEqual(PluginPermission.vaultWrite.summary, "Change your notes")
        XCTAssertEqual(PluginPermission.network.risk, .high)
        XCTAssertEqual(PluginPermission.shell.risk, .high)
        XCTAssertEqual(PluginPermission.vaultRead.risk, .low)
    }

    func testAnUnknownPermissionIsKeptAndTreatedAsHighRisk() throws {
        let decoded = try JSONDecoder().decode([DeclaredPermission].self, from: Data(#"["vault.read", "camera"]"#.utf8))
        XCTAssertEqual(decoded, [.known(.vaultRead), .unknown("camera")])
        XCTAssertEqual(decoded[1].summary, "Unknown permission: camera")
        XCTAssertEqual(decoded[1].risk, .high)
        XCTAssertEqual(decoded[1].rawValue, "camera")
    }

    func testTheListPutsTheRiskiestFirstAndDropsDuplicates() {
        let list = DeclaredPermission.list(["vault.read", "network", "vault.write", "vault.read", "zzz"])
        XCTAssertEqual(list, [.known(.network), .unknown("zzz"), .known(.vaultWrite), .known(.vaultRead)])
    }

    func testThirdPartyManifestReadsItsPermissions() throws {
        let json = #"{"id": "hello", "name": "Hello", "version": "0.1.0", "library": "HelloPlugin", "permissions": ["vault.read", "shell", "telepathy"]}"#
        let manifest = try JSONDecoder().decode(ThirdPartyPluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.permissions, ["vault.read", "shell", "telepathy"], "stored as written")
        XCTAssertEqual(manifest.declaredPermissions, [.known(.shell), .unknown("telepathy"), .known(.vaultRead)])

        let none = #"{"id": "hello", "name": "Hello", "version": "0.1.0", "library": "HelloPlugin"}"#
        XCTAssertEqual(try JSONDecoder().decode(ThirdPartyPluginManifest.self, from: Data(none.utf8)).declaredPermissions, [])
    }

    func testPluginManifestPermissionsAreOptionalAndRoundTrip() throws {
        let json = #"{"id": "p", "name": "P", "version": "1.0.0"}"#
        XCTAssertEqual(try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8)).permissions, [])
        let full = PluginManifest(id: "p", name: "P", version: "1.0.0", permissions: ["vault.write", "network"])
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(decoded, full)
        XCTAssertEqual(decoded.declaredPermissions, [.known(.network), .known(.vaultWrite)])
    }

    func testPluginManifestDescriptionIconAndSettingsAreOptionalAndRoundTrip() throws {
        let bare = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id": "p", "name": "P", "version": "1"}"#.utf8))
        XCTAssertEqual(bare.description, "")
        XCTAssertNil(bare.icon)
        XCTAssertEqual(bare.settings, [])

        let full = PluginManifest(
            id: "p", name: "P", version: "1", description: "Does p.", icon: "star",
            settings: [
                SettingDescription("folder", title: "Folder", help: "Where it goes."),
                SettingDescription("week", title: "Week starts on", choices: [
                    SettingChoice(.string("monday"), title: "Monday"), SettingChoice(.number(0), title: "Sunday"),
                ]),
            ]
        )
        XCTAssertEqual(try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(full)), full)

        let written = #"{"id": "p", "name": "P", "version": "1", "settings": [{"key": "on", "title": "On"}]}"#
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(written.utf8))
        XCTAssertEqual(decoded.settings, [SettingDescription("on", title: "On")])
    }
}
