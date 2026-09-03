// swift-tools-version: 6.0
// omgui-mac -- native Apple Silicon port of Axivity's OMGUI.
// Phase 0/1: vendored libomapi, the Swift OmApi layer, and a CLI.
// Phase 2: the OmGui macOS app shell (SwiftUI + AppKit).

import PackageDescription

let package = Package(
    name: "omgui-mac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OmApi", targets: ["OmApi"]),
        .executable(name: "omgui-cli", targets: ["omgui-cli"]),
        .executable(name: "OmGui", targets: ["OmGui"]),
    ],
    targets: [
        // Vendored libomapi (BSD-2, Newcastle University). See Vendor/libomapi/UPSTREAM.md
        // and Vendor/PATCHES.md. Only the macOS device finder is vendored.
        .target(
            name: "COmApi",
            path: "Vendor/libomapi",
            exclude: [
                "LICENSE.TXT",
                "UPSTREAM.md",
            ],
            sources: ["src"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),

        // Swift API mirroring upstream omapinet (OmApi.cs / OmDevice.cs / OmSource.cs / OmReader.cs).
        .target(
            name: "OmApi",
            dependencies: ["COmApi"]
        ),

        // The CLI shares the GUI's flows (`DownloadFlow.resolve`, `checkFirmware`,
        // `DeviceFlowPreflight`) rather than re-implementing them: a guard fixed in one has to be
        // fixed in both, and the re-implementations drifted.
        .executableTarget(
            name: "omgui-cli",
            dependencies: ["OmApi", "OmGuiCore"]
        ),

        // The macOS app. `OmGuiCore` holds every headless view model so the flows can be tested
        // without a window; `OmGui` is the SwiftUI/AppKit shell on top of it.
        .target(
            name: "OmGuiCore",
            dependencies: ["OmApi"]
        ),

        .executableTarget(
            name: "OmGui",
            dependencies: ["OmApi", "OmGuiCore"]
        ),

        .testTarget(
            name: "OmApiTests",
            dependencies: ["OmApi"]
        ),

        .testTarget(
            name: "OmGuiTests",
            dependencies: ["OmGuiCore", "OmApi"]
        ),
    ]
)
