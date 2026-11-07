import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// Sends one HTTP request. The sync only reaches GitHub's API through this, so tests can script it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Why a GitHub call failed, in one sentence for the user.
public struct GitHubError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What GitHub shows the user to sign in on another screen: open `verificationURL`, type `userCode`.
public struct GitHubDeviceCode: Codable, Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: String
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

/// A repository the vault syncs with.
public struct GitHubRepository: Codable, Sendable, Equatable {
    public let fullName: String
    public let cloneURL: String
    public let sshURL: String
    public let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case cloneURL = "clone_url"
        case sshURL = "ssh_url"
        case isPrivate = "private"
    }
}

/// A repository's deploy key: how one agent reaches that repository, and only it.
public struct GitHubDeployKey: Codable, Sendable, Equatable {
    public let id: Int
    public let title: String
}

/// Loam's GitHub OAuth app, signed in to with the device flow (no secret in the app): the token reaches only what
/// the user allows, and the sync uses it to create the vault's private repository, push over HTTPS and give each
/// agent a deploy key.
public struct GitHub: Sendable {
    /// Loam's OAuth app. `LOAM_GITHUB_CLIENT_ID` overrides it (tests, a fork).
    public static var clientID: String {
        let override = ProcessInfo.processInfo.environment["LOAM_GITHUB_CLIENT_ID"] ?? ""
        return override.isEmpty ? builtInClientID : override
    }
    static let builtInClientID = "Ov23lisqXb80IqyhNkQT"
    /// Private repositories and their deploy keys; `workflow` to push the encrypted vault's GitHub check
    /// (`.github/workflows/loam-encrypted.yml`), which GitHub refuses from an OAuth app without it.
    static let scope = "repo workflow"
    /// The prefix of the deploy keys Loam makes: the agents listed are the keys with it.
    static let agentKeyPrefix = "Loam agent: "

    let transport: HTTPTransport
    let token: String?

    public init(token: String?, transport: HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    // MARK: - Sign in

    public func startSignIn() async throws -> GitHubDeviceCode {
        let data = try await form("https://github.com/login/device/code",
                                  ["client_id": Self.clientID, "scope": Self.scope])
        guard let code = try? JSONDecoder().decode(GitHubDeviceCode.self, from: data) else {
            throw GitHubError("GitHub did not start the sign-in: \(Self.reason(data))")
        }
        return code
    }

    /// Waits until the user approved `code` on GitHub, then returns the token. Stops when they refused or it expired.
    public func finishSignIn(_ code: GitHubDeviceCode, sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }) async throws -> String {
        var interval = TimeInterval(max(code.interval, 1))
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try Task.checkCancellation()
            await sleep(interval)
            let data = try await form("https://github.com/login/oauth/access_token", [
                "client_id": Self.clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let token = object["access_token"] as? String, !token.isEmpty { return token }
            switch object["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw GitHubError("The sign-in was cancelled on GitHub.")
            case "expired_token": throw GitHubError("The sign-in code expired: try again.")
            default: throw GitHubError("GitHub refused the sign-in: \(Self.reason(data))")
            }
        }
        throw GitHubError("The sign-in code expired: try again.")
    }

    // MARK: - API

    public func login() async throws -> String {
        let object = try await api("GET", "/user")
        guard let login = object["login"] as? String else { throw GitHubError("GitHub did not say who you are.") }
        return login
    }

    /// The user's private repository `name`, made if it does not exist yet. A public one with that name is refused.
    public func vaultRepository(named name: String) async throws -> (GitHubRepository, created: Bool) {
        let owner = try await login()
        if let existing = try? await repository("\(owner)/\(name)") {
            guard existing.isPrivate else {
                throw GitHubError("Your repository \(existing.fullName) is public: Loam only syncs with a private one.")
            }
            return (existing, false)
        }
        let object = try await api("POST", "/user/repos", [
            "name": name, "private": true, "auto_init": false,
            "description": "Loam vault (synced by Loam; encrypted notes)",
        ])
        return (try Self.decode(GitHubRepository.self, object), true)
    }

    /// The repository has no commit yet (GitHub answers 409 for its commits): made, but nothing pushed.
    public func isEmpty(_ fullName: String) async -> Bool {
        do {
            _ = try await request("GET", "/repos/\(fullName)/commits?per_page=1")
            return false
        } catch {
            return (error as? GitHubError)?.message.contains("answered 409") == true
        }
    }

    public func repository(_ fullName: String) async throws -> GitHubRepository {
        try Self.decode(GitHubRepository.self, try await api("GET", "/repos/\(fullName)"))
    }

    /// A file's text on the default branch; nil when the repository is empty or has no such file.
    public func fileContent(_ fullName: String, path: String) async throws -> String? {
        guard let data = try? await request("GET", "/repos/\(fullName)/contents/\(path)"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = object["content"] as? String,
              let decoded = Data(base64Encoded: content.filter { !$0.isWhitespace }) else { return nil }
        return String(decoding: decoded, as: UTF8.self)
    }

    public func addDeployKey(_ fullName: String, title: String, publicKey: String) async throws -> GitHubDeployKey {
        let object = try await api("POST", "/repos/\(fullName)/keys",
                                   ["title": title, "key": publicKey, "read_only": false])
        return try Self.decode(GitHubDeployKey.self, object)
    }

    public func deployKeys(_ fullName: String) async throws -> [GitHubDeployKey] {
        let data = try await request("GET", "/repos/\(fullName)/keys?per_page=100")
        return (try? JSONDecoder().decode([GitHubDeployKey].self, from: data)) ?? []
    }

    public func deleteDeployKey(_ fullName: String, id: Int) async throws {
        _ = try await request("DELETE", "/repos/\(fullName)/keys/\(id)")
    }

    // MARK: - HTTP

    private func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(method, path, body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        guard let token else { throw GitHubError("Not signed in to GitHub.") }
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Loam", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, status) = try await send(request)
        switch status {
        case 200..<300: return data
        case 401: throw GitHubError("GitHub no longer accepts Loam's sign-in: sign in again.")
        case 403, 404:
            throw GitHubError("GitHub refused \(method) \(path) (\(status)): \(Self.reason(data)). Sign in again to give "
                              + "Loam access to private repositories.")
        default: throw GitHubError("GitHub answered \(status) to \(method) \(path): \(Self.reason(data))")
        }
    }

    private func form(_ url: String, _ fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Loam", forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        return try await send(request).0
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            return try await transport.send(request)
        } catch {
            throw GitHubError("GitHub cannot be reached: \(error.localizedDescription)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(type, from: data) else {
            throw GitHubError("GitHub's answer was not what Loam expected.")
        }
        return value
    }

    static func reason(_ data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["message"] as? String) ?? (object?["error_description"] as? String)
            ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    /// The `Authorization` header git sends to github.com over HTTPS with this token, given through the environment
    /// (`GIT_CONFIG_*`), never written to the repository's config or shown in a process list.
    static func gitEnvironment(token: String) -> [String: String] {
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
            "GIT_CONFIG_VALUE_0": "Authorization: Basic \(basic)",
        ]
    }
}

/// Where this device keeps its GitHub token: the login Keychain on a Mac ("Loam GitHub"), else
/// `~/.config/loam/github-token` (only the user can read it). `LOAM_GITHUB_TOKEN` comes first when set.
public struct GitHubTokenStore: Sendable {
    static let service = "Loam GitHub"
    let file: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let directory = environment["LOAM_KEY_DIR"], !directory.isEmpty {
            file = URL(fileURLWithPath: directory).appendingPathComponent("github-token")
        } else {
            #if canImport(Security)
            file = nil
            #else
            let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
            file = config.appendingPathComponent("loam/github-token")
            #endif
        }
        self.environment = environment["LOAM_GITHUB_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private let environment: String?

    public func load() -> String? {
        if let environment { return environment }
        if let file { return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "default", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
        #else
        return nil
        #endif
    }

    /// Keeps `token`, or forgets it when nil (sign out).
    public func save(_ token: String?) throws {
        if let file {
            guard let token else { try? FileManager.default.removeItem(at: file); return }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw GitHubError("Could not keep the GitHub sign-in in \(file.path).")
            }
            return
        }
        #if canImport(Security)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "default",
        ]
        SecItemDelete(identity as CFDictionary)
        guard let token else { return }
        var item = identity
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = Self.service
        item[kSecAttrDescription as String] = "Loam's sign-in to GitHub, for the vault's sync"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitHubError("Could not keep the GitHub sign-in (error \(status)).") }
        #endif
    }
}
