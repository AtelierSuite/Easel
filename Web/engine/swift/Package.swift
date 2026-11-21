// swift-tools-version:6.0
//
// The Easel engine for the web: Paintbrush (../../../Paintbrush, linked as
// Sources/Paintbrush) built for WebAssembly behind a small C interface, plus
// the tool that turns string catalogues into the JSON the web app loads.
// Built by Web/build.sh.
//
// Paintbrush is compiled exactly as the Apple apps compile it. What it imports
// from Apple's SDK is provided here by portable stand-ins of the same names
// (Sources/Portable/*), which implement only what Paintbrush uses: Core
// Graphics drawing in software, Core Image filters, ImageIO's PNG and JPEG,
// and so on. zlib and SQLite are the real libraries (fetched by vendor.sh).
//
// Requires the swift.org toolchain and its matching Swift SDK for WebAssembly
// (see Web/README.md).

import PackageDescription

let standIns: [Target] = [
    .target(name: "CoreGraphics", dependencies: ["zlib"], path: "Sources/Portable/CoreGraphics"),
    .target(name: "CoreImage", dependencies: ["CoreGraphics"], path: "Sources/Portable/CoreImage"),
    .target(name: "ImageIO", dependencies: ["CoreGraphics", "UniformTypeIdentifiers", "zlib"], path: "Sources/Portable/ImageIO"),
    .target(name: "UniformTypeIdentifiers", path: "Sources/Portable/UniformTypeIdentifiers"),
    .target(name: "Compression", dependencies: ["zlib"], path: "Sources/Portable/Compression"),
    .target(name: "AppKit", dependencies: ["CoreGraphics", "EaselHost"], path: "Sources/Portable/AppKit"),
    .target(name: "CoreText", dependencies: ["AppKit"], path: "Sources/Portable/CoreText"),
    .target(name: "CoreVideo", dependencies: ["CoreGraphics"], path: "Sources/Portable/CoreVideo"),
    .target(name: "Vision", dependencies: ["CoreGraphics", "CoreVideo"], path: "Sources/Portable/Vision"),
    .target(name: "SwiftUI", dependencies: ["CoreGraphics"], path: "Sources/Portable/SwiftUI"),
    .target(name: "simd", path: "Sources/Portable/simd"),
]

let package = Package(
    name: "EaselWeb",
    // The strings tool runs on the Mac doing the build.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EaselWasm", targets: ["EaselWasm"]),
        .executable(name: "strings-tool", targets: ["StringsTool"]),
    ],
    targets: standIns + [
        .target(name: "zlib", path: "Sources/zlib", cSettings: [.define("Z_HAVE_UNISTD_H")]),
        .target(name: "EaselHost", path: "Sources/EaselHost"),
        .target(
            name: "SQLite3",
            path: "Sources/SQLite3",
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "0"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_OMIT_WAL"),
                .define("SQLITE_DEFAULT_LOCKING_MODE", to: "1"),
                .define("SQLITE_TEMP_STORE", to: "3"),
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),
        .target(
            name: "Paintbrush",
            dependencies: [
                "CoreGraphics", "CoreImage", "ImageIO", "UniformTypeIdentifiers", "Compression",
                "AppKit", "CoreText", "CoreVideo", "Vision", "SwiftUI", "simd", "zlib", "SQLite3",
            ],
            path: "Sources/Paintbrush",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "EaselWasm",
            dependencies: ["Paintbrush", "CoreGraphics"],
            path: "Sources/EaselWasm",
            linkerSettings: [
                // A reactor: no main entry point, just the exported functions.
                .unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"]),
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=8388608"]),
                // Canvases are large; let memory grow to WebAssembly's 4 GB.
                .unsafeFlags(["-Xlinker", "--max-memory=4294967296"]),
            ]
        ),
        .executableTarget(name: "StringsTool"),
    ]
)
