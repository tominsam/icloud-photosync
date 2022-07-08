//
//  PHAsset+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 5/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Photos

enum AssetData {
    case data(Data, hash: String)
    case url(URL, hash: String)
    case tempUrl(URL, hash: String)
    case failure(Error)

    var hash: String? {
        switch self {
        case .data(_, let hash), .url(_, let hash), .tempUrl(_, let hash):
            return hash
        case .failure:
            return nil
        }
    }
}

enum AssetError: Error, LocalizedError {
    case fetch(String, Error?)
    case mediaType(PHAssetMediaType)

    var errorDescription: String? {
        switch self {
        case .fetch(let message, _):
            return message
        case .mediaType(let mediaType):
            return "Invalid media type \(mediaType)"
        }
    }

    var sourceError: Error? {
        switch self {
        case .fetch(_, let error):
            return error
        case .mediaType:
            return nil
        }
    }
}

extension PHAsset {
    static var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM"
        return dateFormatter
    }()

    // slightly slow
    func dropboxPath(fromFilename filename: String) -> String {
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

        return "/\(datePath)/\(filename)".lowercased()
    }

    // This is slow! (~100ms)
    var filename: String? {
        return PHAssetResource.assetResources(for: self)
            .first {
                [.photo, .video, .fullSizePhoto, .fullSizeVideo].contains($0.type)
            }?
            .originalFilename
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
                        let error = info?[PHImageErrorKey] as? Error
                        NSLog("Photo fetch failed: %@", info ?? [:])
                        continuation.resume(throwing: AssetError.fetch("Can't fetch photo", error))
                        return
                    }
                    continuation.resume(returning: .data(data, hash: data.dropboxContentHash()))
                }
            }

        case .video:
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current // save out edited versions (or original if no edits)
            options.isNetworkAccessAllowed = true // download if required
            return try await withCheckedThrowingContinuation { continuation in
                manager.requestAVAsset(forVideo: self, options: options) { avAsset, _, info in
                    if let composition = avAsset as? AVComposition {
                        NSLog("%@", "Exporting compositional video")
                        // Slo-mo video - https://buffer.com/resources/slow-motion-video-ios/
                        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                            continuation.resume(throwing: AssetError.fetch("Can't start export session", nil))
                            return
                        }
                        let filename = UUID().uuidString + ".mov"
                        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                        let tempFile = tempDir.appendingPathComponent(filename, isDirectory: false)
                        export.outputURL = tempFile
                        export.outputFileType = .mov
                        export.shouldOptimizeForNetworkUse = true
                        export.exportAsynchronously {
                            NSLog("%@", "Export complete: \(export.status) to \(tempFile)")
                            if export.status == .completed {
                                continuation.resume(returning: .tempUrl(tempFile, hash: tempFile.dropboxContentHash()))
                            } else {
                                continuation.resume(throwing: AssetError.fetch("Can't export video", nil))
                            }
                        }
                        // TODO do I need to delete these urls?

                    } else if let avUrlAsset = avAsset as? AVURLAsset {
                        NSLog("%@", "Video downloaded as \(avUrlAsset.url)")
                        continuation.resume(returning: .url(avUrlAsset.url, hash: avUrlAsset.url.dropboxContentHash()))
                        // TODO do I need to delete these urls?
                    } else {
                        let error = info?[PHImageErrorKey] as? Error
                        NSLog("Video fetch for %@ failed: %@", String(describing: avAsset), info ?? [:])
                        continuation.resume(throwing: AssetError.fetch("Can't fetch video", error))
                    }
                }
            }

        default:
            throw AssetError.mediaType(mediaType)
        }
    }

    static var allAssets: [PHAsset] {
        get async {
            return await withCheckedContinuation { continuation in
                let allPhotosOptions = PHFetchOptions()
                allPhotosOptions.includeHiddenAssets = false
                allPhotosOptions.wantsIncrementalChangeDetails = false
                allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

                // This blocks very briefly - 0.2 seconds on my physical
                // device for 70k photos - so I'm not super bothered right now.
                let start = Date()
                let assets = PHAsset.fetchAssets(with: allPhotosOptions)
                var allAssets = [PHAsset]()
                assets.enumerateObjects { asset, _, _ in
                    allAssets.append(asset)
                }
                continuation.resume(returning: allAssets)
                NSLog("%@", "PhotoKit call took \((-start.timeIntervalSinceNow).formatted()) seconds to read \(allAssets.count) photos")
            }
        }
    }
}
