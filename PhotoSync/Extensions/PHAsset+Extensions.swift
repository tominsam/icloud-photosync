// Copyright 2020 Thomas Insam. All rights reserved.

import Photos
import UIKit

/// Various possible representations of a fetched PHAsset.
enum AssetData {
    /// Images generally arrive as NSData (raw jpeg, heic, etc)
    case data(Data, hash: String)
    /// Videos are too large for Data, so we get URLs to something on disk
    case url(URL, hash: String)
    /// Future/testing work for a local file that we've edited (to try to update exif)
    case tempUrl(URL, hash: String)
    /// Represents a failed fetch
    case failure(Error)

    /// If fetched, this will be the dropbox content hash of the file, however it's stored.
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

private let dateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy/MM"
    return dateFormatter
}()

// Protocol allows mocking for tests
protocol PHAssetProtocol {
    var localIdentifier: String { get }
    var creationDate: Date? { get }
    var modificationDate: Date? { get }
    var timezone: TimeZone? { get }
    var filename: String? { get }

    func getImageData(version: PHImageRequestOptionsVersion) async throws -> AssetData
    func thumbnail(size: CGSize) async -> UIImage?
}

extension PHAsset: PHAssetProtocol {
    /// Attempts to derive the timezone for an image from the lat/lng of the image. PHAsset
    /// doesn't have a native timezone property for some reason (but it's in iPhoto! Why is
    /// it not visible on the API!?) but we need localtime for the image because the day folder
    /// for that image should be the localtime day the image was captured, not the UTC day.
    var timezone: TimeZone? {
        guard let location else { return nil }
        return TimezoneMapper.latLngToTimezone(location.coordinate)
    }
    
    // This is slow! (~100ms)
    var filename: String? {
        return PHAssetResource.assetResources(for: self)
            .first {
                [.photo, .video, .fullSizePhoto, .fullSizeVideo].contains($0.type)
            }?
            .originalFilename
    }
    
    func getImageData(version: PHImageRequestOptionsVersion) async throws -> AssetData {
        let manager = PHImageManager.default()
        
        switch mediaType {
        case .image:
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = version
            options.isNetworkAccessAllowed = true // download if required
            options.isSynchronous = true // stay on thread for async simplicity
            
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                manager.requestImageDataAndOrientation(for: self, options: options) { data, _, _, info in
                    guard let data = data else {
                        let error = info?[PHImageErrorKey] as? Error
                        NSLog("Photo fetch failed: %@", error.map { String(describing: $0) } ?? "")
                        continuation.resume(throwing: AssetError.fetch("Can't fetch photo", error))
                        return
                    }
                    continuation.resume(returning: data)
                }
            }
            
            // If you edit the capture date of a photo in Photos, that doesn't change the Original
            // bytes downloaded from the server. I kinda want to update the file on disk to have the
            // right exif, because that means the dropbox photo browser will show the image in the
            // right place (we'll always put it in the right folder on disk, though). But we can't
            // do that, because exif editing is non-deterministic, so the content hash isn't predictable.
            
            //let dataWithExif = await Self.setDate(onImage: data, date: self.creationDate, timezone: self.timezone)
            //return .data(dataWithExif, hash: dataWithExif.dropboxContentHash())
            
            return .data(data, hash: data.dropboxContentHash())
            
        case .video:
            let avAsset = try await manager.getAVAsset(for: self)
            if let avUrlAsset = avAsset as? AVURLAsset {
                return .url(avUrlAsset.url, hash: avUrlAsset.url.dropboxContentHash())
            }
            throw AssetError.fetch("Unknown asset type \(type(of: avAsset))", nil)
        default:
            throw AssetError.mediaType(mediaType)
        }
    }

    func thumbnail(size: CGSize) async -> UIImage? {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: self, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

extension PHAsset {
    /// Fetches every PHAsset in the DB in one huge fetch. I've found that this isn't worth
    /// paginating or optimmizing - my personal photo DB is 160,000 photos and this fetches
    /// in 4-5 seconds and doesn't use that much ram, that's a completely reasonable amount
    /// of time compared to the rest of the things that are happening around here.
    static var allAssets: [PHAssetProtocol] {
        get async {
            return await withCheckedContinuation { continuation in
                let start = Date()

                let allPhotosOptions = PHFetchOptions()
                allPhotosOptions.wantsIncrementalChangeDetails = false
                let assets = PHAsset.fetchAssets(with: allPhotosOptions)
                var allAssets = [PHAsset]()
                assets.enumerateObjects { asset, _, _ in
                    // the returned object isn't an array and can't
                    // conveniently be cast to one
                    allAssets.append(asset)
                }

                // We can't sort by identifier in the predicate, so sort in ram
                allAssets.sort { (lhs, rhs) in
                    if let ld = lhs.creationDate, let rd = rhs.creationDate, ld != rd {
                        return ld < rd
                    }
                    // keep determinstic (localidentifier isn't properly deterministic, I guess
                    // running this on another device might flip the order here, and that'll have
                    // implications for filenames)
                    return lhs.localIdentifier < rhs.localIdentifier
                }

                NSLog("%@", "PhotoKit call took \((-start.timeIntervalSinceNow).formatted()) seconds to read \(allAssets.count) photos")
                continuation.resume(returning: allAssets)
            }
        }
    }}

extension PHAssetProtocol {
    /// Get the "preferred" dropbox filename for this asset. Currently this is hard-coded
    /// to be "yyyy/mm/iphoto-filename.jpg". This is slow (100ms+) because we need to fetch
    /// another representation from the photokit database to do it, so they're cached elsewhere.
    /// This method doesn't worry about avoiding collisions (that's elsewhere)
    func dropboxPath(fromFilename filename: String) -> String {
        let datePath: String
        if let creationDate = creationDate {
            // Can we get a timezone from the photo location? Assume the photo was taken in that TZ
            dateFormatter.timeZone = self.timezone ?? TimeZone(identifier: "UTC")!
            datePath = dateFormatter.string(from: creationDate)
        } else {
            // no creation date?
            datePath = "No date"
        }

        return "/\(datePath)/\(filename)".lowercased()
    }

//    static func setDate(onImage data: Data, date: Date?, timezone: TimeZone?) async -> Data {
//        guard let date else { return data }
//
//        // If an image date has been edited in iPhoto, we're going to write the image
//        // in a folder with that edited date, and with an mtime of that edited date, but
//        // it _also_ needs the edited date in the EXIF so that things that import it
//        // (and the dropbox photos view) understand that it's at the time we claim it's
//        // at. The "edited image" export from photokit has the original EXIF, without
//        // the new date, so we need to fix that.
//
//        // Read image
//        let imageRef: CGImageSource = CGImageSourceCreateWithData((data as CFData), nil)!
//
//        // Read exif, extract existing timezone offset from image
//        let oldProperties = CGImageSourceCopyPropertiesAtIndex(imageRef, 0, nil) as? [String: AnyObject]
//        let oldExif = oldProperties?[kCGImagePropertyExifDictionary as String] as? [String: AnyObject]
//        let oldOffset = oldExif?["OffsetTimeOriginal"] as? String
//        let oldTimezone = oldOffset != nil ? TimeZone(fromOffset: oldOffset!) : nil
//
//        let dateFormatter = DateFormatter()
//        // yes, colons. EXIF gonna EXIF.
//        dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
//        // Guess timezone from GPS first, fall back to respecting any existing timezone on the image
//        dateFormatter.timeZone = timezone ?? oldTimezone
//        let dateString = dateFormatter.string(from: date)
//
//        // There's an unofficial place to put offset in EXIF, let's do that
//        dateFormatter.dateFormat = "xxxxx" // -07:00
//        let offsetString = dateFormatter.string(from: date)
//
//        // Build new exif properties for image
//        let exifDictionary: [NSString: AnyObject] = [
//            "DateTimeOriginal": dateString as CFString,
//            "SubSecDateTimeOriginal": kCFNull,
//            "OffsetTimeOriginal": offsetString as CFString,
//        ]
//        let properties: [NSString: AnyObject] = [
//            kCGImagePropertyExifDictionary: exifDictionary as CFDictionary
//        ]
//
//        // Write out a new data object with updated exif
//        let uti: CFString = CGImageSourceGetType(imageRef)!
//        let dataWithEXIF: NSMutableData = NSMutableData(data: data)
//        if ["org.webmproject.webp"].contains(uti as NSString) {
//            return data
//        }
//
//        guard let destination: CGImageDestination = CGImageDestinationCreateWithData((dataWithEXIF as CFMutableData), uti, 1, nil) else {
//            NSLog("!! Failed to write exif to data")
//            return data
//        }
//        CGImageDestinationAddImageFromSource(destination, imageRef, 0, (properties as CFDictionary))
//        CGImageDestinationFinalize(destination)
//        return dataWithEXIF as Data
//    }
//
//    static func dateMetadata(for date: Date?) -> [AVMetadataItem]? {
//        guard let date else { return nil }
//        let dates = [
//            (AVMetadataKeySpace.common, AVMetadataKey.commonKeyCreationDate),
//            (.common, .commonKeyLastModifiedDate),
//            (.quickTimeMetadata, .quickTimeMetadataKeyCreationDate),
//            (.quickTimeUserData, .quickTimeUserDataKeyCreationDate),
//            (.isoUserData, .isoUserDataKeyDate),
//            (.id3, .id3MetadataKeyDate),
//        ].map { keySpace, key in
//            let dateMetadata = AVMutableMetadataItem()
//            dateMetadata.keySpace = keySpace
//            dateMetadata.key = key as NSString
//            dateMetadata.dataType = kCMMetadataBaseDataType_UTF8 as String
//            dateMetadata.value = "1970-02-01T10:59:43-0800" as NSString // Date(timeIntervalSince1970: 1000) as NSDate?
//            assert(dateMetadata.dateValue != nil)
//            return dateMetadata
//        }
//
//        let moreDates = [
//            AVMetadataIdentifier.commonIdentifierCreationDate,
//            .quickTimeMetadataCreationDate
//        ].map { identifier in
//            let dateMetadata = AVMutableMetadataItem()
//            dateMetadata.identifier = identifier
//            dateMetadata.dataType = kCMMetadataBaseDataType_UTF8 as String
//            dateMetadata.value = "1970-02-01T10:59:43-0800" as NSString // Date(timeIntervalSince1970: 1000) as NSDate?
//            assert(dateMetadata.dateValue != nil)
//            return dateMetadata
//        }
//
//        return dates + moreDates
//    }

}

extension PHImageManager {
    func getAVAsset(for asset: PHAsset) async throws -> AVAsset {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            //options.deliveryMode = .highQualityFormat
            //options.version = .current // save out edited versions (or original if no edits)
            options.version = .original
            options.isNetworkAccessAllowed = true // download if required
            requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: AssetError.fetch("Can't fetch", error))
                    return
                }
                guard let avAsset else {
                    continuation.resume(throwing: AssetError.fetch("Can't fetch", nil))
                    return
                }
                continuation.resume(returning: avAsset)
            }
        }
    }
}
