// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import C2PA
// Foundation also has a `Stream`.
import class C2PA.Stream
import Darwin
import Foundation

/// C2PA streams of files that read and write with POSIX calls, so that signing or reading a large
/// video uses a small, fixed amount of memory.
///
/// Use these instead of `Stream(readFrom:)` and `Stream(writeTo:)` for videos. Those read with
/// `FileHandle.read(upToCount:)`, which returns autoreleased `Data`. C2PA reads a file in many small
/// chunks from a single call, so nothing drains the autorelease pool in between: on a dispatch
/// queue, memory grows by about the size of the file until signing ends. These streams copy
/// straight into C2PA's buffer and allocate nothing per read.
public enum FileStream {
    public enum Error: Swift.Error {
        case cannotOpen(URL, errno: Int32)
    }

    /// Returns a read-only stream of the existing file at `url`.
    public static func reading(_ url: URL) throws -> Stream {
        try stream(of: OpenFile(url, flags: O_RDONLY), writable: false)
    }

    /// Returns a read-write stream of the file at `url`, which is created or emptied. Signing reads
    /// its destination back, so the stream must be readable too.
    public static func writing(_ url: URL) throws -> Stream {
        try stream(of: OpenFile(url, flags: O_RDWR | O_CREAT | O_TRUNC), writable: true)
    }

    private static func stream(of file: OpenFile, writable: Bool) throws -> Stream {
        // The closures own `file`, so it is closed when C2PA releases the stream.
        try Stream(
            read: { buffer, count in
                retryingOnInterrupt { Darwin.read(file.value, buffer, count) }
            },
            seek: { offset, mode in
                let whence: Int32
                // C2paSeekMode's Start, Current and End, which are in the C module C2PAC.
                switch mode.rawValue {
                case 0: whence = SEEK_SET
                case 1: whence = SEEK_CUR
                case 2: whence = SEEK_END
                default: return -1
                }
                return Int(lseek(file.value, off_t(offset), whence))
            },
            write: writable ? { buffer, count in
                var written = 0
                while written < count {
                    let result = retryingOnInterrupt {
                        Darwin.write(file.value, buffer + written, count - written)
                    }
                    guard result > 0 else {
                        return -1
                    }
                    written += result
                }
                return count
            } : nil,
            flush: writable ? { fsync(file.value) == 0 ? 0 : -1 } : nil
        )
    }

    private static func retryingOnInterrupt(_ call: () -> Int) -> Int {
        while true {
            let result = call()
            if result >= 0 || errno != EINTR {
                return result
            }
        }
    }
}

/// An open file descriptor, closed on deinit.
private final class OpenFile: @unchecked Sendable {
    let value: Int32

    init(_ url: URL, flags: Int32) throws {
        value = open(url.path, flags | O_CLOEXEC, 0o644)
        guard value >= 0 else {
            throw FileStream.Error.cannotOpen(url, errno: errno)
        }
    }

    deinit {
        close(value)
    }
}
