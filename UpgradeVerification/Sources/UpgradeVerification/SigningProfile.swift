// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import C2PA
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The usage profile that this build supports and that the verification tests sign with: a live
/// RFC 3161 timestamp from DigiCert through the async signer, without a custom HTTP resolver; a
/// network allowlist that only permits the timestamp authority; thumbnails made by the caller;
/// and parent ingredients from archives, including archives written by the previous release
/// (v0.0.16).
public enum SigningProfile {
    /// The RFC 3161 timestamp authority.
    public static let timestampAuthority = URL(string: "http://timestamp.digicert.com")!

    /// The only host C2PA may contact.
    public static let allowedNetworkHost = "timestamp.digicert.com"

    /// Time limit of each timestamp request.
    public static let timestampRequestTimeoutInMilliseconds = 15_000

    /// Length, in pixels, of the long edge of the manifest thumbnail.
    public static let thumbnailLongEdge = 1024

    /// Compression quality of JPEG thumbnails.
    public static let thumbnailJPEGQuality = 0.75

    /// Label of the ingredient that stands for the opened image.
    public static let parentIngredientLabel = "parentIngredient"

    /// Name of the claim generator of every manifest, and of the v0.0.16 archive fixtures.
    public static let claimGeneratorName = "UpgradeVerification"

    /// Thumbnail embedded as the claim thumbnail.
    public struct Thumbnail: Sendable, Equatable {
        /// MIME type of `data`.
        public let format: String

        /// Encoded thumbnail.
        public let data: Data
    }

    /// Version of the linked C2PA library.
    public static var libraryVersion: String {
        C2PA.version
    }

    public enum Error: Swift.Error {
        case noThumbnail(URL)
    }

    /// Returns the signing context: C2PA may contact the timestamp authority only, and neither
    /// fetches OCSP responses nor remote manifests.
    public static func makeContext() throws -> C2PAContext {
        let settings = try C2PASettings(json: """
            {
                "version": 1,
                "core": {
                    "allowed_network_hosts": ["\(allowedNetworkHost)"],
                    "time_stamp_request_timeout_in_ms": \(timestampRequestTimeoutInMilliseconds)
                },
                "verify": {"ocsp_fetch": false, "remote_manifest_fetch": false}
            }
            """)
        return try C2PAContext(settings: settings)
    }

    /// Returns a thumbnail of the image at `url` whose long edge is at most `thumbnailLongEdge`. The
    /// thumbnail is a JPEG, or a PNG if the image has alpha.
    public static func makeThumbnail(ofImageAt url: URL) -> Thumbnail? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailLongEdge
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        return encode(thumbnail: image, as: opaque.contains(image.alphaInfo) ? .jpeg : .png)
    }

    private static func encode(thumbnail image: CGImage, as format: UTType) -> Thumbnail? {
        let data = NSMutableData()
        guard let mimeType = format.preferredMIMEType,
              let destination = CGImageDestinationCreateWithData(
                data, format.identifier as CFString, 1, nil
              ) else {
            return nil
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: thumbnailJPEGQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return Thumbnail(format: mimeType, data: data as Data)
    }

    /// Returns the manifest of an image opened from a parent and edited with AI. The parent
    /// ingredient is part of the definition only if it doesn't come from an archive.
    public static func manifestDefinition(
        title: String, format: String, parentFromArchive: Bool, thumbnail: Thumbnail
    ) -> ManifestDefinition {
        let opened: [String: Any] = [
            "action": PredefinedAction.opened.rawValue,
            "parameters": ["ingredientIds": [parentIngredientLabel]]
        ]
        let editedWithAI: [String: Any] = [
            "action": PredefinedAction.edited.rawValue,
            "digitalSourceType": DigitalSourceType.compositeWithTrainedAlgorithmicMedia.rawValue
        ]
        let actions = AssertionDefinition.custom(
            label: StandardAssertionLabel.actionsV2.rawValue,
            data: AnyCodable(
                ["allActionsIncluded": false, "actions": [opened, editedWithAI]] as [String: Any]
            )
        )
        let ingredients = parentFromArchive
            ? [] : [Ingredient(label: parentIngredientLabel, relationship: .parentOf)]
        var definition = ManifestDefinition(
            assertions: [actions], claimGeneratorInfo: [ClaimGeneratorInfo(name: claimGeneratorName)],
            format: format, ingredients: ingredients, title: title
        )
        definition.thumbnail = ResourceRef(format: thumbnail.format, identifier: "thumbnail")
        return definition
    }

    /// Writes a signed copy of the image at `source` to `destination` and returns the embedded
    /// thumbnail. `sign` returns the DER ECDSA signature of its argument. `timestampAuthority` is a
    /// parameter so that tests can point it elsewhere.
    @discardableResult
    public static func sign(
        imageAt source: URL, format: String, to destination: URL, parentIngredientArchive: URL?,
        certificateChainPEM: String, timestampAuthority: URL? = timestampAuthority,
        sign: @escaping @Sendable (Data) async throws -> Data
    ) throws -> Thumbnail {
        guard let thumbnail = makeThumbnail(ofImageAt: source) else {
            throw Error.noThumbnail(source)
        }
        let builder = try makeBuilder(
            context: makeContext(), title: source.lastPathComponent, format: format, thumbnail: thumbnail,
            parentIngredientArchive: parentIngredientArchive
        )
        try builder.sign(
            format: format, source: .init(readFrom: source), destination: .init(writeTo: destination),
            signer: makeSigner(
                certificateChainPEM: certificateChainPEM, timestampAuthority: timestampAuthority, sign: sign
            )
        )
        return thumbnail
    }

    private static func makeSigner(
        certificateChainPEM: String, timestampAuthority: URL?,
        sign: @escaping @Sendable (Data) async throws -> Data
    ) throws -> Signer {
        try Signer(
            algorithm: .es256, certificateChainPEM: certificateChainPEM, tsa: timestampAuthority,
            asyncSigner: sign
        )
    }

    private static func makeBuilder(
        context: C2PAContext, title: String, format: String, thumbnail: Thumbnail,
        parentIngredientArchive: URL?
    ) throws -> Builder {
        let definition = manifestDefinition(
            title: title, format: format, parentFromArchive: parentIngredientArchive != nil,
            thumbnail: thumbnail
        )
        let builder = try Builder(context: context, manifest: definition)
        try builder.addResource(uri: "thumbnail", stream: .init(data: thumbnail.data))
        if let parentIngredientArchive {
            try builder.addIngredient(fromArchive: .init(readFrom: parentIngredientArchive))
        }
        return builder
    }

    /// Returns a reader of the asset at `url` that trusts `timestampRoots` for timestamps.
    public static func reader(for url: URL, format: String, timestampRoots: String) throws -> Reader {
        let configuration: [String: Any] = [
            "version": 1,
            "trust": [
                "anchors": [[
                    "trust_kind": "tsa",
                    "trust_uri": "https://www.digicert.com/",
                    "trust_anchors": timestampRoots
                ]]
            ],
            "verify": [
                "ocsp_fetch": false, "remote_manifest_fetch": false, "verify_timestamp_trust": true
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: configuration)
        let settings = try C2PASettings(json: String(decoding: json, as: UTF8.self))
        return try Reader(
            context: C2PAContext(settings: settings), format: format, stream: .init(readFrom: url)
        )
    }
}
