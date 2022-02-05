//
//  PHAsset+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 5/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Photos

enum AssetData {
    case data(Data)
    case url(URL)

    func dropboxContentHash() -> String? {
        switch self {
        case let .data(data):
            return data.dropboxContentHash()
        case let .url(url):
            return url.dropboxContentHash()
        }
    }
}

enum AssetError: Error, LocalizedError {
    case fetch(String)
    case mediaType(PHAssetMediaType)

    var errorDescription: String? {
        switch self {
        case let .fetch(message):
            return message
        case let .mediaType(mediaType):
            return "Invalid media type \(mediaType)"
        }
    }
}

extension PHAsset {
    static var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM"
        return dateFormatter
    }()

    /// The path in dropbox where we want this asset to be. This method is slow (multiple
    /// milliseconds) so exercise caution - don't call it on first sync.
    var dropboxPath: String {
        let datePath: String
        if let creationDate = creationDate {
            // Can we get a timezone from the photo location? Assume the photo was taken in that TZ
            if let location = location, let timezone = TimezoneMapper.latLngToTimezone(location.coordinate) {
                Self.dateFormatter.timeZone = timezone
            } else {
                // Otherwise we'll just have to assume UTC for safety
                Self.dateFormatter.timeZone = TimeZone(identifier: "UTC")
            }
            datePath = Self.dateFormatter.string(from: creationDate)
        } else {
            // no creation date?
            datePath = "No date"
        }

        // This includes the file extension.
        let filename = (PHAssetResource.assetResources(for: self)
            .first(where: { [.photo, .video, .fullSizePhoto, .fullSizeVideo].contains($0.type) })?
            .originalFilename)!
        return "/\(datePath)/\(filename)".lowercased()
    }

    func getImageData() async throws -> AssetData {
        let manager = PHImageManager.default()

        switch mediaType {
        case .image:
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current // save out edited versions (or original if no edits)
            options.isNetworkAccessAllowed = true // download if required
            return try await withCheckedThrowingContinuation { continuation in
                manager.requestImageDataAndOrientation(for: self, options: options) { data, _, _, info in
                    guard let data = data else {
                        continuation.resume(throwing: AssetError.fetch("Can't fetch photo: \(info ?? [:])"))
                        return
                    }
                    continuation.resume(returning: .data(data))
                }
            }

        case .video:
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current // save out edited versions (or original if no edits)
            options.isNetworkAccessAllowed = true // download if required
            return try await withCheckedThrowingContinuation { continuation in
                manager.requestAVAsset(forVideo: self, options: options) { avAsset, _, info in
                    guard let avUrlAsset = avAsset as? AVURLAsset else {
                        continuation.resume(throwing: AssetError.fetch("Can't fetch video: \(info ?? [:])"))
                        return
                    }
                    continuation.resume(returning: .url(avUrlAsset.url))
                }
            }

        default:
            throw AssetError.mediaType(mediaType)
        }
    }
}
