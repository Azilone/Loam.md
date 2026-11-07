// swift-tools-version:5.10
import PackageDescription

// The `loam` executable. It is a package of its own because an executable links the targets of its own package
// statically, while `loam` must link the runtime library dynamically: it loads third-party plugins, which share the
// runtime with it (docs/PLUGIN-LOADING.md). Its logic is `LoamCLI`, in the runtime. `make release` builds
// it with the runtime next to it.
let package = Package(
    name: "LoamCLIExecutable",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "loam", targets: ["loam"]),
    ],
    dependencies: [
        .package(name: "loam", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "loam",
            dependencies: [.product(name: "LoamRuntime", package: "loam")]
        ),
    ]
)
