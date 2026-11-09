// swift-tools-version:6.2
import PackageDescription

// The native macOS installer wizard. It is a package of its own, like the app's executable (App/Executable), because it
// links nothing but the system frameworks: it copies a Loam.app, links the `loam` command line and opens the app.
// `scripts/build-installer.sh` builds it and puts Loam.app in its bundle as the payload it installs.
let package = Package(
    name: "LoamInstaller",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LoamInstaller", targets: ["LoamInstaller"]),
    ],
    targets: [
        .executableTarget(name: "LoamInstaller"),
    ]
)
