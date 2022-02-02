//
//  DropboxManager.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import CoreData
import Photos
import SwiftyDropbox
import UIKit

class DropboxManager {
    public var state: ServiceState?

    let persistentContainer: NSPersistentContainer
    let dropboxClient: DropboxClient
    let progressUpdate: @MainActor(ServiceState) -> Void

    init(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, progressUpdate: @escaping (ServiceState) -> Void) {
        self.persistentContainer = persistentContainer
        self.dropboxClient = dropboxClient
        self.progressUpdate = progressUpdate
    }

    func sync() async throws {
        if state != nil {
            return
        }
        assert(state == nil)
        state = ServiceState()
        let context = persistentContainer.newBackgroundContext()

        // This is a guess, of course - we don't get a count from DB
        // at any point, so the best number we have is "the last number"
        state?.total = await context.perform {
            DropboxFile.count(in: context)
        }
        await progressUpdate(state!)

        let runIdentifier = UUID().uuidString

        // Get the first page of results (DB has a cursor-based pagination API for
        // large results, and this is probably a large result). Path is "" - this isn't
        // the root of the Dropbox, this is the root of the app-specific folder we own.
        var listResult = try await dropboxClient.files.listFolder(path: "", recursive: true).asyncResponse()
        try await insertPage(listResult: listResult, runIdentifier: runIdentifier, progressUpdate: progressUpdate)

        // While there are more results, fetch and insert the next page
        while listResult.hasMore {
            listResult = try await dropboxClient.files.listFolderContinue(cursor: listResult.cursor).asyncResponse()
            try await insertPage(listResult: listResult, runIdentifier: runIdentifier, progressUpdate: progressUpdate)
        }

        // Once we've fetched everything, remove from the database anything that wasn't fetched
        // (and that must therefore have been removed)
        try await removeRemainder(runIdentifier: runIdentifier)

        NSLog("%@", "File sync complete")
        state?.complete = true
        await progressUpdate(state!)
    }

    func insertPage(listResult: Files.ListFolderResult, runIdentifier: String, progressUpdate: @MainActor @escaping (ServiceState) -> Void) async throws {
        // Only consider actual files (the sync response is very complicated and can contain
        // folders and deleted files, but I'm not bothering with any of that - I just want a
        // list of all the files, and I'll remove everything else at the end.
        let fileMetadata = listResult.entries.compactMap { $0 as? Files.FileMetadata }
        NSLog("%@", "Inserting / updating \(fileMetadata.count) file(s)")

        let context = persistentContainer.newBackgroundContext()
        let total = try await context.perform { () -> Int in
            DropboxFile.insertOrUpdate(fileMetadata, syncRun: runIdentifier, into: context)
            try context.save()
            return DropboxFile.count(in: context)
        }

        state?.progress += fileMetadata.count
        state?.total = total

        await progressUpdate(state!)
    }

    // Any file in the database with a _different_ run identifier wasn't inserted in this
    // path, so it must have been removed on the dropbox side of things. Delete it from the
    // local database.
    func removeRemainder(runIdentifier: String) async throws {
        let context = persistentContainer.newBackgroundContext()
        let removed = DropboxFile.matching("syncRun != %@", args: [runIdentifier], in: context)
        if removed.isEmpty {
            return
        }
        NSLog("%@", "Removing \(removed.count) deleted file(s)")
        try await context.perform {
            for file in removed {
                context.delete(file)
            }
            try context.save()
        }
    }
}
