// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes test images at runtime, so that the test bundle needs no large fixtures.
public enum SampleImage {
    public enum Error: Swift.Error {
        case encodingFailed(UTType)
    }

    /// Writes a `width`×`height` image to `url`: a gradient with deterministic noise, which keeps
    /// its JPEG thumbnail far larger than a JPEG APP11 segment. A transparent image fades to fully
    /// transparent at its edges.
    public static func write(
        _ type: UTType, transparent: Bool, width: Int = 1600, height: Int = 1200, to url: URL
    ) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0x2545_F491
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                for x in 0..<width {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    let noise = Int(state >> 27) - 16
                    let index = (y * width + x) * 4
                    let edge = min(x, y, width - 1 - x, height - 1 - y)
                    let alpha = transparent ? min(255, edge * 2) : 255
                    let red = UInt8(clamping: x * 255 / width + noise)
                    let green = UInt8(clamping: y * 255 / height - noise)
                    let blue = UInt8(clamping: 128 + noise * 2)
                    // Premultiplied, as CoreGraphics requires.
                    buffer[index] = UInt8(Int(red) * alpha / 255)
                    buffer[index + 1] = UInt8(Int(green) * alpha / 255)
                    buffer[index + 2] = UInt8(Int(blue) * alpha / 255)
                    buffer[index + 3] = UInt8(alpha)
                }
            }
        }
        let alphaInfo: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil
              ) else {
            throw Error.encodingFailed(type)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.encodingFailed(type)
        }
    }

    /// Returns the pixel size and alpha of the first image in `url`, decoded with ImageIO.
    public static func decodedSize(of url: URL) -> (width: Int, height: Int, hasAlpha: Bool)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        return (image.width, image.height, !opaque.contains(image.alphaInfo))
    }

    /// Returns the pixel size of the first image in `data`, decoded with ImageIO.
    public static func decodedSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return (image.width, image.height)
    }
}
