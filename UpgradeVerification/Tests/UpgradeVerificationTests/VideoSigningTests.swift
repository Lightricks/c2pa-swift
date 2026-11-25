// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import AVFoundation
import C2PA
import CryptoKit
import Foundation
import UpgradeVerification
import XCTest

/// Signs QuickTime and MP4 movies written by AVFoundation with `SigningProfile`: a live DigiCert
/// timestamp, the timestamp authority as the only allowed host and a thumbnail made by the caller,
/// as for images, plus file streams and the video backing store threshold.
final class VideoSigningTests: XCTestCase {
    private static let quickTime = "video/quicktime"
    private static let mp4 = "video/mp4"

    func testMOVH264WithAAC() async throws {
        try await signAndVerify(.init(fileType: .mov, codec: .h264), format: Self.quickTime)
    }

    func testMOVHEVCHDR() async throws {
        try await signAndVerify(.init(fileType: .mov, codec: .hevc, hdr: true), format: Self.quickTime)
    }

    func testMP4H264WithAAC() async throws {
        try await signAndVerify(.init(fileType: .mp4, codec: .h264), format: Self.mp4)
    }

    /// A video opened from a signed video: the parent's ingredient archive is added to the new
    /// video's manifest, and the chain reads back with both manifests valid.
    func testParentFromVideoArchive() async throws {
        let directory = try temporaryDirectory()
        let parentSource = directory.appendingPathComponent("parent-source.mov")
        try SampleVideo.write(.init(fileType: .mov, codec: .hevc, frameCount: 15), to: parentSource)
        let parent = directory.appendingPathComponent("parent.mov")
        try await sign(parentSource, format: Self.quickTime, to: parent)
        let archive = directory.appendingPathComponent("parent.c2pa")
        try SigningProfile.writeParentIngredientArchive(ofVideoAt: parent, format: Self.quickTime, to: archive)

        try await signAndVerify(
            .init(fileType: .mov, codec: .h264, frameCount: 15), format: Self.quickTime,
            parentIngredientArchive: archive
        )
    }

    /// Changing one byte of the media data after signing must fail the BMFF hash.
    func testTamperedMediaFailsValidation() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.mov")
        try SampleVideo.write(.init(fileType: .mov, codec: .h264), to: source)
        let signed = directory.appendingPathComponent("signed.mov")
        try await sign(source, format: Self.quickTime, to: signed)

        let mdat = try XCTUnwrap(topLevelBoxes(of: signed).first { $0.type == "mdat" })
        let handle = try FileHandle(forUpdating: signed)
        let offset = mdat.payloadOffset + (mdat.end - mdat.payloadOffset) / 2
        try handle.seek(toOffset: offset)
        let byte = try XCTUnwrap(handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: [byte ^ 0xFF])
        try handle.close()

        let store = try await read(signed, format: Self.quickTime)
        XCTAssertEqual(store.validationState, "Invalid", store.text)
        XCTAssertTrue(store.failureCodes.contains("assertion.bmffHash.mismatch"), store.text)
    }

    /// Signing a video of a few hundred megabytes on a dispatch queue and reading it back must raise
    /// peak memory by much less than the file's size. Signing with `Stream(readFrom:)` or c2pa-rs's
    /// default backing store threshold rises by about the file's size. Reading with
    /// `Stream(readFrom:)` rises like that only above 512 MB, so this file doesn't catch it.
    func testLargeVideoKeepsMemoryFlat() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.mov")
        let start = Date()
        try await writeLongVideo(
            repeating: .init(
                fileType: .mov, codec: .h264, width: 1280, height: 720, frameCount: 60,
                bitRate: 50_000_000, audio: false
            ),
            minimumSize: 320_000_000, in: directory, to: source
        )
        let writing = Date().timeIntervalSince(start)
        let size = try fileSize(of: source)
        XCTAssertGreaterThanOrEqual(size, 300_000_000)
        let thumbnail = try await SigningProfile.makeThumbnail(ofVideoAt: source)
        let signed = directory.appendingPathComponent("signed.mov")

        let signing = try await measured {
            try await self.sign(source, format: Self.quickTime, thumbnail: thumbnail, to: signed)
        }
        try FileManager.default.removeItem(at: source)
        let reading = try await measured {
            let store = try await self.read(signed, format: Self.quickTime)
            XCTAssertEqual(store.validationState, "Valid", store.text)
            XCTAssertTrue(store.successCodes.contains("assertion.bmffHash.match"), store.text)
        }
        print(String(
            format: "C2PA video memory: %.0f MB written in %.1f s; sign %.1f s +%.0f MB; read %.1f s +%.0f MB",
            Double(size) / 1e6, writing, signing.seconds, signing.peakMegabytes, reading.seconds,
            reading.peakMegabytes
        ))
        XCTAssertLessThan(signing.peakMegabytes, Self.largeVideoMemoryBoundInMegabytes)
        XCTAssertLessThan(reading.peakMegabytes, Self.largeVideoMemoryBoundInMegabytes)
    }

    /// Bound of the rise in peak memory in `testLargeVideoKeepsMemoryFlat`, with room for noise. It is
    /// about 35 MB locally at any size, and over 300 MB if memory grows with the file.
    private static let largeVideoMemoryBoundInMegabytes = 100.0

    /// Local measurement, not run in CI: signs and reads 4K HEVC exports of 6 s, 60 s and 180 s at
    /// about 50 Mbit/s, reporting time and the rise in peak memory. Run with
    /// `TEST_RUNNER_C2PA_VIDEO_PERF=1 xcodebuild test ...`.
    func testPerformanceOfLarge4KExports() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["C2PA_VIDEO_PERF"] != nil, "Set TEST_RUNNER_C2PA_VIDEO_PERF=1 to measure"
        )
        let directory = try temporaryDirectory()
        let clip = directory.appendingPathComponent("clip.mov")
        try SampleVideo.write(.init(
            fileType: .mov, codec: .hevc, width: 3840, height: 2160, frameCount: 180, bitRate: 50_000_000
        ), to: clip)
        for repeats in [1, 10, 30] {
            let source = directory.appendingPathComponent("source-\(repeats).mov")
            try await repeatClip(clip, times: repeats, to: source)
            let size = try fileSize(of: source)
            let duration = try await AVURLAsset(url: source).load(.duration).seconds
            let signed = directory.appendingPathComponent("signed-\(repeats).mov")
            var thumbnail: SigningProfile.Thumbnail?
            let thumbnailing = try await measured {
                thumbnail = try await SigningProfile.makeThumbnail(ofVideoAt: source)
            }
            let signing = try await measured {
                try await self.sign(source, format: Self.quickTime, thumbnail: XCTUnwrap(thumbnail), to: signed)
            }
            let reading = try await measured {
                let store = try await self.read(signed, format: Self.quickTime)
                XCTAssertEqual(store.validationState, "Valid", store.text)
            }
            print(String(
                format: "C2PA video perf: %.0f s, %.0f MB: thumbnail %.2f s +%.0f MB; "
                    + "sign %.2f s +%.0f MB; read %.2f s +%.0f MB",
                duration, Double(size) / 1e6, thumbnailing.seconds, thumbnailing.peakMegabytes,
                signing.seconds, signing.peakMegabytes, reading.seconds, reading.peakMegabytes
            ))
            try FileManager.default.removeItem(at: source)
            try FileManager.default.removeItem(at: signed)
        }
    }

    // MARK: - Signing and verification

    private func signAndVerify(
        _ settings: SampleVideo.Settings, format: String, parentIngredientArchive: URL? = nil
    ) async throws {
        let directory = try temporaryDirectory()
        let fileExtension = settings.fileType == .mp4 ? "mp4" : "mov"
        let source = directory.appendingPathComponent("source.\(fileExtension)")
        try SampleVideo.write(settings, to: source)
        let signed = directory.appendingPathComponent("signed.\(fileExtension)")

        let signingStart = Date()
        let thumbnail = try await sign(
            source, format: format, to: signed, parentIngredientArchive: parentIngredientArchive
        )

        let store = try await read(signed, format: format)
        XCTAssertEqual(store.validationState, "Valid", store.text)
        verifySignatureAndTimestamp(
            success: store.successCodes, failures: store.failureCodes, timestampTrusted: true, json: store.text
        )
        XCTAssertTrue(store.successCodes.contains("assertion.bmffHash.match"), store.text)
        let labels = (store.active["assertions"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        XCTAssertTrue(labels.contains { $0.hasPrefix("c2pa.hash.bmff") }, "\(labels)")
        XCTAssertFalse(labels.contains { $0.hasPrefix("c2pa.hash.data") }, "\(labels)")
        XCTAssertEqual(store.ingredientDeltaFailureCodes, [], store.text)

        let signatureInfo = store.active["signature_info"] as? [String: Any]
        let timestampText = try XCTUnwrap(signatureInfo?["time"] as? String, store.text)
        try verifyTimestamp(timestampText, isAfter: signingStart)

        let thumbnailResource = try XCTUnwrap(store.active["thumbnail"] as? [String: Any], store.text)
        XCTAssertEqual(thumbnailResource["format"] as? String, "image/jpeg")
        let storedThumbnail = directory.appendingPathComponent("thumbnail")
        try SigningProfile.reader(
            for: signed, format: format, timestampRoots: fixtureText("DigiCertTrustedRootG4.pem")
        ).resource(
            uri: XCTUnwrap(thumbnailResource["identifier"] as? String), to: .init(writeTo: storedThumbnail)
        )
        XCTAssertEqual(try Data(contentsOf: storedThumbnail), thumbnail.data)
        let thumbnailSize = try XCTUnwrap(SampleImage.decodedSize(of: thumbnail.data))
        XCTAssertEqual(thumbnailSize.width, min(settings.width, SigningProfile.thumbnailLongEdge))

        try await verifyPlayback(of: signed, matches: source, settings: settings)

        let ingredients = store.active["ingredients"] as? [[String: Any]] ?? []
        XCTAssertEqual(ingredients.count, 1, store.text)
        let ingredient = try XCTUnwrap(ingredients.first)
        XCTAssertEqual(ingredient["relationship"] as? String, "parentOf")
        guard parentIngredientArchive != nil else {
            XCTAssertNil(ingredient["active_manifest"], "A parent of unknown provenance has no manifest")
            return
        }
        XCTAssertEqual(ingredient["format"] as? String, format)
        let parentLabel = try XCTUnwrap(ingredient["active_manifest"] as? String, store.text)
        let parentManifest = try XCTUnwrap(store.manifests[parentLabel], store.text)
        let generator = (parentManifest["claim_generator_info"] as? [[String: Any]])?.first
        XCTAssertEqual(generator?["name"] as? String, SigningProfile.claimGeneratorName)
        XCTAssertNotNil((parentManifest["signature_info"] as? [String: Any])?["time"], store.text)
        let parentResults = (ingredient["validation_results"] as? [String: Any])?["activeManifest"]
        let parentStatuses = try XCTUnwrap(parentResults as? [String: Any], store.text)
        verifySignatureAndTimestamp(
            success: codes(parentStatuses["success"]), failures: codes(parentStatuses["failure"]), json: store.text
        )
        XCTAssertTrue(codes(parentStatuses["success"]).contains("assertion.bmffHash.match"), store.text)
    }

    /// Checks that AVFoundation reads the signed video like the source: the same duration and
    /// tracks, every video frame decodes, and an HDR video keeps its transfer function.
    private func verifyPlayback(
        of signed: URL, matches source: URL, settings: SampleVideo.Settings,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let sourceAsset = AVURLAsset(url: source)
        let signedAsset = AVURLAsset(url: signed)
        let sourceDuration = try await sourceAsset.load(.duration)
        let signedDuration = try await signedAsset.load(.duration)
        XCTAssertEqual(signedDuration, sourceDuration, file: file, line: line)
        let sourceTracks = try await sourceAsset.load(.tracks)
        let signedTracks = try await signedAsset.load(.tracks)
        XCTAssertEqual(signedTracks.count, sourceTracks.count, file: file, line: line)
        XCTAssertEqual(signedTracks.count, settings.audio ? 2 : 1, file: file, line: line)

        let generator = AVAssetImageGenerator(asset: signedAsset)
        let (frame, _) = try await generator.image(at: CMTime(value: 1, timescale: 2))
        XCTAssertEqual(frame.width, settings.width, file: file, line: line)

        let videoTracks = try await signedAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let descriptions = try await videoTrack.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(
            description.mediaSubType,
            settings.codec == .hevc ? .hevc : .h264, file: file, line: line
        )
        let transferFunction = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String
        XCTAssertEqual(
            transferFunction,
            (settings.hdr ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                : kCMFormatDescriptionTransferFunction_ITU_R_709_2) as String,
            file: file, line: line
        )

        let reader = try AVAssetReader(asset: signedAsset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))", file: file, line: line)
        var decodedFrames = 0
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(buffer) != nil {
                decodedFrames += 1
            }
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))", file: file, line: line)
        XCTAssertEqual(decodedFrames, settings.frameCount, file: file, line: line)
    }

    // MARK: - Helpers

    /// Signs `source` on a dispatch queue, since signing blocks its thread until the asynchronous
    /// signer returns.
    @discardableResult
    private func sign(
        _ source: URL, format: String, thumbnail: SigningProfile.Thumbnail? = nil, to destination: URL,
        parentIngredientArchive: URL? = nil
    ) async throws -> SigningProfile.Thumbnail {
        let thumbnail = if let thumbnail {
            thumbnail
        } else {
            try await SigningProfile.makeThumbnail(ofVideoAt: source)
        }
        let certificateChain = try fixtureText("es256_certs.pem")
        let key = try P256.Signing.PrivateKey(pemRepresentation: fixtureText("es256_private.key"))
        try await onDispatchQueue {
            try SigningProfile.sign(
                videoAt: source, format: format, thumbnail: thumbnail, to: destination,
                parentIngredientArchive: parentIngredientArchive, certificateChainPEM: certificateChain
            ) { try key.signature(for: $0).derRepresentation }
        }
        return thumbnail
    }

    /// Reads the manifest store of `url` on a dispatch queue, like signing.
    private func read(_ url: URL, format: String) async throws -> VideoManifestStore {
        let timestampRoots = try fixtureText("DigiCertTrustedRootG4.pem")
        let json = try await onDispatchQueue {
            try SigningProfile.reader(for: url, format: format, timestampRoots: timestampRoots).json()
        }
        return try VideoManifestStore(json: json)
    }

    /// Returns the result of `body` run on a global dispatch queue, like signing. Its autorelease pool
    /// drains only when `body` returns, so memory that a stream autoreleases per read adds up.
    private func onDispatchQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }

    /// Writes a video of at least `minimumSize` bytes to `url`: a clip with `settings`, repeated
    /// without re-encoding, which is much faster than encoding a long video.
    private func writeLongVideo(
        repeating settings: SampleVideo.Settings, minimumSize: Int, in directory: URL, to url: URL
    ) async throws {
        let clip = directory.appendingPathComponent("clip.mov")
        try SampleVideo.write(settings, to: clip)
        let clipSize = try fileSize(of: clip)
        try await repeatClip(clip, times: (minimumSize + clipSize - 1) / clipSize, to: url)
        try FileManager.default.removeItem(at: clip)
    }

    /// Writes `clip` repeated `times` times to `url`, without re-encoding.
    private func repeatClip(_ clip: URL, times: Int, to url: URL) async throws {
        let asset = AVURLAsset(url: clip)
        let range = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
        let composition = AVMutableComposition()
        for _ in 0..<times {
            try await composition.insertTimeRange(range, of: asset, at: composition.duration)
        }
        let session = try XCTUnwrap(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        )
        try await session.export(to: url, as: .mov)
    }

    private func fileSize(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    private struct Box {
        let type: String
        let payloadOffset: UInt64
        let end: UInt64
    }

    private func topLevelBoxes(of url: URL) throws -> [Box] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var boxes: [Box] = []
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            let header = [UInt8](try XCTUnwrap(handle.read(upToCount: 16)))
            var size = header[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var headerSize: UInt64 = 8
            if size == 1 {
                size = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerSize = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            boxes.append(Box(type: type, payloadOffset: offset + headerSize, end: offset + size))
            offset += size
        }
        return boxes
    }

    private struct Measurement {
        let seconds: Double
        let peakMegabytes: Double
    }

    /// Runs `body` and returns its wall time and how much the process's peak memory footprint rose
    /// above the footprint before it ran.
    private func measured(_ body: () async throws -> Void) async throws -> Measurement {
        let sampler = try FootprintSampler()
        let start = Date()
        try await body()
        let seconds = Date().timeIntervalSince(start)
        return Measurement(seconds: seconds, peakMegabytes: Double(try sampler.stop()) / 1e6)
    }
}

private func codes(_ statuses: Any?) -> [String] {
    (statuses as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
}

/// The manifest store JSON of a reader, decoded loosely.
private struct VideoManifestStore {
    let text: String
    let manifests: [String: [String: Any]]
    let active: [String: Any]
    let validationState: String?
    let successCodes: [String]
    let failureCodes: [String]
    let ingredientDeltaFailureCodes: [String]

    init(json: String) throws {
        text = json
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        manifests = try XCTUnwrap(root["manifests"] as? [String: [String: Any]], json)
        active = try XCTUnwrap(manifests[XCTUnwrap(root["active_manifest"] as? String, json)], json)
        validationState = root["validation_state"] as? String
        let results = root["validation_results"] as? [String: Any]
        let activeResults = results?["activeManifest"] as? [String: Any]
        successCodes = codes(activeResults?["success"])
        failureCodes = codes(activeResults?["failure"])
        ingredientDeltaFailureCodes = (results?["ingredientDeltas"] as? [[String: Any]] ?? [])
            .flatMap { codes(($0["validationDeltas"] as? [String: Any])?["failure"]) }
    }
}

/// Samples the process's physical memory footprint every 5 ms on a background thread.
private final class FootprintSampler: @unchecked Sendable {
    struct SamplingError: Error {
        let result: kern_return_t
    }

    private let lock = NSLock()
    private let baseline: UInt64
    private var peak: UInt64
    private var error: Error?
    private var running = true
    private let done = DispatchSemaphore(value: 0)

    init() throws {
        baseline = try Self.footprint()
        peak = baseline
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                do {
                    let current = try Self.footprint()
                    lock.withLock { peak = max(peak, current) }
                } catch {
                    lock.withLock { self.error = error }
                }
                usleep(5_000)
            }
            done.signal()
        }
    }

    /// Stops sampling and returns the peak footprint above the baseline, in bytes. Throws if a
    /// sample failed, so that a failing measurement can't pass as a flat one.
    func stop() throws -> UInt64 {
        lock.withLock { running = false }
        done.wait()
        let current = try Self.footprint()
        return try lock.withLock {
            if let error { throw error }
            return max(peak, current) - baseline
        }
    }

    static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, info.phys_footprint > 0 else {
            throw SamplingError(result: result)
        }
        return info.phys_footprint
    }
}
