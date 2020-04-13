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

    @NSManaged public var photoKitId: String
    @NSManaged public var created: Date?
    @NSManaged public var dropboxId: String?
    @NSManaged public var dropboxRev: String?
    @NSManaged public var modified: Date?
    @NSManaged public var removedFromServer: Bool
    @NSManaged public var syncRun: String?
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

    @discardableResult
    public static func delete(_ assets: [PHAsset], syncRun: String, in context: NSManagedObjectContext) -> [Photo] {
        guard !assets.isEmpty else { return [] }
        let existing = Photo.matching("photoKitId IN (%@)", args: [assets.map { $0.localIdentifier }], in: context).uniqueBy(\.photoKitId)
        return assets.compactMap { asset in
            guard let photo = existing[asset.localIdentifier] else {
                NSLog("Can't delete photo \(asset.localIdentifier)")
                return nil
            }
            photo.markRemoved()
            photo.syncRun = syncRun
            return photo
        }
    }

    func update(from asset: PHAsset) {
        photoKitId = asset.localIdentifier
        created = asset.creationDate
        modified = asset.modificationDate
    }

    func markRemoved() {
        removedFromServer = true
        modified = Date()
    }

    

}
