// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

// Signs synthetic images with c2pa-swift v0.0.16 in the signing profile that `SigningProfile` in the
// UpgradeVerification package covers, as far as v0.0.16's API allows: a manifest with a parent
// ingredient and an AI edit, a 1024 px thumbnail made by the caller, and a DigiCert timestamp
// through an HTTP resolver limited to the timestamp authority. It then writes the parent ingredient
// archive of each signed image. The upstream ES256 test key signs.
//
// Usage: swift run GenerateFixtures <directory with es256_certs.pem and es256_private.key> <output>

import C2PA
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let timestampAuthority = URL(string: "http://timestamp.digicert.com")!
let httpRequestTimeout: TimeInterval = 15
let thumbnailLongEdge = 1024
let thumbnailJPEGQuality = 0.75
let parentIngredientLabel = "parentIngredient"
let claimGeneratorName = "UpgradeVerification"

enum GeneratorError: Error {
    case usage, encoding(String), disallowedRequest(URL), timedOut(URL), noThumbnail
}

/// A 1600×1200 image of flat color blocks, which keeps the encoded fixtures small. The transparent
/// variant has a transparent border.
func syntheticImage(transparent: Bool) throws -> CGImage {
    let width = 1600, height = 1200
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: transparent
            ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw GeneratorError.encoding("context")
    }
    let colors: [(CGFloat, CGFloat, CGFloat)] = [
        (0.95, 0.35, 0.2), (0.2, 0.6, 0.9), (0.3, 0.8, 0.4), (0.95, 0.8, 0.2), (0.6, 0.3, 0.8)
    ]
    let inset = transparent ? 160 : 0
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    for row in 0..<4 {
        for column in 0..<5 {
            let (red, green, blue) = colors[(row + column) % colors.count]
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            let blockWidth = (width - 2 * inset) / 5, blockHeight = (height - 2 * inset) / 4
            context.fill(CGRect(
                x: inset + column * blockWidth, y: inset + row * blockHeight, width: blockWidth,
                height: blockHeight
            ))
        }
    }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fillEllipse(in: CGRect(x: 600, y: 400, width: 400, height: 400))
    return context.makeImage()!
}

func encode(_ image: CGImage, as type: UTType) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
    else {
        throw GeneratorError.encoding(type.identifier)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw GeneratorError.encoding(type.identifier)
    }
    return data as Data
}

// MARK: - Signing

struct Thumbnail {
    let format: String
    let data: Data
}

func makeThumbnail(ofImageAt url: URL) -> Thumbnail? {
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: thumbnailLongEdge
    ] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
        return nil
    }
    let format: UTType
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: format = .jpeg
    default: format = .png
    }
    let data = NSMutableData()
    guard let mimeType = format.preferredMIMEType,
          let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil)
    else {
        return nil
    }
    let properties = [kCGImageDestinationLossyCompressionQuality: thumbnailJPEGQuality]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        return nil
    }
    return Thumbnail(format: mimeType, data: data as Data)
}

func resolve(_ request: HTTPRequest) throws -> HTTPResponse {
    guard request.url.scheme == timestampAuthority.scheme, request.url.host == timestampAuthority.host,
          request.url.port == timestampAuthority.port else {
        throw GeneratorError.disallowedRequest(request.url)
    }
    var urlRequest = URLRequest(url: request.url, timeoutInterval: httpRequestTimeout)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let completion = DispatchSemaphore(value: 0)
    var result: Result<HTTPResponse, Error>?
    let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
        if let error {
            result = .failure(error)
        } else if let response = response as? HTTPURLResponse {
            result = .success(HTTPResponse(status: response.statusCode, body: data ?? Data()))
        } else {
            result = .failure(GeneratorError.disallowedRequest(request.url))
        }
        completion.signal()
    }
    task.resume()
    guard completion.wait(timeout: .now() + httpRequestTimeout) == .success, let result else {
        task.cancel()
        throw GeneratorError.timedOut(request.url)
    }
    return try result.get()
}

func manifestDefinition(title: String, format: String, thumbnail: Thumbnail) -> ManifestDefinition {
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
        data: AnyCodable(["allActionsIncluded": false, "actions": [opened, editedWithAI]] as [String: Any])
    )
    var definition = ManifestDefinition(
        assertions: [actions], claimGeneratorInfo: [ClaimGeneratorInfo(name: claimGeneratorName)],
        format: format, ingredients: [Ingredient(label: parentIngredientLabel, relationship: .parentOf)],
        title: title
    )
    definition.thumbnail = ResourceRef(format: thumbnail.format, identifier: "thumbnail")
    return definition
}

func sign(imageAt url: URL, format: String, certificateChain: String, key: P256.Signing.PrivateKey) throws {
    let signer = try Signer(
        algorithm: .es256, certificateChainPEM: certificateChain, tsa: timestampAuthority,
        asyncSigner: { try key.signature(for: $0).derRepresentation }
    )
    let settings = try C2PASettings(definition: C2PASettingsDefinition(
        version: 1, verify: VerifySettings(ocspFetch: false, remoteManifestFetch: false)
    ))
    let context = try C2PAContext(settings: settings, httpResolver: { try resolve($0) })
    guard let thumbnail = makeThumbnail(ofImageAt: url) else {
        throw GeneratorError.noThumbnail
    }
    let builder = try Builder(
        context: context,
        manifest: manifestDefinition(title: url.lastPathComponent, format: format, thumbnail: thumbnail)
    )
    try builder.addResource(uri: "thumbnail", stream: .init(data: thumbnail.data))
    let signed = url.appendingPathExtension("signed")
    try builder.sign(
        format: format, source: .init(readFrom: url), destination: .init(writeTo: signed), signer: signer
    )
    _ = try FileManager.default.replaceItemAt(url, withItemAt: signed)
}

// MARK: - Ingredient archives

func writeArchive(ofImageData data: Data, format: String, to url: URL) throws {
    let settings = try C2PASettings(definition: C2PASettingsDefinition(
        version: 1,
        verify: VerifySettings(ocspFetch: false, remoteManifestFetch: false),
        builder: BuilderSettingsDefinition(
            thumbnail: ThumbnailSettings(enabled: false), generateC2paArchive: true
        )
    ))
    let context = try C2PAContext(settings: settings)
    _ = try Reader(context: context, format: format, stream: .init(data: data))
    let ingredient = Ingredient(format: format, label: parentIngredientLabel, relationship: .parentOf)
    let builder = try Builder(context: context, manifest: ManifestDefinition(
        claimGeneratorInfo: [ClaimGeneratorInfo(name: claimGeneratorName)], format: format,
        title: "Parent ingredient"
    ))
    try builder.addIngredient(json: C2PAJson.encode(ingredient), format: format, from: .init(data: data))
    try builder.writeIngredientArchive(id: parentIngredientLabel, to: .init(writeTo: url))
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    throw GeneratorError.usage
}
let resources = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let certificateChain = try String(
    contentsOf: resources.appendingPathComponent("es256_certs.pem"), encoding: .utf8
)
let key = try P256.Signing.PrivateKey(pemRepresentation: String(
    contentsOf: resources.appendingPathComponent("es256_private.key"), encoding: .utf8
))
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let inputs: [(name: String, type: UTType, transparent: Bool)] = [
    ("jpeg.jpg", .jpeg, false), ("png-alpha.png", .png, true), ("heic.heic", .heic, false)
]
for input in inputs {
    let url = scratch.appendingPathComponent(input.name)
    try encode(syntheticImage(transparent: input.transparent), as: input.type).write(to: url)
    let format = input.type.preferredMIMEType!
    try sign(imageAt: url, format: format, certificateChain: certificateChain, key: key)
    let archive = output.appendingPathComponent("v0.0.16-ingredient-\(input.name).c2pa")
    try writeArchive(ofImageData: Data(contentsOf: url), format: format, to: archive)
    print("\(archive.lastPathComponent): \(try Data(contentsOf: archive).count) bytes")
}
print("C2PA \(C2PA.version)")
