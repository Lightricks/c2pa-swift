// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import CryptoKit
import SwiftUI
import UpgradeVerification

/// App that links the C2PA package for iOS devices. CI only builds it: linking the app resolves every
/// symbol the static C2PA library needs, which building the package's library target doesn't.
@main
struct DeviceLinkCheckApp: App {
    @State private var status = "C2PA \(SigningProfile.libraryVersion)"

    var body: some Scene {
        WindowGroup {
            VStack {
                Text(status)
                Button("Sign") { status = sign() }
            }
        }
    }

    private func sign() -> String {
        let directory = FileManager.default.temporaryDirectory
        let source = directory.appendingPathComponent("source.jpg")
        let key = P256.Signing.PrivateKey()
        do {
            try SampleImage.write(.jpeg, transparent: false, to: source)
            try SigningProfile.sign(
                imageAt: source, format: "image/jpeg", to: directory.appendingPathComponent("signed.jpg"),
                parentIngredientArchive: nil, certificateChainPEM: "",
                sign: { try key.signature(for: $0).derRepresentation }
            )
            return "Signed"
        } catch {
            return "\(error)"
        }
    }
}
