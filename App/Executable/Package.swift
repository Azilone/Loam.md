// swift-tools-version:6.2
import PackageDescription

// The app executable. It is a package of its own because an executable links the targets of its own package
// statically, while the app must link the two runtime libraries dynamically: third-party plugins link them too, and
// a process must hold one copy of each PluginKit and PluginKitUI type (docs/PLUGIN-LOADING.md).
// `scripts/build-app.sh` builds it and puts the libraries in the bundle's `Contents/Frameworks`.
let package = Package(
    name: "LoamAppExecutable",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Loam", targets: ["Loam"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(name: "loam", path: "../.."),
    ],
    targets: [
        // Decides which plugins the shell hosts.
        .executableTarget(
            name: "Loam",
            dependencies: [
                .product(name: "LoamUIRuntime", package: "App"),
                .product(name: "LoamRuntime", package: "loam"),
            ]
        ),
    ]
)
