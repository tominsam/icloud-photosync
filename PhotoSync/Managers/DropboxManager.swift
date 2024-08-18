//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import Photos
import SwiftyDropbox
import UIKit

class DropboxManager: Manager {

    func sync() async throws {
        let context = persistentContainer.newBackgroundContext()

        // This is a guess, of course - we don't get a count from DB
        // at any point, so the best number we have is "the last number"
        let count = await context.perform {
            DropboxFile.count(in: context)
        }
        var state = await stateManager.createState(named: "Dropbox", total: count)

        // Try to resume a previous run if possible
        var cursor = (try await SyncToken.dataFor(type: .dropboxListFolder, in: context) as NSString?) as String?

        // If the cursor is nil, we've never fetched a page, get the first page as a bootstrap
        if cursor == nil {
            NSLog("%@", "Dropbox cursor is missing or invalid - resetting local sync state")
            await state.updateTotal(to: 0)

            // We don't have an existing cursor for this. First remove everything
            try await DropboxFile.deleteAll(in: context)

            // Now get the first page of results (DB has a cursor-based pagination API for
            // large results, and this is probably a large result). Path is "" - this isn't
            // the root of the Dropbox, this is the root of the app-specific folder we own.
            let listResult: Files.ListFolderResult
            do {
                listResult = try await dropboxClient.files.listFolder(path: "", recursive: true, includeDeleted: true, limit: 2000).asyncResponse()
            } catch {
                NSLog("Error calling dropbox listFolder: %@", error.localizedDescription)
                await recordError(ServiceError(path: "/", message: error.localizedDescription, error: error))
                throw error
            }
            cursor = try await gotPage(listResult, context: context, state: &state)
        }
        NSLog("Cursor is %@", String(describing: cursor))

        // While there are more results, fetch and insert the next page
        while cursor != nil {
            let listResult: Files.ListFolderResult
            do {
                listResult = try await dropboxClient.files.listFolderContinue(cursor: cursor!).asyncResponse()
            } catch {
                NSLog("Error calling dropbox listFolderContinue: %@", error.localizedDescription)
                await recordError(ServiceError(path: "/", message: error.localizedDescription, error: error))
                throw error
            }
            cursor = try await gotPage(listResult, context: context, state: &state)
            if !listResult.hasMore {
                NSLog("All files fetched from dropbox")
                break
            }
        }

        NSLog("%@", "File sync complete")
        await state.setComplete()
    }

    func gotPage(_ listResult: Files.ListFolderResult, context: NSManagedObjectContext, state: inout ServiceState) async throws -> String {
        try await self.insertPage(listResult: listResult, state: &state)
        try await SyncToken.insertOrUpdate(type: .dropboxListFolder, value: listResult.cursor as NSString, into: context)
        return listResult.cursor
    }

    func insertPage(listResult: Files.ListFolderResult, state: inout ServiceState) async throws {
        // There are also folders in this list but they're unimportant
        let fileMetadata = listResult.entries.compactMap { $0 as? Files.FileMetadata }
        let deletedMetadata = listResult.entries.compactMap { $0 as? Files.DeletedMetadata }
        NSLog("%@", "Inserting / updating \(fileMetadata.count) file(s), deleting \(deletedMetadata.count) file(s)")
        let context = persistentContainer.newBackgroundContext()
        try await DropboxFile.insertOrUpdate(fileMetadata, delete: deletedMetadata, into: context)
        await state.increment(listResult.entries.count)
    }

}
