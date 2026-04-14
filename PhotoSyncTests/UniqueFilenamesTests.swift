// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation
import Testing
@testable import PhotoSync

struct UniqueFilenamesTests {

    private func entry(_ id: String, _ path: String, created: TimeInterval? = nil) -> Photo.PhotoEntry {
        Photo.PhotoEntry(photoKitId: id, preferredPath: path, contentHash: nil,
                         created: created.map { Date(timeIntervalSinceReferenceDate: $0) })
    }

    private func run(_ entries: [Photo.PhotoEntry]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Photo.uniqueFilenames(from: entries).map { ($0.photoKitId, $0.path) })
    }

    @Test func noCollisionsUnchanged() {
        let result = run([
            entry("a", "2024/01/a.jpg"),
            entry("b", "2024/01/b.jpg"),
        ])
        #expect(result["a"] == "2024/01/a.jpg")
        #expect(result["b"] == "2024/01/b.jpg")
    }

    @Test func collisionGetsSuffix() {
        let result = run([
            entry("a", "2024/01/photo.jpg", created: 0),
            entry("b", "2024/01/photo.jpg", created: 1),
        ])
        #expect(result["a"] == "2024/01/photo.jpg")
        #expect(result["b"] == "2024/01/photo (1).jpg")
    }

    @Test func threeWayCollisionGetsSuffixes() {
        let entries = ["a","b","c"].enumerated().map { entry($0.element, "2024/01/photo.jpg", created: Double($0.offset)) }
        let result = run(entries)
        #expect(result["a"] == "2024/01/photo.jpg")
        #expect(result["b"] == "2024/01/photo (1).jpg")
        #expect(result["c"] == "2024/01/photo (2).jpg")
    }

    @Test func earliestPhotoWinsPlainName() {
        // Pass b first to confirm sort order drives assignment, not input order
        let result = run([
            entry("b", "2024/01/photo.jpg", created: 1),
            entry("a", "2024/01/photo.jpg", created: 0),
        ])
        #expect(result["a"] == "2024/01/photo.jpg")
        #expect(result["b"] == "2024/01/photo (1).jpg")
    }

    @Test func collisionIsCaseInsensitive() {
        let result = run([
            entry("a", "2024/01/Photo.jpg", created: 0),
            entry("b", "2024/01/photo.jpg", created: 1),
        ])
        #expect(Set(result.values).count == 2)
    }

    @Test func contentHashPreserved() {
        let mappings = Photo.uniqueFilenames(from: [
            Photo.PhotoEntry(photoKitId: "a", preferredPath: "2024/01/a.jpg", contentHash: "abc123", created: nil),
        ])
        #expect(mappings[0].contentHash == "abc123")
    }

    @Test func tieBreakByPhotoKitId() {
        // Same date → sort by photoKitId; "a" comes first
        let result = run([
            entry("b", "2024/01/photo.jpg", created: 0),
            entry("a", "2024/01/photo.jpg", created: 0),
        ])
        #expect(result["a"] == "2024/01/photo.jpg")
        #expect(result["b"] == "2024/01/photo (1).jpg")
    }
}
