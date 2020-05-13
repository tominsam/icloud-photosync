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
    @NSManaged public var pathLower: String

    // The dropbox contenthash of the image. nil becaue we need the
    // image data to calculate this, so I'll only set it when I
    // have read the image.
    @NSManaged public var contentHash: String?

    @NSManaged public var uploadRun: String?
}

extension Photo {

    @discardableResult
    public static func insertOrUpdate(_ assets: [PHAsset], into context: NSManagedObjectContext) -> [Photo] {
        guard !assets.isEmpty else { return [] }
        let existing = Photo.matching("photoKitId IN (%@)", args: [assets.map { $0.localIdentifier }], in: context).uniqueBy(\.photoKitId)
        return assets.map { asset in
            let photo = existing[asset.localIdentifier] ?? context.insertObject()
            photo.update(from: asset)
            return photo
        }
    }

    public static func forAsset(_ asset: PHAsset, in context: NSManagedObjectContext) -> Photo? {
        return Photo.matching("photoKitId = %@", args: [asset.localIdentifier], in: context).first
    }

    private func update(from asset: PHAsset) {
        photoKitId = asset.localIdentifier
        created = asset.creationDate
        if modified != asset.modificationDate {
            // if the file has been changed, invalidate the content hash
            contentHash = nil
            modified = asset.modificationDate
        }
        if pathLower.isEmpty {
            pathLower = asset.dropboxPath.localizedLowercase
        }
    }

}

