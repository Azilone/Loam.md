import Foundation
import PluginKit

/// Builds a third-party plugin's package, `.loam/plugins/<id>/`, against the SDK (`PluginSDK`) into
/// `.loam/cache/plugins/<id>/lib<library>.dylib` (`.so` on Linux), where `PluginLoader` finds it.
///
///     swift build -c release --product <library> --scratch-path .loam/cache/build/<id>     (LOAM_SDK=<sdk> in the env)
///
/// - The `swift` on the PATH compiles it. On Linux it must be the toolchain the app was built with: the build id covers
///   `swift --version`, so a plugin built by another compiler is refused at load time ("rebuild it"). On macOS the ABI
///   is stable and the plugin SDK is built with library evolution, so any compiler will do.
/// - On macOS a library that uses the runtime libraries outside the plugin SDK (PluginKit, PluginKitUI) is refused:
///   those parts change with every release.
/// - The SDK's `Package.resolved` pins are copied into the plugin's, so swift-markdown and Yams resolve to the
///   versions the runtime was built with.
/// - From a source checkout (not the app's stamped snapshot), the checkout is stamped with its build id for the build
///   and put back afterwards, as `make app` does, unless the running runtime is an unstamped `dev` build.
/// - On macOS the copied library loses the build folder's absolute rpaths (which hold another copy of the runtime)
///   and is signed ad hoc, so it only links the runtime the app or `loam` already loaded.
public struct PluginBuilder {
    public struct Result: Encodable, Equatable, Sendable {
        public let id: String
        public let ok: Bool
        /// The installed library, when the build succeeded.
        public let library: String?
        /// The last 40 lines of the build log.
        public let log: String
    }

    public static let buildFolder = ".loam/cache/build"
    static let logLines = 40

    public let rootURL: URL
    public let sdk: Swift.Result<PluginSDK, PluginSDKError>
    /// The runtime build id of the process; decides whether a checkout is stamped.
    public let runtimeBuildID: String
    /// Finds `swift`, which builds the plugin.
    let tools: ToolLocating

    public init(
        rootURL: URL,
        sdk: Swift.Result<PluginSDK, PluginSDKError> = PluginSDK.locate(),
        runtimeBuildID: String = PluginRuntime.buildID,
        tools: ToolLocating = ToolLocator()
    ) {
        self.rootURL = rootURL
        self.sdk = sdk
        self.runtimeBuildID = runtimeBuildID
        self.tools = tools
    }

    func packageURL(_ id: String) -> URL {
        rootURL.appendingPathComponent(PluginLoader.pluginsFolder, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    func scratchURL(_ id: String) -> URL {
        rootURL.appendingPathComponent(Self.buildFolder, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    func logURL(_ id: String) -> URL {
        rootURL.appendingPathComponent(Self.buildFolder, isDirectory: true).appendingPathComponent("\(id).log")
    }

    /// Builds one plugin. Never throws: every problem is a result with `ok: false` and the reason in its log.
    public func build(_ id: String) async -> Result {
        let log = logURL(id)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: log)
        do {
            let library = try await runBuild(id, log: log)
            return Result(id: id, ok: true, library: library.path, log: tail(log))
        } catch {
            append("error: \(error.localizedDescription)", to: log)
            return Result(id: id, ok: false, library: nil, log: tail(log))
        }
    }

    /// Runs the plugin's tests (`swift test` against the SDK, in a scratch folder of its own). Never throws: the
    /// result's `ok` says whether they passed, its log ends with their summary.
    public func test(_ id: String) async -> Result {
        let log = rootURL.appendingPathComponent(Self.buildFolder, isDirectory: true).appendingPathComponent("\(id)-test.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: log)
        do {
            _ = try readManifest(id)
            let sdk = try self.sdk.get()
            append("Testing plugin \(id) against the SDK at \(sdk.url.path)", to: log)
            let package = packageURL(id)
            try pinDependencies(package: package, sdk: sdk.url)
            let scratch = rootURL.appendingPathComponent(Self.buildFolder, isDirectory: true)
                .appendingPathComponent("\(id)-test", isDirectory: true)
            let status = try await Subprocess.run(
                "swift", ["test", "--scratch-path", scratch.path], in: package,
                environment: [PluginSDK.environmentKey: sdk.url.path], log: log
            )
            guard status == 0 else { throw Subprocess.Failure(message: "swift test failed (exit \(status))") }
            return Result(id: id, ok: true, library: nil, log: tail(log))
        } catch {
            append("error: \(error.localizedDescription)", to: log)
            return Result(id: id, ok: false, library: nil, log: tail(log))
        }
    }

    private func runBuild(_ id: String, log: URL) async throws -> URL {
        let manifest = try readManifest(id)
        let sdk = try self.sdk.get()
        append("Building plugin \(id) (\(manifest.library)) against the SDK at \(sdk.url.path) (\(sdk.origin.rawValue))", to: log)
        let package = packageURL(id)
        try pinDependencies(package: package, sdk: sdk.url)
        // The developer tools' stub would open an installer and fail: say what to do instead.
        guard let swift = tools.locate("swift") else {
            throw Subprocess.Failure(message: "swift is not installed: run xcode-select --install, then build again")
        }

        let stamp = sdk.isCheckout && runtimeBuildID != "dev"
        let script = sdk.url.appendingPathComponent("scripts/stamp-build-id.sh").path
        if stamp {
            guard try await Subprocess.run("bash", [script], log: log) == 0 else {
                throw Subprocess.Failure(message: "cannot stamp the build id of \(sdk.url.path)")
            }
        }
        let arguments = ["-c", "release", "--product", manifest.library, "--scratch-path", scratchURL(id).path]
        let environment = [PluginSDK.environmentKey: sdk.url.path]
        let status: Int32
        do {
            status = try await Subprocess.run(swift.path, ["build"] + arguments, in: package, environment: environment, log: log)
        } catch {
            if stamp { _ = try? await Subprocess.run("bash", [script, "--restore"], log: log) }
            throw error
        }
        if stamp { _ = try? await Subprocess.run("bash", [script, "--restore"], log: log) }
        guard status == 0 else { throw Subprocess.Failure(message: "swift build failed (exit \(status))") }

        let bin = try await Subprocess.output(
            swift.path, ["build", "--show-bin-path"] + arguments, in: package, environment: environment
        )
        let fileName = PluginLoader.libraryFileName(manifest.library)
        let built = URL(fileURLWithPath: bin.split(separator: "\n").last.map(String.init) ?? bin)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: built.path) else {
            throw Subprocess.Failure(message: "the build did not produce \(built.path); is \"library\" in plugin.json the "
                + "name of a dynamic library product of Package.swift?")
        }
        #if os(macOS)
        let unstable = Self.unstableModules(inUndefinedSymbols: try await Subprocess.output("nm", ["-m", "-u", built.path]))
        guard unstable.isEmpty else {
            throw Subprocess.Failure(message: "the plugin uses \(unstable.joined(separator: ", ")), which "
                + (unstable.count == 1 ? "is" : "are") + " not part of the plugin SDK and change"
                + (unstable.count == 1 ? "s" : "") + " with every release of the app: import only PluginKit and PluginKitUI")
        }
        #endif
        return try await install(built, id: id, fileName: fileName, log: log)
    }

    /// The modules a plugin may use from the runtime libraries: the SDK, built with library evolution so a plugin
    /// survives releases that only add API. Everything else in them (the kernel, the shell, the editor, first-party
    /// plugins, swift-markdown) changes with every release.
    static let sdkModules: Set<String> = ["PluginKit", "PluginKitUI"]
    static let runtimeLibraries = ["libLoamRuntime", "libLoamUIRuntime"]

    /// The modules outside the SDK whose symbols a plugin library takes from the runtime libraries, sorted, from
    /// `nm -m -u` output (`(undefined) external _$s8LoamCore6KernelC… (from libLoamRuntime)`). A symbol whose module
    /// cannot be read is not counted.
    static func unstableModules(inUndefinedSymbols output: String) -> [String] {
        var modules: Set<String> = []
        for line in output.split(separator: "\n") {
            guard runtimeLibraries.contains(where: { line.contains("(from \($0))") }),
                  let symbol = line.split(separator: " ").first(where: { $0.hasPrefix("_") }),
                  let module = mangledModule(String(symbol)),
                  !sdkModules.contains(module),
                  !extendsInTheSDK(String(symbol)) else { continue }
            modules.insert(module)
        }
        return modules.sorted()
    }

    /// Whether a symbol is a member the SDK adds to another module's type (`Font.ui` in PluginKitUI is mangled
    /// `$s7SwiftUI4FontV11PluginKitUIE2ui…`): it lives in the SDK, though its name starts with SwiftUI.
    /// The mangled name abbreviates repeated words (`PluginKitUI` after `SwiftUI` is `PluginKitB0`), so it is read
    /// demangled, by the Swift runtime.
    static func extendsInTheSDK(_ symbol: String) -> Bool {
        let name = symbol.hasPrefix("_$s") ? String(symbol.dropFirst()) : symbol
        guard let demangled = demangle(name) else { return false }
        return sdkModules.contains { demangled.contains("(extension in \($0)):") }
    }

    private static func demangle(_ name: String) -> String? {
        name.withCString { pointer in
            guard let result = swiftDemangle(pointer, UInt(strlen(pointer)), nil, nil, 0) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
    }

    /// The module a mangled Swift symbol starts with: `$s9PluginKit…` is PluginKit, an Objective-C class
    /// `_OBJC_CLASS_$__TtC11PluginKitUI…` is PluginKitUI.
    static func mangledModule(_ symbol: String) -> String? {
        let rest: Substring
        if let range = symbol.range(of: "$s") {
            rest = symbol[range.upperBound...]
        } else if let range = symbol.range(of: "_Tt") {
            rest = symbol[range.upperBound...].dropFirst()
        } else {
            return nil
        }
        let digits = rest.prefix(while: \.isNumber)
        guard let length = Int(digits), length > 0 else { return nil }
        let name = rest.dropFirst(digits.count).prefix(length)
        return name.count == length ? String(name) : nil
    }

    /// Copies the built library into `.loam/cache/plugins/<id>/`, replacing the old file by a rename so a process that
    /// mapped it keeps a valid file.
    private func install(_ built: URL, id: String, fileName: String, log: URL) async throws -> URL {
        let files = FileManager.default
        let folder = rootURL.appendingPathComponent(PluginLoader.cacheFolder, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(".\(fileName).new")
        try? files.removeItem(at: staged)
        try files.copyItem(at: built, to: staged)
        #if os(macOS)
        let rpaths = try await Subprocess.output("otool", ["-l", staged.path])
        let lines = rpaths.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line == "cmd LC_RPATH" && index + 2 < lines.count {
            let parts = lines[index + 2].split(separator: " ")
            guard parts.first == "path", parts.count > 1, parts[1].hasPrefix("/") else { continue }
            try await Subprocess.run("install_name_tool", ["-delete_rpath", String(parts[1]), staged.path], log: log)
        }
        guard try await Subprocess.run("codesign", ["--force", "--sign", "-", staged.path], log: log) == 0 else {
            throw Subprocess.Failure(message: "cannot sign \(staged.path)")
        }
        #endif
        let target = folder.appendingPathComponent(fileName)
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: staged)
        } else {
            try files.moveItem(at: staged, to: target)
        }
        append("Installed \(target.path)", to: log)
        return target
    }

    func readManifest(_ id: String) throws -> ThirdPartyPluginManifest {
        let url = packageURL(id).appendingPathComponent(PluginLoader.manifestFile)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Subprocess.Failure(message: "no plugin \"\(id)\": \(PluginLoader.pluginsFolder)/\(id)/plugin.json is missing")
        }
        let manifest: ThirdPartyPluginManifest
        do {
            manifest = try JSONDecoder().decode(ThirdPartyPluginManifest.self, from: data)
        } catch {
            throw Subprocess.Failure(message: "\(PluginLoader.pluginsFolder)/\(id)/plugin.json cannot be read: \(error)")
        }
        if let problem = manifest.problem(folderName: id) { throw Subprocess.Failure(message: problem) }
        return manifest
    }

    /// Writes the SDK's pins (root and App packages) into the plugin's `Package.resolved`, keeping the plugin's own
    /// other pins. SwiftPM ignores a path dependency's `Package.resolved`, so without this a plugin could resolve
    /// a newer swift-markdown than the runtime it links.
    func pinDependencies(package: URL, sdk: URL) throws {
        func pins(_ url: URL) -> [[String: Any]] {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return object["pins"] as? [[String: Any]] ?? []
        }
        func byIdentity(_ list: [[String: Any]]) -> [String: [String: Any]] {
            var result: [String: [String: Any]] = [:]
            for pin in list { if let identity = pin["identity"] as? String { result[identity] = pin } }
            return result
        }
        func encode(_ pins: [String: [String: Any]]) throws -> Data {
            let list: [Any] = pins.keys.sorted().map { pins[$0]! }
            return try JSONSerialization.data(withJSONObject: ["pins": list, "version": 3] as [String: Any],
                                              options: [.prettyPrinted, .sortedKeys])
        }
        let resolved = package.appendingPathComponent("Package.resolved")
        let current = byIdentity(pins(resolved))
        var merged = current
        for url in [sdk.appendingPathComponent("Package.resolved"), sdk.appendingPathComponent("App/Package.resolved")] {
            merged.merge(byIdentity(pins(url))) { _, sdk in sdk }
        }
        guard !merged.isEmpty, try encode(merged) != encode(current) else { return }
        try encode(merged).write(to: resolved, options: .atomic)
    }

    private func append(_ line: String, to log: URL) {
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// The last lines of the log, without the build's progress lines (`[12 / 480] Yams`).
    private func tail(_ log: URL) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !Self.isProgress($0) }
        return Subprocess.lastLines(lines.joined(separator: "\n"), Self.logLines)
    }

    static func isProgress(_ line: Substring) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        let counter = line[line.index(after: line.startIndex)..<close]
        // Swift Build separates the numbers with thin spaces (U+2009).
        return counter.contains("/") && counter.contains(where: \.isNumber)
            && counter.allSatisfy { $0.isNumber || $0.isWhitespace || $0 == "/" }
    }
}

@_silgen_name("swift_demangle")
private func swiftDemangle(
    _ mangledName: UnsafePointer<CChar>?, _ mangledNameLength: UInt, _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?, _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
