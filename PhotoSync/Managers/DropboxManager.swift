//  Copyright 2020 Thomas Insam. All rights reserved.

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
        state = ServiceState()
        let context = persistentContainer.newBackgroundContext()

        // This is a guess, of course - we don't get a count from DB
        // at any point, so the best number we have is "the last number"
        state?.total = await context.perform {
            DropboxFile.count(in: context)
        }
        await progressUpdate(state!)

        // Try to resume a previous run if possible
        var cursor = (try await SyncToken.dataFor(type: .dropboxListFolder, in: context) as NSString?) as String?

        // If the cursor is nil, we've never fetched a page, get the first page as a bootstrap
        if cursor == nil {
            NSLog("%@", "Dropbox cursor is missing or invalid - resetting local sync state")

            // We don't have an existing cursor for this. First remove everything
            try await DropboxFile.deleteAll(in: context)

            // Now get the first page of results (DB has a cursor-based pagination API for
            // large results, and this is probably a large result). Path is "" - this isn't
            // the root of the Dropbox, this is the root of the app-specific folder we own.
            let listResult: Files.ListFolderResult
            do {
                listResult = try await dropboxClient.files.listFolder(path: "", recursive: true, includeDeleted: true).asyncResponse()
            } catch {
                state?.errors.append(ServiceError(path: "/", message: error.localizedDescription))
                return
            }
            cursor = try await gotPage(listResult, context: context)
        }

        // While there are more results, fetch and insert the next page
        while cursor != nil {
            let listResult: Files.ListFolderResult
            do {
                listResult = try await dropboxClient.files.listFolderContinue(cursor: cursor!).asyncResponse()
            } catch {
                state?.errors.append(ServiceError(path: "/", message: error.localizedDescription))
                return
            }
            cursor = try await gotPage(listResult, context: context)
            if !listResult.hasMore {
                break
            }
        }

        NSLog("%@", "File sync complete")
        state?.complete = true
        await progressUpdate(state!)
    }

    func gotPage(_ listResult: Files.ListFolderResult, context: NSManagedObjectContext) async throws -> String {
        try await self.insertPage(listResult: listResult, progressUpdate: progressUpdate)
        try await SyncToken.insertOrUpdate(type: .dropboxListFolder, value: listResult.cursor as NSString, into: context)
        return listResult.cursor
    }

    func insertPage(listResult: Files.ListFolderResult, progressUpdate: @MainActor @escaping (ServiceState) -> Void) async throws {
        // There are also folders in this list but they're unimportant
        let fileMetadata = listResult.entries.compactMap { $0 as? Files.FileMetadata }
        let deletedMetadata = listResult.entries.compactMap { $0 as? Files.DeletedMetadata }
        NSLog("%@", "Inserting / updating \(fileMetadata.count) file(s), deleting \(deletedMetadata.count) file(s)")

        let context = persistentContainer.newBackgroundContext()
        try await DropboxFile.insertOrUpdate(fileMetadata, delete: deletedMetadata, into: context)
        let total = DropboxFile.count(in: context)

        state?.progress += fileMetadata.count
        state?.total = total

        await progressUpdate(state!)
    }

}
