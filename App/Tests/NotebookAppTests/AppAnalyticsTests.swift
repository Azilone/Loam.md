import Foundation
import XCTest
@testable import NotebookApp

/// The anonymous launch statistics: on by default, off when the user says so, and nothing from a development build.
@MainActor
final class AppAnalyticsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("loam-analytics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private final class Sent: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "loam-analytics-\(UUID().uuidString)"))
    }

    /// A bundle like a release build's, carrying the endpoint in its Info.plist.
    private func releaseBundle() throws -> Bundle {
        let contents = scratch.appendingPathComponent("Loam.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.loam", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45",
            "LoamAnalyticsURL": "https://stats.example.com/api/p", "LoamAnalyticsWebsiteID": "site-id",
        ]
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: scratch.appendingPathComponent("Loam.app")))
    }

    func testItIsOnByDefaultAndRemembersTheChoice() throws {
        let store = try defaults()
        let analytics = AppAnalytics(defaults: store)
        XCTAssertTrue(analytics.isEnabled)
        analytics.isEnabled = false
        XCTAssertFalse(AppAnalytics(defaults: store).isEnabled)
    }

    func testADevelopmentBuildSendsNothing() async throws {
        let sent = Sent()
        let analytics = AppAnalytics(bundle: Bundle(for: AppAnalyticsTests.self), defaults: try defaults(), delay: .zero) { sent.requests.append($0) }
        XCTAssertFalse(analytics.isAvailable)
        analytics.reportLaunch()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sent.requests.isEmpty)
    }

    func testTheLaunchEventCarriesOnlyVersionsAndLanguage() throws {
        let analytics = AppAnalytics(bundle: try releaseBundle(), defaults: try defaults())
        let request = try XCTUnwrap(analytics.launchRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://stats.example.com/api/p")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Mozilla/5.0 ") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasSuffix("Loam/1.2.3") == true)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "event")
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(payload["website"] as? String, "site-id")
        XCTAssertEqual(payload["name"] as? String, "app_launch")
        let data = try XCTUnwrap(payload["data"] as? [String: String])
        XCTAssertEqual(Set(data.keys), ["version", "build", "macos"])
        XCTAssertEqual(data["version"], "1.2.3")
        XCTAssertEqual(data["build"], "45")
        XCTAssertEqual(Set(payload.keys), ["website", "hostname", "language", "url", "title", "name", "data"])
    }

    func testAReleaseBuildReportsTheLaunchOnceUnlessTurnedOff() async throws {
        let store = try defaults()
        let sent = Sent()
        let on = AppAnalytics(bundle: try releaseBundle(), defaults: store, delay: .zero) { sent.requests.append($0) }
        XCTAssertTrue(on.isAvailable)
        on.reportLaunch()
        on.reportLaunch()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent.requests.count, 1)

        let off = AppAnalytics(bundle: try releaseBundle(), defaults: store, delay: .zero) { sent.requests.append($0) }
        off.isEnabled = false
        off.reportLaunch()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent.requests.count, 1)
    }
}
