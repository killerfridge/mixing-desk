// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MixingDesk",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "MixingDesk", targets: ["MixingDesk"]), .executable(name: "DeskModelChecks", targets: ["DeskModelChecks"])],
    targets: [
        .target(name: "DeskAudio", path: "Sources/DeskAudio", exclude: ["VST3SDK/README.md", "VST3SDK/pluginterfaces/LICENSE.txt"], publicHeadersPath: "include",
                cxxSettings: [.headerSearchPath("."), .headerSearchPath("VST3SDK")],
                linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("AudioUnit"), .linkedFramework("CoreAudioKit"),
                    .linkedFramework("Foundation"), .linkedFramework("AppKit")]),
        .target(name: "DeskModels", path: "Sources/DeskModels"),
        .executableTarget(name: "MixingDesk", dependencies: ["DeskAudio", "DeskModels"], path: "Sources/MixingDesk"),
        .executableTarget(name: "DeskModelChecks", dependencies: ["DeskModels"], path: "Tests/ModelChecks"),
        .testTarget(name: "DeskModelsTests", dependencies: ["DeskModels"], path: "Tests/DeskModelsTests")
    ], cxxLanguageStandard: .cxx20
)
