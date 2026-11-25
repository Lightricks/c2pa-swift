// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import C2PA
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UpgradeVerification
import XCTest

/// Parent ingredient archive of a timestamped image, written with c2pa-swift v0.0.16, the previous
/// release.
private struct ParentArchive {
    let filename: String

    static func previousRelease(_ format: String) -> Self {
        .init(filename: "v0.0.16-ingredient-\(format).c2pa")
    }
}

final class UpgradeVerificationTests: XCTestCase {
    private static let sourceSize = (width: 1600, height: 1200)

    func testJPEG() throws { try signAndVerify(.jpeg) }
    func testPNG() throws { try signAndVerify(.png) }
    func testTransparentPNG() throws { try signAndVerify(.png, transparent: true) }
    func testHEIC() throws { try signAndVerify(.heic) }
    func testTIFF() throws { try signAndVerify(.tiff) }

    func testParentFromPreviousReleaseJPEGArchive() throws {
        try signAndVerify(.jpeg, parent: .previousRelease("jpeg.jpg"))
    }

    func testParentFromPreviousReleaseTransparentPNGArchive() throws {
        try signAndVerify(.png, transparent: true, parent: .previousRelease("png-alpha.png"))
    }

    func testParentFromPreviousReleaseHEICArchive() throws {
        try signAndVerify(.heic, parent: .previousRelease("heic.heic"))
    }

    /// C2PA must refuse to contact a timestamp authority outside `allowed_network_hosts`. The
    /// authority is a loopback listener, which C2PA would connect to if the allowed list weren't
    /// enforced, since only link-local and cloud metadata addresses are blocked by default.
    func testRejectsTimestampAuthorityOutsideTheAllowedHosts() throws {
        let listener = try LoopbackListener()
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.jpg")
        try SampleImage.write(.jpeg, transparent: false, to: source)
        let authority = try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)/"))
        let certificateChain = try fixtureText("es256_certs.pem")
        let signer = try testSigner()

        XCTAssertThrowsError(try SigningProfile.sign(
            imageAt: source, format: "image/jpeg", to: directory.appendingPathComponent("signed.jpg"),
            parentIngredientArchive: nil, certificateChainPEM: certificateChain,
            timestampAuthority: authority, sign: signer
        )) { error in
            XCTAssertTrue(
                "\(error)".contains("not permitted by the allowed list"), "Unexpected error: \(error)"
            )
        }
        XCTAssertFalse(listener.receivedConnection(), "C2PA connected to a host outside the allowed list")
    }

    // MARK: - Signing and verification

    private func signAndVerify(
        _ type: UTType, transparent: Bool = false, parent: ParentArchive? = nil
    ) throws {
        let mimeType = try XCTUnwrap(type.preferredMIMEType)
        let fileExtension = try XCTUnwrap(type.preferredFilenameExtension)
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.\(fileExtension)")
        try SampleImage.write(type, transparent: transparent, to: source)
        let output = directory.appendingPathComponent("signed.\(fileExtension)")

        let signingStart = Date()
        let thumbnail = try SigningProfile.sign(
            imageAt: source, format: mimeType, to: output,
            parentIngredientArchive: parent.map { try fixture($0.filename) },
            certificateChainPEM: fixtureText("es256_certs.pem"), sign: testSigner()
        )

        let decoded = try XCTUnwrap(SampleImage.decodedSize(of: output), "ImageIO can't decode the output")
        XCTAssertEqual(decoded.width, Self.sourceSize.width)
        XCTAssertEqual(decoded.height, Self.sourceSize.height)
        XCTAssertEqual(decoded.hasAlpha, transparent)
        if type == .jpeg {
            XCTAssertGreaterThan(
                try app11SegmentCount(Data(contentsOf: output)), 1,
                "The manifest should span several APP11 segments"
            )
        }

        let reader = try SigningProfile.reader(
            for: output, format: mimeType, timestampRoots: fixtureText("DigiCertTrustedRootG4.pem")
        )
        let json = try reader.json()
        let store = try JSONDecoder().decode(ManifestStore.self, from: Data(json.utf8))
        let manifest = try XCTUnwrap(store.manifests[store.activeManifest])
        let results = try XCTUnwrap(store.validationResults.activeManifest, json)
        verify(results, timestampTrusted: true, json: json)
        XCTAssertEqual(manifest.claimGeneratorInfo.first?.name, SigningProfile.claimGeneratorName)
        let deltaFailures = (store.validationResults.ingredientDeltas ?? [])
            .flatMap { $0.validationDeltas.failure ?? [] }.map(\.code)
        XCTAssertEqual(deltaFailures, [], json)

        let timestampText = try XCTUnwrap(
            manifest.signatureInfo.time, "The active manifest must contain a DigiCert timestamp"
        )
        try verifyTimestamp(timestampText, isAfter: signingStart)

        let thumbnailResource = try XCTUnwrap(manifest.thumbnail)
        XCTAssertEqual(thumbnailResource.format, transparent ? "image/png" : "image/jpeg")
        XCTAssertEqual(thumbnail.format, thumbnailResource.format)
        let storedThumbnail = directory.appendingPathComponent("thumbnail")
        try reader.resource(uri: thumbnailResource.identifier, to: .init(writeTo: storedThumbnail))
        let thumbnailData = try Data(contentsOf: storedThumbnail)
        XCTAssertEqual(thumbnailData, thumbnail.data)
        let thumbnailSize = try XCTUnwrap(SampleImage.decodedSize(of: thumbnailData))
        XCTAssertEqual(max(thumbnailSize.width, thumbnailSize.height), SigningProfile.thumbnailLongEdge)

        let ingredients = manifest.ingredients ?? []
        XCTAssertEqual(ingredients.count, 1, json)
        let ingredient = try XCTUnwrap(ingredients.first)
        XCTAssertEqual(ingredient.relationship, "parentOf")
        guard parent != nil else {
            XCTAssertNil(ingredient.activeManifest, "A parent of unknown provenance has no manifest")
            return
        }

        let parentLabel = try XCTUnwrap(ingredient.activeManifest, "The parent's manifest is missing")
        let parentManifest = try XCTUnwrap(store.manifests[parentLabel], json)
        XCTAssertEqual(parentManifest.claimGeneratorInfo.first?.name, SigningProfile.claimGeneratorName)
        XCTAssertNotNil(parentManifest.signatureInfo.time, json)
        let parentResults = try XCTUnwrap(ingredient.validationResults?.activeManifest, json)
        verify(parentResults, json: json)
    }

    private func verify(
        _ statuses: ManifestStore.Statuses, timestampTrusted: Bool = false,
        json: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        verifySignatureAndTimestamp(
            success: statuses.success.map(\.code), failures: (statuses.failure ?? []).map(\.code),
            timestampTrusted: timestampTrusted, json: json, file: file, line: line
        )
    }

    // MARK: - Helpers

    private func testSigner() throws -> @Sendable (Data) async throws -> Data {
        let key = try P256.Signing.PrivateKey(pemRepresentation: fixtureText("es256_private.key"))
        return { try key.signature(for: $0).derRepresentation }
    }

    /// Returns the number of APP11 segments, which carry the C2PA manifest, before the image data.
    private func app11SegmentCount(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8])
        var offset = 2
        var count = 0
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] != 0xDA {
            if bytes[offset + 1] == 0xEB {
                count += 1
            }
            offset += 2 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
        }
        return count
    }
}

/// TCP listener on the loopback interface that records whether a client connected.
private final class LoopbackListener {
    private let descriptor: Int32
    let port: UInt16

    init() throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let descriptor = descriptor
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, length) == 0 && listen(descriptor, 8) == 0
                    && getsockname(descriptor, address, &length) == 0
            }
        }
        guard descriptor >= 0, bound, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    /// Whether a client connected. The kernel accepts connections into the backlog by itself.
    func receivedConnection() -> Bool {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
            return false
        }
        close(client)
        return true
    }

    deinit {
        close(descriptor)
    }
}

private struct ManifestStore: Decodable {
    let activeManifest: String
    let manifests: [String: Manifest]
    let validationResults: ValidationResults

    enum CodingKeys: String, CodingKey {
        case activeManifest = "active_manifest"
        case manifests
        case validationResults = "validation_results"
    }

    struct Manifest: Decodable {
        let claimGeneratorInfo: [ClaimGenerator]
        let signatureInfo: SignatureInfo
        let thumbnail: Thumbnail?
        let ingredients: [Ingredient]?

        enum CodingKeys: String, CodingKey {
            case claimGeneratorInfo = "claim_generator_info"
            case signatureInfo = "signature_info"
            case thumbnail, ingredients
        }
    }

    struct ClaimGenerator: Decodable {
        let name: String
    }

    struct SignatureInfo: Decodable {
        let time: String?
    }

    struct Thumbnail: Decodable {
        let format: String
        let identifier: String
    }

    struct Ingredient: Decodable {
        let relationship: String
        let activeManifest: String?
        let validationResults: ValidationResults?

        enum CodingKeys: String, CodingKey {
            case relationship
            case activeManifest = "active_manifest"
            case validationResults = "validation_results"
        }
    }

    struct ValidationResults: Decodable {
        let activeManifest: Statuses?
        let ingredientDeltas: [IngredientDelta]?
    }

    struct IngredientDelta: Decodable {
        let validationDeltas: Statuses
    }

    struct Statuses: Decodable {
        let success: [Status]
        let failure: [Status]?
    }

    struct Status: Decodable {
        let code: String
    }
}
