// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation
import Photos
import UIKit

@testable import PhotoSync

struct MockPhoto: PhotoProtocol {
    let photoKitId: String!
    let cloudIdentifier: String?
    let created: Date?
    let preferredPath: String?
    let contentHash: String?
}

struct MockDropboxFile: DropboxFileProtocol {
    let pathLower: String
    let rev: String
    let contentHash: String
}

struct MockAsset: PHAssetProtocol {
    let localIdentifier: String
    var creationDate: Date?
    var modificationDate: Date?
    var timezone: TimeZone?
    var filename: String?

    func getImageData(version: PHImageRequestOptionsVersion) async throws -> AssetData {
        throw AssetError.fetch("mock", nil)
    }

    func thumbnail(size: CGSize) async -> UIImage? { nil }
}

func mockPhoto(_ id: String, _ path: String, created: TimeInterval? = nil, hash: String? = nil) -> MockPhoto {
    MockPhoto(
        photoKitId: id,
        cloudIdentifier: id,
        created: created.map { Date(timeIntervalSinceReferenceDate: $0) },
        preferredPath: path,
        contentHash: hash
    )
}

func mockPhotoMapping(_ id: String, path: String, hash: String? = nil) -> Photo.PhotoMapping {
    Photo.PhotoMapping(photoKitId: id, path: path, contentHash: hash)
}

func mockFile(_ path: String, hash: String = "hash", rev: String = "rev") -> MockDropboxFile {
    MockDropboxFile(pathLower: path, rev: rev, contentHash: hash)
}

func mockAsset(_ id: String) -> MockAsset {
    MockAsset(localIdentifier: id)
}
