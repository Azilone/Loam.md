import XCTest
import PluginKit
@testable import LoamCore

protocol Greeter {
    func greet() -> String
}

struct English: Greeter {
    func greet() -> String { "hello" }
}

extension ServiceKey where Service == Greeter {
    static var greeter: ServiceKey<Greeter> { ServiceKey<Greeter>("greeter") }
}

struct Renamed: PluginEvent {
    var name: String
}

private final class GreeterPlugin: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "greeter-plugin", name: "Greeter", version: "1.0.0", provides: ["greeter"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.provide(.greeter, English())
    }
}

private final class OtherGreeterPlugin: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "other-greeter", name: "Other", version: "1.0.0", provides: ["greeter"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.provide(.greeter, English())
    }
}

private final class ForgetfulPlugin: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "forgetful", name: "Forgetful", version: "1.0.0", provides: ["greeter"])
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}

private final class Consumer: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "consumer", name: "Consumer", version: "1.0.0", requires: ["greeter"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        guard let greeter = context.service(.greeter) else { return }
        try context.registerCommand(
            Command(id: "consumer.hello", title: "Hello", summary: "Greets") { _ in greeter.greet() }
        )
    }
}

private struct Boom: Error {}

private final class Failing: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "failing", name: "Failing", version: "1.0.0", requires: ["greeter"])
    }
    required init() {}
    func activate(context: PluginContext) throws { throw Boom() }
}

private final class CycleA: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "a", name: "A", version: "1.0.0", provides: ["a"], requires: ["b"])
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}

private final class CycleB: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "b", name: "B", version: "1.0.0", provides: ["b"], requires: ["a"])
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}

final class PluginHostTests: XCTestCase {
    private func makeKernel() -> Kernel {
        Kernel(vault: Vault(rootURL: FileManager.default.temporaryDirectory))
    }

    func testProvidersActivateBeforeConsumers() throws {
        let host = PluginHost(kernel: makeKernel())
        try host.register(Consumer.self)
        try host.register(GreeterPlugin.self)
        XCTAssertEqual(try host.resolveOrder().map(\.id), ["greeter-plugin", "consumer"])
    }

    func testMissingServiceIsReported() throws {
        let host = PluginHost(kernel: makeKernel())
        try host.register(GreeterPlugin.self)
        try host.register(Consumer.self)
        XCTAssertThrowsError(try host.resolveOrder(enabled: ["consumer"])) { error in
            XCTAssertEqual(error as? PluginError, .missingService(plugin: "consumer", service: "greeter"))
        }
    }

    func testReplacingAProviderKeepsConsumersWorking() throws {
        let host = PluginHost(kernel: makeKernel())
        try host.register(OtherGreeterPlugin.self)
        try host.register(Consumer.self)
        XCTAssertEqual(try host.resolveOrder().map(\.id), ["other-greeter", "consumer"])
    }

    func testTwoProvidersOfOneServiceConflict() throws {
        let host = PluginHost(kernel: makeKernel())
        try host.register(GreeterPlugin.self)
        try host.register(OtherGreeterPlugin.self)
        XCTAssertThrowsError(try host.resolveOrder()) { error in
            XCTAssertEqual(
                error as? PluginError,
                .duplicateProvider(service: "greeter", plugins: ["greeter-plugin", "other-greeter"])
            )
        }
    }

    func testCycleIsDetected() throws {
        let host = PluginHost(kernel: makeKernel())
        try host.register(CycleA.self)
        try host.register(CycleB.self)
        XCTAssertThrowsError(try host.resolveOrder()) { error in
            XCTAssertEqual(error as? PluginError, .cycle(ids: ["a", "b", "a"]))
        }
    }

    func testDuplicateRegistrationFails() throws {
        let host = PluginHost(kernel: makeKernel())
        try host.register(GreeterPlugin.self)
        XCTAssertThrowsError(try host.register(GreeterPlugin.self))
    }

    func testPromisedServiceMustBeProvided() throws {
        let host = PluginHost(kernel: makeKernel())
        try host.register(ForgetfulPlugin.self)
        XCTAssertThrowsError(try host.activateAll()) { error in
            XCTAssertEqual(error as? PluginError, .providedServiceMissing(plugin: "forgetful", service: "greeter"))
        }
        XCTAssertEqual(host.activeIDs, [])
    }

    func testConsumerUsesServiceAndDeactivationUndoesEverything() async throws {
        let kernel = makeKernel()
        let host = PluginHost(kernel: kernel)
        try host.register(GreeterPlugin.self)
        try host.register(Consumer.self)
        try host.activateAll()
        XCTAssertEqual(host.activeIDs, ["greeter-plugin", "consumer"])
        let result = try await kernel.commands.command(id: "consumer.hello")?.handler([:])
        XCTAssertEqual(result, "hello")
        host.deactivateAll()
        XCTAssertNil(kernel.commands.command(id: "consumer.hello"))
        XCTAssertNil(kernel.services.service(.greeter))
    }

    func testFailedActivationRollsBackEarlierPlugins() throws {
        let kernel = makeKernel()
        let host = PluginHost(kernel: kernel)
        try host.register(GreeterPlugin.self)
        try host.register(Failing.self)
        XCTAssertThrowsError(try host.activateAll())
        XCTAssertEqual(host.activeIDs, [])
        XCTAssertNil(kernel.services.service(.greeter))
    }

    func testEmitReachesObserversUntilRemoved() {
        let bus = EventBus()
        var seen: [String] = []
        let remove = bus.on(Renamed.self) { seen.append($0.name) }
        bus.emit(Renamed(name: "a"))
        remove()
        bus.emit(Renamed(name: "b"))
        XCTAssertEqual(seen, ["a"])
    }

    func testWaterfallWrapsInOrderAndCanShortCircuit() {
        let bus = EventBus()
        _ = bus.intercept(Renamed.self) { event, next in
            var copy = event
            copy.name += "1"
            return next(copy)
        }
        _ = bus.intercept(Renamed.self) { event, next in
            var copy = event
            copy.name += "2"
            return next(copy)
        }
        XCTAssertEqual(bus.waterfall(Renamed(name: "x")).name, "x12")

        _ = bus.intercept(Renamed.self) { _, _ in Renamed(name: "stop") }
        _ = bus.intercept(Renamed.self) { event, next in next(Renamed(name: event.name + "never")) }
        XCTAssertEqual(bus.waterfall(Renamed(name: "x")).name, "stop")
    }
}
