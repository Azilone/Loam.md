// swift-tools-version:5.10
import Foundation
import PackageDescription

// A third-party plugin, built outside the app and loaded at run time. Install it into a test vault with
// `loam plugin install Examples/HelloPlugin` (which builds it), then `loam plugin enable hello`.
//
// A plugin links the app's runtime library dynamically (`LoamRuntime`; a UI plugin adds
// `LoamUIRuntime` from App/) and is itself a dynamic library, built against the app's SDK sources: `loam plugin build`
// sets LOAM_SDK to them. Without it, this checkout is the SDK. On macOS it keeps running on later releases while the
// plugin SDK keeps its major version (docs/PLUGIN-LOADING.md, "Plugin SDK version").
let sdk = ProcessInfo.processInfo.environment["LOAM_SDK"] ?? "../.."

let package = Package(
    name: "HelloPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HelloPlugin", type: .dynamic, targets: ["HelloPlugin"]),
    ],
    dependencies: [
        .package(name: "loam", path: sdk),
    ],
    targets: [
        .target(
            name: "HelloPlugin",
            dependencies: [.product(name: "LoamRuntime", package: "loam")]
        ),
    ]
)
