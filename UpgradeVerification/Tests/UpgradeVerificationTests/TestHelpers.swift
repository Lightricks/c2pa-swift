// Copyright (c) 2026 Lightricks. All rights reserved.
// Created by Anass AlZurba.

import Foundation
import XCTest

extension XCTestCase {
    /// Returns a new directory that is removed when the test ends.
    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Returns the URL of `path` in the test bundle's `Fixtures` directory, for example
    /// `c2pa-rs/CACA.jpg`.
    func fixture(_ path: String) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        let subdirectory = (["Fixtures"] + components.dropLast()).joined(separator: "/")
        return try XCTUnwrap(
            Bundle.module.url(forResource: components.last, withExtension: nil, subdirectory: subdirectory),
            "Missing fixture \(path)"
        )
    }

    func fixtureText(_ path: String) throws -> String {
        try String(contentsOf: fixture(path), encoding: .utf8)
    }

    /// Checks that the claim signature and its timestamp validated, and if `timestampTrusted`, that
    /// the timestamp is trusted. The only allowed failure is the untrusted test signing certificate.
    func verifySignatureAndTimestamp(
        success: [String], failures: [String], timestampTrusted: Bool = false, json: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(success.contains("claimSignature.validated"), "Codes: \(success)", file: file, line: line)
        XCTAssertTrue(success.contains("timeStamp.validated"), "Codes: \(success)", file: file, line: line)
        if timestampTrusted {
            XCTAssertTrue(success.contains("timeStamp.trusted"), "Codes: \(success)", file: file, line: line)
        }
        XCTAssertEqual(failures, ["signingCredential.untrusted"], "Failures: \(failures)\n\(json)",
                       file: file, line: line)
    }

    /// Checks that `text`, the ISO 8601 time of a signature's timestamp, is at most a minute before
    /// `start` and a minute after now. RFC 3161 times are second-granular and the runner and TSA
    /// have separate clocks.
    func verifyTimestamp(
        _ text: String, isAfter start: Date, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        let timestamp = try XCTUnwrap(
            formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text),
            "Invalid timestamp \(text)", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(timestamp, start.addingTimeInterval(-60), file: file, line: line)
        XCTAssertLessThanOrEqual(timestamp, Date().addingTimeInterval(60), file: file, line: line)
    }
}
