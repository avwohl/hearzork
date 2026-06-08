import XCTest
import Foundation
@testable import HearZork

/// Resolves bundled story-file fixtures relative to this source file, so tests
/// no longer depend on an external games directory. Freely-distributable
/// fixtures (advent, czech, praxix, strictz, gntests) are committed under
/// Tests/Fixtures; copyrighted games (zork1, curses, …) are not, so tests that
/// need them skip gracefully when they are absent.
enum TestFixtures {
    static var dir: URL {
        URL(fileURLWithPath: #filePath)        // Tests/ZMachineTests/TestFixtures.swift
            .deletingLastPathComponent()        // Tests/ZMachineTests
            .deletingLastPathComponent()        // Tests
            .appendingPathComponent("Fixtures")
    }

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    /// Load a fixture's bytes, or skip the calling test if it isn't present.
    static func load(_ name: String) throws -> Data {
        let u = url(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path),
                          "Fixture '\(name)' not present at \(u.path) — skipping.")
        return try Data(contentsOf: u)
    }

    /// Run a story with scripted input to completion or a timeout; returns the
    /// captured lower-window output.
    static func run(_ name: String, inputs: [String] = [], seconds: Double = 5) async throws -> String {
        let data = try load(name)
        let memory = try Memory(storyData: data)
        _ = Header(memory)
        let io = TestIO()
        io.inputLines = inputs
        let proc = Processor(memory: memory, io: io)
        let task = Task { @Sendable in await proc.start() }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        proc.running = false
        task.cancel()
        return io.outputBuffer
    }
}
