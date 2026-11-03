import CryptoKit
import Foundation
import XCTest
@testable import NotebookApp

/// The app's own updates: the feed, the signature check and the archive, without a network or a restart.
@MainActor
final class AppUpdaterTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("loam-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func release(for data: Data, key: Curve25519.Signing.PrivateKey, build: Int = 10) throws -> AppRelease {
        AppRelease(
            version: "0.2.0", build: build, url: URL(string: "https://example.com/Loam-0.2.0.zip")!, size: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            signature: try key.signature(for: data).base64EncodedString(), minimumSystemVersion: "26.0",
            notes: nil, date: nil
        )
    }

    func testTheFeedReadsAsWrittenByTheReleaseScript() throws {
        let json = #"{"version": "0.2.0", "build": 480, "url": "https://github.com/x/y/releases/download/v0.2.0/Loam-0.2.0.zip", "size": 10, "sha256": "ab", "signature": "cd", "minimumSystemVersion": "26.0", "notes": "", "date": "2026-10-28"}"#
        let release = try JSONDecoder().decode(AppRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.build, 480)
        XCTAssertTrue(release.isNewer(thanBuild: 473))
        XCTAssertFalse(release.isNewer(thanBuild: 480))
        XCTAssertTrue(release.runsOnThisMac())
        var future = release
        future.minimumSystemVersion = "99.0"
        XCTAssertFalse(future.runsOnThisMac())
    }

    func testOnlyAnArchiveSignedWithTheProjectKeyPasses() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("the archive".utf8)
        let good = try release(for: data, key: key)
        XCTAssertNoThrow(try AppUpdater.verify(data, release: good, publicKey: key.publicKey))

        // Someone else's key, even with the right checksum.
        let forged = try release(for: data, key: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try AppUpdater.verify(data, release: forged, publicKey: key.publicKey)) {
            XCTAssertEqual($0 as? AppUpdateError, .badSignature)
        }
        // A changed archive.
        XCTAssertThrowsError(try AppUpdater.verify(Data("another".utf8), release: good, publicKey: key.publicKey)) {
            XCTAssertEqual($0 as? AppUpdateError, .badChecksum)
        }
    }

    func testUnpackFindsTheAppAndRefusesAnotherOne() async throws {
        func zip(bundleID: String) throws -> Data {
            let source = scratch.appendingPathComponent("src-\(UUID().uuidString)/Loam.app/Contents")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "0.2.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: source.appendingPathComponent("Info.plist"))
            let archive = scratch.appendingPathComponent("\(UUID().uuidString).zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", source.deletingLastPathComponent().path, archive.path]
            try process.run()
            process.waitUntilExit()
            return try Data(contentsOf: archive)
        }
        let folder = scratch.appendingPathComponent("updates")
        let app = try await AppUpdater.unpack(try zip(bundleID: "com.azilone.loam"), version: "0.2.0", into: folder,
                                              bundleID: "com.azilone.loam")
        XCTAssertEqual(app.lastPathComponent, "Loam.app")
        XCTAssertEqual(Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String, "0.2.0")

        do {
            _ = try await AppUpdater.unpack(try zip(bundleID: "com.someone.else"), version: "0.2.0", into: folder,
                                            bundleID: "com.azilone.loam")
            XCTFail("unpacked another app")
        } catch let error as AppUpdateError {
            guard case .badArchive = error else { return XCTFail("\(error)") }
        }
    }

    func testADevelopmentBuildDoesNotUpdateItself() {
        let updater = AppUpdater(bundle: Bundle(for: AppUpdaterTests.self), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertNotNil(updater.unavailableReason)
        XCTAssertEqual(updater.channel, .stable)
        XCTAssertTrue(updater.checksAutomatically)
    }
}
