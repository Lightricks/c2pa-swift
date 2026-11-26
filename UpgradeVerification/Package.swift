// swift-tools-version:6.3

// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import PackageDescription

let package = Package(
    name: "UpgradeVerification",
    platforms: [.iOS(.v16)],
    products: [.library(name: "UpgradeVerification", targets: ["UpgradeVerification"])],
    dependencies: [.package(path: "../c2pa-swift")],
    targets: [
        .target(
            name: "UpgradeVerification",
            dependencies: [.product(name: "C2PA", package: "c2pa-swift")]
        ),
        .testTarget(
            name: "UpgradeVerificationTests",
            dependencies: ["UpgradeVerification", .product(name: "C2PA", package: "c2pa-swift")],
            resources: [.copy("Fixtures")]
        )
    ]
)
