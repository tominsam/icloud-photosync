//
//  DropboxFile.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import CoreData
import Foundation
import SwiftyDropbox

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
    static func insertOrUpdate(_ metadatas: [Files.FileMetadata], delete deletedMetadatas: [Files.DeletedMetadata], into context: NSManagedObjectContext) async throws -> [DropboxFile] {
        guard !metadatas.isEmpty else { return [] }
        let existing = try await DropboxFile.matching("pathLower IN (%@)", args: [metadatas.map { $0.pathLower! }], in: context).uniqueBy(\.pathLower)
        let files = metadatas.compactMap { metadata -> DropboxFile? in
            guard let path = metadata.pathLower else { return nil }
            let file = existing[path] ?? context.performAndWait { context.insertObject() }
            file.update(from: metadata)
            return file
        }
        try await context.performSave()

        let newExisting = try await DropboxFile.matching("pathLower IN (%@)", args: [deletedMetadatas.map { $0.pathLower! }], in: context).uniqueBy(\.pathLower)
        deletedMetadatas.forEach { deleted in
            if let path = deleted.pathLower, let file = newExisting[path] {
                context.performAndWait {
                    context.delete(file)
                }
            }
        }
        try await context.performSave()

        return files
    }

    static func forPath(_ pathLower: String, context: NSManagedObjectContext) async throws -> DropboxFile? {
        return try await DropboxFile.matching("pathLower ==[c] %@", args: [pathLower], in: context).first
    }

    static func deleteAll(in context: NSManagedObjectContext) async throws {
        for file in try await DropboxFile.matching(nil, in: context) {
            await context.perform {
                context.delete(file)
            }
        }
        try await context.performSave(andReset: true)
    }

    internal func update(from metadata: Files.FileMetadata) {
        dropboxId = metadata.id
        pathLower = metadata.pathLower!
        rev = metadata.rev
        modified = metadata.serverModified
        contentHash = metadata.contentHash!
    }
}
