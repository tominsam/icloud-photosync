// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
@preconcurrency import SwiftyDropbox

@objc(DropboxFile)
public class DropboxFile: NSManagedObject, ManagedObject {
    public static var defaultSortDescriptors: [NSSortDescriptor] {
        return [NSSortDescriptor(key: "modified", ascending: false)]
    }

    @NSManaged public var dropboxId: String
    @NSManaged public var pathLower: String
    @NSManaged public var rev: String
    @NSManaged public var contentHash: String
    @NSManaged public var modified: Date?
}

public extension DropboxFile {
    @discardableResult
    static func insertOrUpdate(_ metadatas: [Files.FileMetadata], delete deletedMetadatas: [Files.DeletedMetadata], into context: NSManagedObjectContext) throws -> [DropboxFile] {
        let files: [DropboxFile]
        if !metadatas.isEmpty {
            let existing = try DropboxFile.matching("pathLower IN (%@)", args: [metadatas.map { $0.pathLower! }], in: context).uniqueBy(\.pathLower)
            files = metadatas.compactMap { metadata -> DropboxFile? in
                guard let path = metadata.pathLower else { return nil }
                let file = existing[path] ?? context.insertObject()
                file.update(from: metadata)
                return file
            }
            try context.save()
        } else {
            files = []
        }

        if !deletedMetadatas.isEmpty {
            let newExisting = try DropboxFile.matching("pathLower IN (%@)", args: [deletedMetadatas.map { $0.pathLower! }], in: context).uniqueBy(\.pathLower)
            deletedMetadatas.forEach { deleted in
                if let path = deleted.pathLower, let file = newExisting[path] {
                    context.delete(file)
                }
            }
            try context.save()
        }

        return files
    }

    static func forPath(_ pathLower: String, context: NSManagedObjectContext) throws -> DropboxFile? {
        return try DropboxFile.matching("pathLower ==[c] %@", args: [pathLower], in: context).first
    }

    static func deleteAll(in context: NSManagedObjectContext) throws {
        for file in try DropboxFile.matching(nil, in: context) {
            context.delete(file)
        }
        try context.save(andReset: true)
    }

    internal func update(from metadata: Files.FileMetadata) {
        dropboxId = metadata.id
        pathLower = metadata.pathLower!
        rev = metadata.rev
        modified = metadata.serverModified
        contentHash = metadata.contentHash!
    }
}
