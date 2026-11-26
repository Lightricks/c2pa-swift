// swift-tools-version:6.0

// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import PackageDescription

// Writes the `v0.0.16-ingredient-*.c2pa` ingredient archive fixtures with c2pa-swift v0.0.16, the
// release before the upgrade. See `Tests/UpgradeVerificationTests/Fixtures/README.md`.
let package = Package(
    name: "FixtureGenerator",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/contentauth/c2pa-swift", exact: "0.0.16")],
    targets: [
        .executableTarget(
            name: "GenerateFixtures",
            dependencies: [.product(name: "C2PA", package: "c2pa-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
