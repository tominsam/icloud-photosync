// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation
import Testing
@testable import PhotoSync

// MARK: - Tests

struct IterateTests {

    @Test func newPhotoWithNoRemoteFile() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [mockPhotoMapping("a", path: "/2024/01/a.jpg")],
            files: [],
            assets: [mockAsset("a")]
        )
        #expect(uploads.count == 1)
        #expect(uploads[0].state == .new)
        #expect(uploads[0].filename == "/2024/01/a.jpg")
        #expect(deletions.isEmpty)
    }

    @Test func matchingHashSkipsUpload() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [mockPhotoMapping("a", path: "/2024/01/a.jpg", hash: "abc")],
            files: [mockFile("/2024/01/a.jpg", hash: "abc")],
            assets: [mockAsset("a")]
        )
        #expect(uploads.isEmpty)
        #expect(deletions.isEmpty)
    }

    @Test func differentHashIsReplacement() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [mockPhotoMapping("a", path: "/2024/01/a.jpg", hash: "new-hash")],
            files: [mockFile("/2024/01/a.jpg", hash: "old-hash")],
            assets: [mockAsset("a")]
        )
        #expect(uploads.count == 1)
        #expect(uploads[0].state == .replacement)
        #expect(deletions.isEmpty)
    }

    @Test func noLocalHashIsUnknown() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [mockPhotoMapping("a", path: "/2024/01/a.jpg", hash: nil)],
            files: [mockFile("/2024/01/a.jpg", hash: "some-hash")],
            assets: [mockAsset("a")]
        )
        #expect(uploads.count == 1)
        #expect(uploads[0].state == .unknown)
        #expect(deletions.isEmpty)
    }

    @Test func remoteFileWithNoLocalPhotoIsDeleted() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [],
            files: [mockFile("/2024/01/orphan.jpg", rev: "rev1")],
            assets: []
        )
        #expect(uploads.isEmpty)
        #expect(deletions.count == 1)
        #expect(deletions[0].pathLower == "/2024/01/orphan.jpg")
        #expect(deletions[0].rev == "rev1")
    }

    @Test func photoWithNoMatchingAssetIsSkipped() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [mockPhotoMapping("missing-asset", path: "/2024/01/a.jpg")],
            files: [],
            assets: []
        )
        #expect(uploads.isEmpty)
        #expect(deletions.isEmpty)
    }

    @Test func pathMatchingIsCaseInsensitive() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [mockPhotoMapping("a", path: "/2024/01/Photo.jpg", hash: "abc")],
            files: [mockFile("/2024/01/photo.jpg", hash: "abc")],
            assets: [mockAsset("a")]
        )
        #expect(uploads.isEmpty)
        #expect(deletions.isEmpty)
    }

    @Test func deletionsAreSortedMostRecentFirst() throws {
        let (_, deletions) = try UploadManager.iterate(
            photos: [],
            files: [
                mockFile("/2024/01/a.jpg"),
                mockFile("/2024/03/b.jpg"),
                mockFile("/2024/02/c.jpg"),
            ],
            assets: []
        )
        #expect(deletions.map(\.pathLower) == ["/2024/03/b.jpg", "/2024/02/c.jpg", "/2024/01/a.jpg"])
    }

    @Test func mixedScenario() throws {
        let (uploads, deletions) = try UploadManager.iterate(
            photos: [
                mockPhotoMapping("new", path: "/2024/01/new.jpg"),
                mockPhotoMapping("unchanged", path: "/2024/01/unchanged.jpg", hash: "same"),
                mockPhotoMapping("changed", path: "/2024/01/changed.jpg", hash: "new"),
                mockPhotoMapping("unknown", path: "/2024/01/unknown.jpg", hash: nil),
            ],
            files: [
                mockFile("/2024/01/unchanged.jpg", hash: "same"),
                mockFile("/2024/01/changed.jpg", hash: "old"),
                mockFile("/2024/01/unknown.jpg", hash: "remote"),
                mockFile("/2024/01/orphan.jpg"),
            ],
            assets: [
                mockAsset("new"),
                mockAsset("unchanged"),
                mockAsset("changed"),
                mockAsset("unknown")
            ]
        )
        let uploadStates = Dictionary(uniqueKeysWithValues: uploads.map { ($0.filename, $0.state) })
        #expect(uploadStates["/2024/01/new.jpg"] == .new)
        #expect(uploadStates["/2024/01/unchanged.jpg"] == nil)
        #expect(uploadStates["/2024/01/changed.jpg"] == .replacement)
        #expect(uploadStates["/2024/01/unknown.jpg"] == .unknown)
        #expect(deletions.count == 1)
        #expect(deletions[0].pathLower == "/2024/01/orphan.jpg")
    }
}
