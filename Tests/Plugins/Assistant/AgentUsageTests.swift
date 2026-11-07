import XCTest
@testable import AssistantPlugin

/// The default agent (`auto`) and Codex's plan and usage, read from its app server's answers.
final class AgentUsageTests: XCTestCase {
    func testThePaidAgentIsTheDefault() {
        let statuses = [
            AgentStatus(kind: .claude, state: .signedOut, path: "/c"),
            AgentStatus(kind: .codex, state: .ready, path: "/x", account: "ChatGPT Free"),
            AgentStatus(kind: .opencode, state: .ready, path: "/o"),
            AgentStatus(kind: .pi, state: .ready, path: "/p", account: "Claude Max"),
        ]
        XCTAssertEqual(AgentCatalog.preferred(statuses), .pi)
        XCTAssertEqual(AgentCatalog.preferred(Array(statuses.prefix(3))), .codex, "a free account beats nothing said")
        XCTAssertEqual(AgentCatalog.preferred([
            AgentStatus(kind: .codex, state: .ready, path: "/x", account: "ChatGPT Plus"),
            AgentStatus(kind: .claude, state: .ready, path: "/c", account: "Claude Pro"),
        ]), .claude, "two subscriptions: Claude Code first")
        XCTAssertEqual(AgentCatalog.preferred([
            AgentStatus(kind: .claude, state: .ready, path: "/c", account: "API key"),
            AgentStatus(kind: .codex, state: .ready, path: "/x", account: "ChatGPT"),
        ]), .codex)
        XCTAssertNil(AgentCatalog.preferred([AgentStatus(kind: .claude, state: .missing, path: nil)]))
    }

    func testTheSettingWinsOverAuto() {
        let catalog = AgentCatalog()
        XCTAssertEqual(catalog.defaultAgent(setting: "codex"), .codex)
        XCTAssertEqual(catalog.defaultAgent(setting: "auto"), .claude, "before the first check")
    }

    func testCodexPlanAndWindowsAreRead() throws {
        let lines = [
            #"{"id":1,"result":{"userAgent":"loam"}}"#,
            #"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}"#,
            #"{"id":2,"result":{"account":{"type":"chatgpt","email":"a@b.c","planType":"plus"},"requiresOpenaiAuth":true}}"#,
            #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1794896288},"secondary":{"usedPercent":40.5,"windowDurationMins":10080,"resetsAt":null},"planType":"plus"}}}"#,
        ]
        let reading = try XCTUnwrap(CodexAccount.parse(lines))
        XCTAssertEqual(reading.plan, "ChatGPT Plus")
        XCTAssertEqual(reading.usage, [
            UsageWindow(name: "5 hours", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_794_896_288)),
            UsageWindow(name: "Week", usedPercent: 40.5, resetsAt: nil),
        ])
        XCTAssertNil(CodexAccount.parse(["not json"]))
        XCTAssertEqual(UsageWindow.name(minutes: 43200), "Month")
        XCTAssertEqual(CodexAccount.planName("free_workspace"), "ChatGPT Free Workspace")
    }
}
