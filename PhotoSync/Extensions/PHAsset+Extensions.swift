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

    var timezone: TimeZone? {
        guard let location else { return nil }
        return TimezoneMapper.latLngToTimezone(location.coordinate)
    }

    // slightly slow
    func dropboxPath(fromFilename filename: String) -> String {
        let datePath: String
        if let creationDate = creationDate {
            // Can we get a timezone from the photo location? Assume the photo was taken in that TZ
            Self.dateFormatter.timeZone = self.timezone ?? TimeZone(identifier: "UTC")!
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
            options.isSynchronous = true // stay on thread for async simplicity
            return try await withCheckedThrowingContinuation { continuation in
                manager.requestImageDataAndOrientation(for: self, options: options) { data, _, _, info in
                    guard let data = data else {
                        let error = info?[PHImageErrorKey] as? Error
                        NSLog("Photo fetch failed: %@", error.map { String(describing: $0) } ?? "")
                        continuation.resume(throwing: AssetError.fetch("Can't fetch photo", error))
                        return
                    }
                    let dataWithExif = Self.setDate(onImage: data, date: self.creationDate, timezone: self.timezone)
                    continuation.resume(returning: .data(dataWithExif, hash: dataWithExif.dropboxContentHash()))
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
                        // TODO this generates inconsistent content hashes per-platform.
                        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                            continuation.resume(throwing: AssetError.fetch("Can't start export session", nil))
                            return
                        }
                        let filename = UUID().uuidString + ".mov"
                        let tempFile = SyncManager.tempDir.appendingPathComponent(filename, isDirectory: false)
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

                    } else if let avUrlAsset = avAsset as? AVURLAsset {
                        NSLog("%@", "Video downloaded as \(avUrlAsset.url)")
                        continuation.resume(returning: .url(avUrlAsset.url, hash: avUrlAsset.url.dropboxContentHash()))

                    } else {
                        let error = info?[PHImageErrorKey] as? Error
                        NSLog("Photo fetch failed: %@", error.map { String(describing: $0) } ?? "")
                        continuation.resume(throwing: AssetError.fetch("Can't fetch video", error))
                    }
                }
            }

        default:
            throw AssetError.mediaType(mediaType)
        }
    }

    static func setDate(onImage data: Data, date: Date?, timezone: TimeZone?) -> Data {
        guard let date else { return data }

        // If an image date has been edited in iPhoto, we're going to write the image
        // in a folder with that edited date, and with an mtime of that edited date, but
        // it _also_ needs the edited date in the EXIF so that things that import it
        // (and the dropbox photos view) understand that it's at the time we claim it's
        // at. The "edited image" export from photokit has the original EXIF, without
        // the new date, so we need to fix that.

        // Read image
        let imageRef: CGImageSource = CGImageSourceCreateWithData((data as CFData), nil)!

        // Read exif, extract existing timezone offset from image
        let oldProperties = CGImageSourceCopyPropertiesAtIndex(imageRef, 0, nil) as? [String: AnyObject]
        let oldExif = oldProperties?[kCGImagePropertyExifDictionary as String] as? [String: AnyObject]
        let oldOffset = oldExif?["OffsetTimeOriginal"] as? String
        let oldTimezone = oldOffset != nil ? TimeZone(fromOffset: oldOffset!) : nil

        let dateFormatter = DateFormatter()
        // yes, colons. EXIF gonna EXIF.
        dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // Guess timezone from GPS first, fall back to respecting any existing timezone on the image
        dateFormatter.timeZone = timezone ?? oldTimezone
        let dateString = dateFormatter.string(from: date)

        // There's an unofficial place to put offset in EXIF, let's do that
        dateFormatter.dateFormat = "xxxxx" // -07:00
        let offsetString = dateFormatter.string(from: date)

        // Build new exif properties for image
        let exifDictionary: [NSString: AnyObject] = [
            "DateTimeOriginal": dateString as CFString,
            "SubSecDateTimeOriginal": kCFNull,
            "OffsetTimeOriginal": offsetString as CFString,
        ]
        let properties: [NSString: AnyObject] = [
            kCGImagePropertyExifDictionary: exifDictionary as CFDictionary
        ]

        // Write out a new data object with updated exif
        let uti: CFString = CGImageSourceGetType(imageRef)!
        let dataWithEXIF: NSMutableData = NSMutableData(data: data)
        guard let destination: CGImageDestination = CGImageDestinationCreateWithData((dataWithEXIF as CFMutableData), uti, 1, nil) else {
               NSLog("!! Failed to write exif to data")
            return data
        }
        CGImageDestinationAddImageFromSource(destination, imageRef, 0, (properties as CFDictionary))
        CGImageDestinationFinalize(destination)
        return dataWithEXIF as Data
    }

    static var allAssets: [PHAsset] {
        get async {
            return await withCheckedContinuation { continuation in
                let start = Date()

                let allPhotosOptions = PHFetchOptions()
                allPhotosOptions.wantsIncrementalChangeDetails = false
                let assets = PHAsset.fetchAssets(with: allPhotosOptions)
                var allAssets = [PHAsset]()
                assets.enumerateObjects { asset, _, _ in
                    allAssets.append(asset)
                }

                // Can't sort by identifier in the predicate
                allAssets.sort { (lhs, rhs) in
                    if let ld = lhs.creationDate, let rd = rhs.creationDate, ld != rd {
                        return ld < rd
                    }
                    return lhs.localIdentifier < rhs.localIdentifier
                }

                NSLog("%@", "PhotoKit call took \((-start.timeIntervalSinceNow).formatted()) seconds to read \(allAssets.count) photos")
                continuation.resume(returning: allAssets)
            }
        }
    }
}
