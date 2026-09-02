// swift-tools-version: 6.0
// omgui-mac -- native Apple Silicon port of Axivity's OMGUI.
// Phase 0/1: vendored libomapi, the Swift OmApi layer, and a CLI. No UI target yet.

import PackageDescription

let package = Package(
    name: "omgui-mac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OmApi", targets: ["OmApi"]),
        .executable(name: "omgui-cli", targets: ["omgui-cli"]),
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

        .executableTarget(
            name: "omgui-cli",
            dependencies: ["OmApi"]
        ),

        .testTarget(
            name: "OmApiTests",
            dependencies: ["OmApi"]
        ),
    ]
)
