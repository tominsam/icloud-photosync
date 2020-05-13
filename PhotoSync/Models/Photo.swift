//
//  Photo.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Foundation
import CoreData
import Photos

@objc(Photo)
public class Photo: NSManagedObject, ManagedObject {

    public static var defaultSortDescriptors: [NSSortDescriptor] {
        return [NSSortDescriptor(key: "created", ascending: false)]
    }

    // Properties from photokit
    @NSManaged public var photoKitId: String
    @NSManaged public var created: Date?
    @NSManaged public var modified: Date?

    // Where should the file be on disk in dropbox, ideally? Stored as the lower-case
    // version to make dropbox lookup better. When actually uploading, use the version
    // on PHAsset so as to respect the original filename better. Optional because it's
    // a little expensive to calculate, so defer for as long as possible
    // TODO I want to wokr out if I can remove this entirely. It's only here to detect
    // files we need to delete from dropbox.
    @NSManaged public var pathLower: String?

    // The dropbox contenthash of the image. nil becaue we need the
    // image data to calculate this, so I'll only set it when I
    // have read the image.
    @NSManaged public var contentHash: String?

    // Used to detect photos removed since the last sync
    @NSManaged public var syncRun: String?

    // True if the asset is deleted from photokit and should therefore be deleted from dropbox
    @NSManaged public var removedFromServer: Bool
}

extension Photo {

    @discardableResult
    public static func insertOrUpdate(_ assets: [PHAsset], syncRun: String, into context: NSManagedObjectContext) -> [Photo] {
        guard !assets.isEmpty else { return [] }
        let existing = Photo.matching("photoKitId IN (%@)", args: [assets.map { $0.localIdentifier }], in: context).uniqueBy(\.photoKitId)
        return assets.map { asset in
            let photo = existing[asset.localIdentifier] ?? context.insertObject()
            photo.update(from: asset)
            photo.syncRun = syncRun
            return photo
        }
    }

    public static func forAsset(_ asset: PHAsset, in context: NSManagedObjectContext) -> Photo? {
        return Photo.matching("photoKitId = %@", args: [asset.localIdentifier], in: context).first
    }

    func update(from asset: PHAsset) {
        photoKitId = asset.localIdentifier
        created = asset.creationDate
        if modified != asset.modificationDate {
            // if the file has been changed, invalidate the content hash
            contentHash = nil
            pathLower = nil
            modified = asset.modificationDate
        }
    }

    func markRemoved() {
        removedFromServer = true
        modified = Date()
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
        if let creationDate = self.creationDate {
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
        let filename = (PHAssetResource.assetResources(for: self).first(where: { $0.type == .photo || $0.type == .video })?.originalFilename)!
        return "/\(datePath)/\(filename)"
    }
}
