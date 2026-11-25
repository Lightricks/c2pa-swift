// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Writes test videos at runtime with `AVAssetWriter`, as apps typically write video exports, so
/// that the test bundle needs no video fixtures.
public enum SampleVideo {
    public struct Settings: Sendable {
        public var fileType: AVFileType
        public var codec: AVVideoCodecType
        /// Whether the video is 10-bit HEVC Main10 with HLG BT.2020 color, like an HDR iPhone video.
        /// Otherwise it's 8-bit BT.709.
        public var hdr: Bool
        public var width: Int
        public var height: Int
        public var frameRate: Int
        public var frameCount: Int
        public var bitRate: Int
        /// Whether to add a stereo AAC track.
        public var audio: Bool

        public init(
            fileType: AVFileType, codec: AVVideoCodecType, hdr: Bool = false, width: Int = 640,
            height: Int = 360, frameRate: Int = 30, frameCount: Int = 30, bitRate: Int = 2_000_000,
            audio: Bool = true
        ) {
            self.fileType = fileType
            self.codec = codec
            self.hdr = hdr
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.frameCount = frameCount
            self.bitRate = bitRate
            self.audio = audio
        }
    }

    public enum Error: Swift.Error {
        case cannotAddInput(AVMediaType)
        case pixelBuffer(CVReturn)
        case sampleBuffer(OSStatus)
        case writingFailed(Swift.Error?)
    }

    private static let audioSampleRate = 44_100
    private static let audioFramesPerBuffer = 1_024
    /// Number of distinct frames, which repeat in turn. A quarter of each frame is noise, so that the
    /// encoder spends about the bit rate and the file size scales with the duration.
    private static let distinctFrameCount = 8

    /// Writes a video with `settings` to `url`. Blocks until the file is finished.
    public static func write(_ settings: Settings, to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: settings.fileType)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(settings))
        video.expectsMediaDataInRealTime = false
        guard writer.canAdd(video) else {
            throw Error.cannotAddInput(.video)
        }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video)

        let audio = settings.audio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: audioSampleRate,
            AVEncoderBitRateKey: 128_000
        ]) : nil
        if let audio {
            audio.expectsMediaDataInRealTime = false
            guard writer.canAdd(audio) else {
                throw Error.cannotAddInput(.audio)
            }
            writer.add(audio)
        }

        let frames = try (0..<min(distinctFrameCount, settings.frameCount)).map { _ in
            try makeFrame(settings)
        }
        let audioFormat = try makeAudioFormat()
        let audioBufferCount = settings.audio
            ? (settings.frameCount * audioSampleRate / settings.frameRate + audioFramesPerBuffer - 1)
                / audioFramesPerBuffer
            : 0

        guard writer.startWriting() else {
            throw Error.writingFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)
        var frameIndex = 0
        var audioIndex = 0
        // Appends to whichever input is ready, so that neither waits on the other to interleave.
        while frameIndex < settings.frameCount || audioIndex < audioBufferCount {
            var appended = false
            if frameIndex < settings.frameCount, video.isReadyForMoreMediaData {
                let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.frameRate))
                guard adaptor.append(frames[frameIndex % frames.count], withPresentationTime: time) else {
                    throw Error.writingFailed(writer.error)
                }
                frameIndex += 1
                appended = true
                if frameIndex == settings.frameCount {
                    video.markAsFinished()
                }
            }
            if let audio, audioIndex < audioBufferCount, audio.isReadyForMoreMediaData {
                guard audio.append(try makeAudioBuffer(index: audioIndex, format: audioFormat)) else {
                    throw Error.writingFailed(writer.error)
                }
                audioIndex += 1
                appended = true
                if audioIndex == audioBufferCount {
                    audio.markAsFinished()
                }
            }
            if !appended {
                guard writer.status == .writing else {
                    throw Error.writingFailed(writer.error)
                }
                usleep(1_000)
            }
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw Error.writingFailed(writer.error)
        }
    }

    private static func videoSettings(_ settings: Settings) -> [String: Any] {
        let color: [String: Any] = settings.hdr ? [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ] : [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitRate,
            AVVideoMaxKeyFrameIntervalKey: settings.frameRate
        ]
        if settings.hdr {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        return [
            AVVideoCodecKey: settings.codec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: color,
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    /// Returns a gray bi-planar 4:2:0 frame whose top quarter is luma noise, 10-bit for HDR and
    /// 8-bit otherwise.
    private static func makeFrame(_ settings: Settings) throws -> CVPixelBuffer {
        let format = settings.hdr
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(nil, settings.width, settings.height, format, attributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw Error.pixelBuffer(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            memset(base, 0x80, bytesPerRow * CVPixelBufferGetHeightOfPlane(buffer, plane))
            if plane == 0 {
                arc4random_buf(base, bytesPerRow * CVPixelBufferGetHeightOfPlane(buffer, plane) / 4)
            }
        }
        return buffer
    }

    private static func makeAudioFormat() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(audioSampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw Error.sampleBuffer(status)
        }
        return format
    }

    /// Returns the `index`th buffer of a stereo 440 Hz tone.
    private static func makeAudioBuffer(index: Int, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let firstFrame = index * audioFramesPerBuffer
        var samples = [Int16](repeating: 0, count: audioFramesPerBuffer * 2)
        for frame in 0..<audioFramesPerBuffer {
            let phase = 2 * Double.pi * 440 * Double(firstFrame + frame) / Double(audioSampleRate)
            let value = Int16(sin(phase) * 8_000)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == noErr, let block else {
            throw Error.sampleBuffer(status)
        }
        status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard status == noErr else {
            throw Error.sampleBuffer(status)
        }
        var buffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: audioFramesPerBuffer,
            presentationTimeStamp: CMTime(value: CMTimeValue(firstFrame), timescale: CMTimeScale(audioSampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else {
            throw Error.sampleBuffer(status)
        }
        return buffer
    }
}
