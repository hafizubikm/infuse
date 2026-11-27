import Foundation
import XCTest

/// Locates the synthetic clips in <repo>/TestMedia (see scripts/make-fixtures.sh).
enum TestMedia {
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["REEL_TEST_MEDIA"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ReelTests/
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("TestMedia", isDirectory: true)
    }()

    static func url(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing test clip \(name) in \(directory.path)", file: file, line: line)
        }
        return url
    }
}
