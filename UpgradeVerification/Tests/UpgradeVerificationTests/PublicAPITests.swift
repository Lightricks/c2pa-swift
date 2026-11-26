// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import C2PA
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UpgradeVerification
import XCTest

/// Common uses of the public API beyond `SigningProfile`, so that an upgrade or trim that breaks them
/// fails here. Unlike `UpgradeVerificationTests`, these tests are offline: their manifests have no
/// timestamp. Upstream's own suite runs separately (see `Scripts/upgrade/upstream-tests.sh`).
final class PublicAPITests: XCTestCase {
    private static let trainedAlgorithmicMedia =
        "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
    private static var created: [String: Any] {
        [
            "action": "c2pa.created",
            "digitalSourceType": "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCreation"
        ]
    }

    // MARK: - Reading manifests from other tools

    /// `CACA.jpg` from c2pa-rs: a manifest whose parent ingredient has its own manifest chain.
    func testReadsAThirdPartyManifestChain() throws {
        let url = try fixture("c2pa-rs/CACA.jpg")
        let store = try ManifestStore(json: C2PA.readFile(at: url))
        let reader = try Reader(format: "image/jpeg", stream: Stream(data: Data(contentsOf: url)))
        XCTAssertEqual(try ManifestStore(json: reader.json()).activeLabel, store.activeLabel)
        XCTAssertTrue(reader.isEmbedded())
        XCTAssertNil(reader.remote())

        XCTAssertEqual(store.manifests.count, 2, store.text)
        XCTAssertEqual(store.validationState, "Valid", store.text)
        XCTAssertTrue(store.successCodes.contains("claimSignature.validated"), store.text)
        let ingredients = try XCTUnwrap(store.active["ingredients"] as? [[String: Any]], store.text)
        XCTAssertEqual(ingredients.count, 1)
        XCTAssertEqual(ingredients.first?["relationship"] as? String, "parentOf")
        let parentLabel = try XCTUnwrap(ingredients.first?["active_manifest"] as? String, store.text)
        XCTAssertNotNil(store.manifests[parentLabel], store.text)

        let detailed = try JSONSerialization.jsonObject(with: Data(reader.detailedJSON().utf8))
        let detailedManifests = try XCTUnwrap((detailed as? [String: Any])?["manifests"] as? [String: Any])
        XCTAssertEqual(Set(detailedManifests.keys), Set(store.manifests.keys))
    }

    func testExtractsThumbnailsFromAThirdPartyManifest() throws {
        let reader = try Reader(format: "image/jpeg", stream: Stream(readFrom: fixture("c2pa-rs/CACA.jpg")))
        let store = try ManifestStore(json: reader.json())
        let ingredient = try XCTUnwrap((store.active["ingredients"] as? [[String: Any]])?.first)
        let directory = try temporaryDirectory()
        for (name, owner) in [("claim", store.active), ("ingredient", ingredient)] {
            let thumbnail = try XCTUnwrap(owner["thumbnail"] as? [String: Any], "No \(name) thumbnail")
            let identifier = try XCTUnwrap(thumbnail["identifier"] as? String)
            let output = directory.appendingPathComponent(name)
            try reader.resource(uri: identifier, to: Stream(writeTo: output))
            let size = try XCTUnwrap(SampleImage.decodedSize(of: Data(contentsOf: output)), name)
            XCTAssertGreaterThan(size.width, 0)
        }
        XCTAssertThrowsError(try reader.resource(
            uri: "self#jumbf=missing", to: Stream(writeTo: directory.appendingPathComponent("missing"))
        ))
    }

    // MARK: - Signers and trust

    /// Signs with the Rust signer of each algorithm family through the file convenience API, and
    /// checks that the signing certificate is trusted with c2pa-rs' test roots from JSON settings.
    func testSignsWithRustSignersOfEachAlgorithmFamily() throws {
        let keys: [(SigningAlgorithm, chain: String, key: String)] = [
            (.es256, "es256_certs.pem", "es256_private.key"),
            (.es384, "c2pa-rs/es384.pub", "c2pa-rs/es384.pem"),
            (.ps256, "c2pa-rs/ps256.pub", "c2pa-rs/ps256.pem"),
            (.ed25519, "c2pa-rs/ed25519.pub", "c2pa-rs/ed25519.pem")
        ]
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.jpg")
        try SampleImage.write(.jpeg, transparent: false, width: 64, height: 48, to: source)
        let settings = try C2PASettings(json: trustJSON())
        for (algorithm, chain, key) in keys {
            let output = directory.appendingPathComponent("\(algorithm.rawValue).jpg")
            try C2PA.signFile(
                source: source, destination: output, manifestJSON: manifestJSON(format: "image/jpeg"),
                signerInfo: SignerInfo(
                    algorithm: algorithm, certificatePEM: fixtureText(chain), privateKeyPEM: fixtureText(key)
                )
            )
            let reader = try Reader(
                context: C2PAContext(settings: settings), format: "image/jpeg", stream: Stream(readFrom: output)
            )
            let store = try ManifestStore(json: reader.json())
            let signature = store.active["signature_info"] as? [String: Any]
            XCTAssertEqual((signature?["alg"] as? String)?.lowercased(), algorithm.rawValue, store.text)
            XCTAssertEqual(store.validationState, "Trusted", "\(algorithm): \(store.text)")
            XCTAssertEqual(store.failureCodes, [], "\(algorithm): \(store.text)")
        }
    }

    /// The same trust anchors loaded from TOML, and the untrusted result without them. The signer
    /// is a callback signer that signs with CryptoKit.
    func testTrustAnchorsFromTOMLSettings() throws {
        let directory = try temporaryDirectory()
        let output = try signSample(.png, in: directory)
        let roots = try fixtureText("c2pa-rs/test_cert_root_bundle.pem")
        let settings = try C2PASettings(toml: """
            version = 1

            [[trust.anchors]]
            trust_uri = "https://c2pa-rs/test_cert_trust_list"
            trust_kind = "manifest"
            trust_anchors = '''
            \(roots)'''

            [verify]
            ocsp_fetch = false
            remote_manifest_fetch = false
            """)

        let trusted = try ManifestStore(json: Reader(
            context: C2PAContext(settings: settings), format: "image/png", stream: Stream(readFrom: output)
        ).json())
        XCTAssertEqual(trusted.validationState, "Trusted", trusted.text)
        XCTAssertTrue(trusted.successCodes.contains("signingCredential.trusted"), trusted.text)

        let untrusted = try ManifestStore(
            json: Reader(format: "image/png", stream: Stream(readFrom: output)).json()
        )
        XCTAssertEqual(untrusted.validationState, "Valid", untrusted.text)
        XCTAssertEqual(untrusted.failureCodes, ["signingCredential.untrusted"], untrusted.text)
    }

    // MARK: - Ingredients, resources and archives

    /// Reads the digital source type of an AI-generated parent through the ingredient's manifest,
    /// which lets an edit of an AI-generated image be labeled as AI content. The parent is added
    /// from a stream.
    func testReadsTheDigitalSourceTypeOfAnAIGeneratedParent() throws {
        let directory = try temporaryDirectory()
        let parent = try signSample(.jpeg, in: directory, actions: [
            ["action": "c2pa.created", "digitalSourceType": Self.trainedAlgorithmicMedia]
        ])
        let source = directory.appendingPathComponent("child-source.jpg")
        try SampleImage.write(.jpeg, transparent: false, width: 64, height: 48, to: source)
        let child = directory.appendingPathComponent("child.jpg")
        let builder = try Builder(manifestJSON: manifestJSON(format: "image/jpeg", actions: [
            ["action": "c2pa.opened", "parameters": ["ingredientIds": ["parent"]]],
            ["action": "c2pa.color_adjustments"]
        ]))
        try builder.addIngredient(
            json: #"{"title": "parent.jpg", "relationship": "parentOf", "label": "parent"}"#,
            format: "image/jpeg", from: Stream(readFrom: parent)
        )
        try builder.sign(
            format: "image/jpeg", source: Stream(readFrom: source), destination: Stream(writeTo: child),
            signer: es256Signer()
        )

        let store = try ManifestStore(json: C2PA.readFile(at: child))
        XCTAssertEqual(store.failureCodes, ["signingCredential.untrusted"], store.text)
        XCTAssertEqual(store.digitalSourceTypes(of: store.active), [], store.text)
        let ingredient = try XCTUnwrap((store.active["ingredients"] as? [[String: Any]])?.first, store.text)
        let parentLabel = try XCTUnwrap(ingredient["active_manifest"] as? String, store.text)
        let parentManifest = try XCTUnwrap(store.manifests[parentLabel], store.text)
        XCTAssertEqual(store.digitalSourceTypes(of: parentManifest), [Self.trainedAlgorithmicMedia], store.text)
    }

    /// Writes a builder with a resource and a third-party ingredient to an archive, restores it and
    /// signs a PNG with it.
    func testBuilderArchiveKeepsIngredientsAndResources() throws {
        let directory = try temporaryDirectory()
        let thumbnailURL = directory.appendingPathComponent("thumbnail.jpg")
        try SampleImage.write(.jpeg, transparent: false, width: 32, height: 24, to: thumbnailURL)
        let thumbnail = try Data(contentsOf: thumbnailURL)
        var manifest = try JSONSerialization.jsonObject(with: Data(manifestJSON(format: "image/png").utf8))
            as! [String: Any]
        manifest["thumbnail"] = ["format": "image/jpeg", "identifier": "thumbnail.jpg"]
        let builder = try Builder(manifestJSON: String(
            decoding: JSONSerialization.data(withJSONObject: manifest), as: UTF8.self
        ))
        try builder.addResource(uri: "thumbnail.jpg", stream: Stream(data: thumbnail))
        try builder.addIngredient(
            json: #"{"title": "CACA.jpg", "relationship": "componentOf"}"#, format: "image/jpeg",
            from: Stream(readFrom: fixture("c2pa-rs/CACA.jpg"))
        )
        let archive = directory.appendingPathComponent("builder.c2pa")
        try builder.writeArchive(to: Stream(writeTo: archive))

        let restored = try Builder(archiveStream: Stream(readFrom: archive))
        let source = directory.appendingPathComponent("source.png")
        try SampleImage.write(.png, transparent: true, width: 64, height: 48, to: source)
        let output = directory.appendingPathComponent("signed.png")
        try restored.sign(
            format: "image/png", source: Stream(readFrom: source), destination: Stream(writeTo: output),
            signer: es256Signer()
        )

        let reader = try Reader(format: "image/png", stream: Stream(readFrom: output))
        let store = try ManifestStore(json: reader.json())
        XCTAssertEqual(store.failureCodes, ["signingCredential.untrusted"], store.text)
        XCTAssertEqual(store.manifests.count, 3, "The ingredient's chain should be kept: \(store.text)")
        let ingredient = try XCTUnwrap((store.active["ingredients"] as? [[String: Any]])?.first, store.text)
        XCTAssertEqual(ingredient["title"] as? String, "CACA.jpg")
        XCTAssertEqual(ingredient["relationship"] as? String, "componentOf")
        let identifier = try XCTUnwrap((store.active["thumbnail"] as? [String: Any])?["identifier"] as? String)
        let extracted = directory.appendingPathComponent("extracted")
        try reader.resource(uri: identifier, to: Stream(writeTo: extracted))
        XCTAssertEqual(try Data(contentsOf: extracted), thumbnail)
    }

    /// A manifest that isn't embedded: the image only references its remote URL, and the reader
    /// validates it with the manifest bytes that signing returned.
    func testSidecarManifestWithARemoteURL() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try SampleImage.write(.png, transparent: false, width: 64, height: 48, to: source)
        let output = directory.appendingPathComponent("signed.png")
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/manifests/signed.c2pa"))
        let builder = try Builder(manifestJSON: manifestJSON(format: "image/png"))
        builder.setNoEmbed()
        try builder.setRemote(url: remoteURL)
        let manifest = try builder.sign(
            format: "image/png", source: Stream(readFrom: source), destination: Stream(writeTo: output),
            signer: es256Signer()
        )
        XCTAssertFalse(manifest.isEmpty)

        let offline = try C2PAContext(settings: C2PASettings(json: """
            {"version": 1, "verify": {"remote_manifest_fetch": false, "ocsp_fetch": false}}
            """))
        XCTAssertThrowsError(
            try Reader(context: offline, format: "image/png", stream: Stream(readFrom: output))
        ) {
            XCTAssertTrue("\($0)".contains(remoteURL.absoluteString), "Unexpected error: \($0)")
        }
        let reader = try Reader(
            context: offline, format: "image/png", stream: Stream(readFrom: output), manifest: manifest
        )
        XCTAssertFalse(reader.isEmbedded())
        let store = try ManifestStore(json: reader.json())
        XCTAssertEqual(store.failureCodes, ["signingCredential.untrusted"], store.text)
    }

    // MARK: - Other formats

    /// A lossy WebP from c2pa-rs, since ImageIO can't write WebP.
    func testSignsAndReadsWebP() throws {
        let directory = try temporaryDirectory()
        let output = directory.appendingPathComponent("signed.webp")
        try sign(fixture("c2pa-rs/test.webp"), format: "image/webp", to: output)
        try verifySigned(output, format: "image/webp")
        XCTAssertEqual(SampleImage.decodedSize(of: output)?.width, 128)
    }

    func testSignsAndReadsAVIF() throws {
        let directory = try temporaryDirectory()
        let output = try signSample(XCTUnwrap(UTType("public.avif")), in: directory)
        try verifySigned(output, format: "image/avif")
        XCTAssertEqual(SampleImage.decodedSize(of: output)?.width, 64)
    }

    // MARK: - Removed features

    /// PDF support is removed from the build. If this fails, PDF was re-enabled: check the size and
    /// dependencies, and update the trim documentation.
    func testPDFIsUnsupported() throws {
        XCTAssertFalse(Builder.supportedMimeTypes.contains("application/pdf"), "\(Builder.supportedMimeTypes)")
        XCTAssertFalse(Reader.supportedMimeTypes.contains("application/pdf"), "\(Reader.supportedMimeTypes)")
        let pdf = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
        XCTAssertThrowsError(try Reader(format: "application/pdf", stream: Stream(data: pdf)), "Reader") {
            assertUnsupportedType($0)
        }
        let directory = try temporaryDirectory()
        XCTAssertThrowsError(try Builder(manifestJSON: manifestJSON(format: "application/pdf")).sign(
            format: "application/pdf", source: Stream(data: pdf),
            destination: Stream(writeTo: directory.appendingPathComponent("signed.pdf")), signer: es256Signer()
        ), "Builder") {
            assertUnsupportedType($0)
        }
    }

    /// c2pa-rs reports a format without an asset handler as `NotSupported: type is unsupported`.
    private func assertUnsupportedType(_ error: Error, line: UInt = #line) {
        guard case let C2PAError.api(message) = error else {
            return XCTFail("Unexpected error: \(error)", line: line)
        }
        XCTAssertEqual(message, "NotSupported: type is unsupported", line: line)
    }

    /// Rust-side thumbnail generation is removed, so a manifest only has the thumbnail the caller
    /// adds. If this fails, the `image` crate is back in the build.
    func testDoesNotGenerateThumbnails() throws {
        let context = try C2PAContext(settings: C2PASettings(json: """
            {"version": 1, "builder": {"thumbnail": {"enabled": true}}}
            """))
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.jpg")
        try SampleImage.write(.jpeg, transparent: false, width: 64, height: 48, to: source)
        let output = directory.appendingPathComponent("signed.jpg")
        try Builder(context: context, manifestJSON: manifestJSON(format: "image/jpeg")).sign(
            format: "image/jpeg", source: Stream(readFrom: source), destination: Stream(writeTo: output),
            signer: es256Signer()
        )
        let store = try ManifestStore(json: C2PA.readFile(at: output))
        XCTAssertNil(store.active["thumbnail"], store.text)
    }

    // MARK: - Helpers

    /// The upstream ES256 test key, signed in Rust.
    private func es256Signer() throws -> Signer {
        try Signer(
            certsPEM: fixtureText("es256_certs.pem"), privateKeyPEM: fixtureText("es256_private.key"),
            algorithm: .es256
        )
    }

    /// The upstream ES256 test key, signed by a callback with CryptoKit.
    private func callbackSigner() throws -> Signer {
        let key = try P256.Signing.PrivateKey(pemRepresentation: fixtureText("es256_private.key"))
        return try Signer(algorithm: .es256, certificateChainPEM: fixtureText("es256_certs.pem")) {
            try key.signature(for: $0).derRepresentation
        }
    }

    private func manifestJSON(
        format: String, actions: [[String: Any]] = [PublicAPITests.created]
    ) throws -> String {
        let manifest: [String: Any] = [
            "claim_generator_info": [["name": "UpgradeVerification", "version": "1.0"]],
            "format": format,
            "title": "Signed",
            "assertions": [["label": "c2pa.actions.v2", "data": ["actions": actions]]]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)
    }

    private func trustJSON() throws -> String {
        let settings: [String: Any] = [
            "version": 1,
            "trust": ["anchors": [[
                "trust_uri": "https://c2pa-rs/test_cert_trust_list",
                "trust_kind": "manifest",
                "trust_anchors": try fixtureText("c2pa-rs/test_cert_root_bundle.pem")
            ]]],
            "verify": ["ocsp_fetch": false, "remote_manifest_fetch": false]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
    }

    private func sign(_ source: URL, format: String, to destination: URL) throws {
        try Builder(manifestJSON: manifestJSON(format: format)).sign(
            format: format, source: Stream(readFrom: source), destination: Stream(writeTo: destination),
            signer: es256Signer()
        )
    }

    /// Signs a generated 64×48 image with the callback signer and returns its URL.
    private func signSample(
        _ type: UTType, in directory: URL, actions: [[String: Any]] = [PublicAPITests.created]
    ) throws -> URL {
        let format = try XCTUnwrap(type.preferredMIMEType)
        let fileExtension = try XCTUnwrap(type.preferredFilenameExtension)
        let source = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try SampleImage.write(type, transparent: false, width: 64, height: 48, to: source)
        let output = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try Builder(manifestJSON: manifestJSON(format: format, actions: actions)).sign(
            format: format, source: Stream(readFrom: source), destination: Stream(writeTo: output),
            signer: callbackSigner()
        )
        return output
    }

    /// Reads `url` and checks that its manifest is valid apart from the untrusted test certificate.
    @discardableResult
    private func verifySigned(
        _ url: URL, format: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ManifestStore {
        let store = try ManifestStore(json: Reader(format: format, stream: Stream(readFrom: url)).json())
        XCTAssertEqual(store.validationState, "Valid", store.text, file: file, line: line)
        XCTAssertTrue(
            store.successCodes.contains("claimSignature.validated"), store.text, file: file, line: line
        )
        XCTAssertEqual(store.failureCodes, ["signingCredential.untrusted"], store.text, file: file, line: line)
        return store
    }
}

/// The manifest store JSON of a reader, decoded loosely so that tests can reach any field.
private struct ManifestStore {
    let text: String
    let activeLabel: String
    let manifests: [String: [String: Any]]
    let validationState: String?
    let successCodes: [String]
    let failureCodes: [String]

    var active: [String: Any] {
        manifests[activeLabel] ?? [:]
    }

    init(json: String) throws {
        text = json
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        activeLabel = try XCTUnwrap(root["active_manifest"] as? String, json)
        manifests = try XCTUnwrap(root["manifests"] as? [String: [String: Any]], json)
        validationState = root["validation_state"] as? String
        let results = (root["validation_results"] as? [String: Any])?["activeManifest"] as? [String: Any]
        func codes(_ kind: String) -> [String] {
            (results?[kind] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        }
        successCodes = codes("success")
        failureCodes = codes("failure")
    }

    /// The digital source types of the actions in `manifest`.
    func digitalSourceTypes(of manifest: [String: Any]) -> [String] {
        (manifest["assertions"] as? [[String: Any]] ?? [])
            .filter { ($0["label"] as? String)?.hasPrefix("c2pa.actions") == true }
            .flatMap { ($0["data"] as? [String: Any])?["actions"] as? [[String: Any]] ?? [] }
            .compactMap { $0["digitalSourceType"] as? String }
    }
}
