import Foundation
import XCTest
@testable import GitSyncPlugin

/// GitHub's API, scripted: each request is answered by the first handler whose prefix matches "METHOD path".
final class ScriptedGitHub: HTTPTransport, @unchecked Sendable {
    var routes: [(String, (URLRequest) -> (Int, Any))] = []
    private(set) var sent: [String] = []

    func on(_ prefix: String, _ answer: @escaping (URLRequest) -> (Int, Any)) { routes.append((prefix, answer)) }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let line = "\(request.httpMethod ?? "GET") \(request.url!.absoluteString)"
        sent.append(line)
        guard let route = routes.first(where: { line.contains($0.0) }) else { return (Data("{}".utf8), 404) }
        let (status, body) = route.1(request)
        return (try JSONSerialization.data(withJSONObject: body), status)
    }
}

final class ConnectTests: XCTestCase {
    func testACodeSurvivesPastingWithSpacesAndQuotes() throws {
        let code = ConnectCode(repository: "me/loam-vault", url: "git@github.com:me/loam-vault.git",
                               sshKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n",
                               vaultKey: VaultKey.generate().exported, device: "agent-research")
        let pasted = "  \"" + code.encoded + "\"\n"
        XCTAssertEqual(ConnectCode(encoded: pasted), code)
        XCTAssertFalse(code.encoded.contains("+") || code.encoded.contains("/") || code.encoded.contains("="),
                       "safe in a shell, an env file and a URL")
        XCTAssertNil(ConnectCode(encoded: "loam-key:abc"))
        XCTAssertNil(ConnectCode(encoded: ConnectCode.prefix + "%%%"))
    }

    func testRepositoryNamesFromEveryKindOfAddress() {
        for url in ["https://github.com/me/notes.git", "git@github.com:me/notes.git", "ssh://git@github.com/me/notes",
                    "https://x-access-token@github.com/me/notes/"] {
            XCTAssertEqual(ConnectCode.gitHubRepository(in: url), "me/notes", url)
        }
        XCTAssertNil(ConnectCode.gitHubRepository(in: "https://gitlab.com/me/notes.git"))
    }

    func testGitGetsTheTokenOnlyForGitHubAndNeverInItsConfig() {
        let environment = GitHub.gitEnvironment(token: "gho_secret")
        XCTAssertEqual(environment["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraheader")
        let header = try? XCTUnwrap(environment["GIT_CONFIG_VALUE_0"])
        XCTAssertEqual(header, "Authorization: Basic " + Data("x-access-token:gho_secret".utf8).base64EncodedString())
    }

    func testSignInWaitsForTheUserThenReturnsTheToken() async throws {
        let github = ScriptedGitHub()
        var polls = 0
        github.on("POST https://github.com/login/device/code") { _ in
            (200, ["device_code": "dev", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device",
                   "expires_in": 900, "interval": 5])
        }
        github.on("POST https://github.com/login/oauth/access_token") { _ in
            polls += 1
            return polls < 3 ? (200, ["error": "authorization_pending"]) : (200, ["access_token": "gho_token"])
        }
        let client = GitHub(token: nil, transport: github)
        let code = try await client.startSignIn()
        XCTAssertEqual(code.userCode, "ABCD-1234")
        let token = try await client.finishSignIn(code, sleep: { _ in })
        XCTAssertEqual(token, "gho_token")
        XCTAssertEqual(polls, 3)
    }

    func testARefusedSignInSaysSo() async throws {
        let github = ScriptedGitHub()
        github.on("access_token") { _ in (200, ["error": "access_denied"]) }
        let code = GitHubDeviceCode(deviceCode: "d", userCode: "u", verificationURL: "v", expiresIn: 60, interval: 1)
        do {
            _ = try await GitHub(token: nil, transport: github).finishSignIn(code, sleep: { _ in })
            XCTFail("signed in")
        } catch let error as GitHubError {
            XCTAssertTrue(error.message.contains("cancelled"), error.message)
        }
    }

    func testTheVaultRepositoryIsMadePrivateOrReused() async throws {
        let github = ScriptedGitHub()
        github.on("GET https://api.github.com/user") { _ in (200, ["login": "me"]) }
        github.on("GET https://api.github.com/repos/me/loam-new") { _ in (404, ["message": "Not Found"]) }
        var made: [String: Any] = [:]
        github.on("POST https://api.github.com/user/repos") { request in
            made = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            return (201, ["full_name": "me/loam-new", "clone_url": "https://github.com/me/loam-new.git",
                          "ssh_url": "git@github.com:me/loam-new.git", "private": true])
        }
        github.on("GET https://api.github.com/repos/me/loam-public") { _ in
            (200, ["full_name": "me/loam-public", "clone_url": "c", "ssh_url": "s", "private": false])
        }
        let client = GitHub(token: "t", transport: github)
        let (repository, created) = try await client.vaultRepository(named: "loam-new")
        XCTAssertTrue(created)
        XCTAssertEqual(repository.fullName, "me/loam-new")
        XCTAssertEqual(made["private"] as? Bool, true, "always private")
        do {
            _ = try await client.vaultRepository(named: "loam-public")
            XCTFail("synced with a public repository")
        } catch let error as GitHubError {
            XCTAssertTrue(error.message.contains("public"), error.message)
        }
    }

    func testAnAgentKeyIsAnEd25519KeyPair() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"))
        let (privateKey, publicKey) = try SSHKeys.generate(comment: "loam-agent-test")
        XCTAssertTrue(privateKey.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertTrue(publicKey.hasPrefix("ssh-ed25519 ") && publicKey.hasSuffix("loam-agent-test"))
    }

    func testAConnectCodeInTheEnvironmentGivesTheVaultKey() throws {
        let key = VaultKey.generate()
        let code = ConnectCode(repository: "me/v", url: "u", sshKey: nil, vaultKey: key.exported, device: "a")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
        let store = VaultKeyStores.system(environment: ["LOAM_KEY_DIR": folder.path, "LOAM_CONNECT": code.encoded])
        XCTAssertEqual(try store.load(id: key.id), key)
    }

    func testTheAgentBriefHoldsEverythingTheAgentNeeds() {
        let line = GitSyncPlugin.installLine("loam-connect:abc")
        let encrypted = AgentBrief.text(repository: "me/loam-vault", agent: "research", encrypted: true, setup: line)
        XCTAssertTrue(encrypted.contains("me/loam-vault"))
        XCTAssertTrue(encrypted.contains(line), "the command that gives access, with the keys")
        XCTAssertTrue(encrypted.contains("sync.now"))
        XCTAssertTrue(encrypted.contains("encryption key"))
        XCTAssertTrue(encrypted.contains("(conflict"), "how conflicts look")
        XCTAssertFalse(encrypted.contains("git push"), "an encrypted vault is pushed with loam")

        let setup = SyncController.gitOnlySetup(repository: "me/loam-vault", agent: "research",
                                                privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nk\n-----END OPENSSH PRIVATE KEY-----")
        let plain = AgentBrief.text(repository: "me/loam-vault", agent: "research", encrypted: false, setup: setup)
        XCTAssertTrue(plain.contains("-----END OPENSSH PRIVATE KEY-----\nKEY\n"), "the heredoc still closes on its own line")
        XCTAssertTrue(plain.contains("git pull --rebase && git push"))
        XCTAssertTrue(plain.contains("not encrypted"))
        XCTAssertFalse(plain.contains("sync.watch"))
    }

    func testAPlainVaultsAgentGetsGitCommandsOnly() {
        let setup = SyncController.gitOnlySetup(repository: "me/loam-vault", agent: "Research Bot",
                                                privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nk\n-----END OPENSSH PRIVATE KEY-----")
        XCTAssertTrue(setup.contains("git clone"))
        XCTAssertTrue(setup.contains("git@github.com:me/loam-vault.git ~/vault"))
        XCTAssertTrue(setup.contains("~/.ssh/loam-research-bot"))
        XCTAssertTrue(setup.contains("StrictHostKeyChecking=yes"), "GitHub's host keys are pinned")
        XCTAssertTrue(setup.contains("user.name=\"Research Bot\""), "the Mac shows who changed what")
        XCTAssertFalse(setup.contains("loam "), "no Loam needed")
        XCTAssertTrue(setup.contains("-----END OPENSSH PRIVATE KEY-----\nKEY"), "the heredoc closes on its own line")
    }
}
