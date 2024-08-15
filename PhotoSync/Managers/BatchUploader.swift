//  Copyright 2020 Thomas Insam. All rights reserved.

import CollectionConcurrencyKit
import CoreData
import Photos
import SwiftyDropbox
import UIKit

enum UploadError: Error {
    case photoKit(String)
    case dropbox(String)
}

// Upload bundles of assets to dropbox at once - this is much much faster than uploading individually,
// even though it's much more complicated, because Dropbox has internal transaction / locking that effectively
// prevent me uploading more than one file at once.
class BatchUploader: LoggingOperation {
    enum UploadState {
        // File is not in dropbox
        case new
        // File is in dropbox, local hash is different
        case replacement
        // File is in dropbox, local hash is nil
        case unknown
    }
    public struct UploadTask {
        let asset: PHAsset
        let filename: String
        let existingContentHash: String?
        let cloudIdentifier: String
        let state: UploadState
    }

    private enum UploadResult {
        case success(String, Files.UploadSessionFinishArg)
        case unchanged
        case failure(path: String, message: String, error: Error?)
    }

    public enum FinishResult {
        case success(Files.FileMetadata)
        case unchanged
        case failure(path: String, message: String, error: Error?)
    }

    public static func batchUpload(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, tasks: [UploadTask]) async -> [FinishResult] {
        NSLog("%@", "Fetching chunk of \(tasks.count) files")

        // Download all the images, one at a time, in advance.
        let data = await tasks.asyncMap { await download(persistentContainer: persistentContainer, asset: $0.asset) }

        NSLog("%@", "Uploading chunk of \(data.filter { $0.hash != nil }.count) files")

        // concurrently upload all the files
        let uploadResults = await withTaskGroup(of: UploadResult.self) { group -> [UploadResult] in
            for (task, data) in zip(tasks, data) {
                if data.hash != nil && task.existingContentHash == data.hash {
                    // This means that we've uploaded it before, in another install or whatever -
                    // the db hash equals the newly-calculated file hash, and we can skip it.
                    continue
                }
                group.addTask {
                    let uploadSession: Files.UploadSessionFinishArg
                    do {
                        switch data {
                        case let .data(data, hash):
                            uploadSession = try await uploadData(
                                dropboxClient: dropboxClient,
                                filename: task.filename,
                                date: task.asset.creationDate ?? task.asset.modificationDate,
                                contentHash: hash,
                                cloudIdentifier: task.cloudIdentifier,
                                data: data)
                        case .url(let url, let hash), .tempUrl(let url, let hash):
                            uploadSession = try await uploadUrl(
                                dropboxClient: dropboxClient,
                                filename: task.filename,
                                date: task.asset.creationDate ?? task.asset.modificationDate,
                                contentHash: hash,
                                cloudIdentifier: task.cloudIdentifier,
                                url: url)
                        case .failure(let error):
                            throw error
                        }
                        if case .tempUrl(let url, _) = data {
                            // We exported a video to a temp file, let's clean that up
                            try? FileManager.default.removeItem(at: url)
                        }
                    } catch {
                        return .failure(path: task.filename, message: error.localizedDescription, error: error)
                    }
                    return .success(task.filename, uploadSession)
                }
            }
            var output = [UploadResult]()
            for await value in group {
                output.append(value)
            }
            return output
        }

        guard !uploadResults.isEmpty else {
            NSLog("%@", "Skipped all files")
            return []
        }

        if uploadResults.count < tasks.count {
            NSLog("%@", "Skipped \(tasks.count - uploadResults.count) file(s)")
        }

        do {
            return try await finish(dropboxClient: dropboxClient, entries: uploadResults)
        } catch {
            return uploadResults.map { result -> FinishResult in
                switch result {
                case .success(let filename, _):
                    return .failure(path: filename, message: error.localizedDescription, error: error)
                case .unchanged:
                    return .unchanged
                case .failure(path: let path, message: let message, error: let error):
                    return .failure(path: path, message: message, error: error)
                }
            }
        }
    }

    private static func download(persistentContainer: NSPersistentContainer, asset: PHAsset) async -> AssetData {
        // Get photo from photoKit. This is slow.
        do {
            // this is the _final_ image data, including patched exif for edited files and videos
            let data = try await asset.getImageData()

            // Store the content hash on the database object before we start the upload
            let context = persistentContainer.newBackgroundContext()
            if let photo = try await Photo.forLocalIdentifier(asset.localIdentifier, in: context) {
                photo.contentHash = data.hash
                try await context.performSave()
            }

            return data
        } catch {
            return .failure(error)
        }
    }

    private static func uploadData(dropboxClient: DropboxClient, filename: String, date: Date?, contentHash: String, cloudIdentifier: String, data: Data) async throws -> Files.UploadSessionFinishArg {
        // Theoretically if data is >150mb we have a problem here, but that seems unlikely
        // for most use cases right now. (hahahaha yes I know)
        let length = data.count
        let result = try await dropboxClient.files.uploadSessionStart(
            close: true,
            contentHash: contentHash,
            input: data
        ).asyncResponse()
        let cursor = Files.UploadSessionCursor(
            sessionId: result.sessionId,
            offset: UInt64(length)
        )
        let commitInfo = Files.CommitInfo(
            path: filename,
            mode: .overwrite,
            autorename: false,
            clientModified: date
            //propertyGroups: [.init(templateId: "foo", fields: [.init(name: "cloudIdentifier", value: cloudIdentifier)])]
        )
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
    }

    private static func uploadUrl(dropboxClient: DropboxClient, filename: String, date: Date?, contentHash: String, cloudIdentifier: String, url: URL) async throws -> Files.UploadSessionFinishArg {
        // We need to close the last chunk - we'll track that by fetching
        // the total file size and checking the total uploaded bytes against it.
        let resources = try url.resourceValues(forKeys: [.fileSizeKey])
        let totalFileSize = resources.fileSize!

        // Dropbox has a file size limit on upload chunks, so we'll batch the file off disk
        // in chunks and upload them piece by piece. Magic number here is from the DB docs -
        // chunk size must be a multiple of 4194304.
        let chunkSize = 4_194_304 * 5
        let dataReader = try AsyncDataFetcher(url: url, chunkSize: chunkSize)

        // start upload with first chunk
        let firstChunk = await dataReader.next()!
        let result = try await dropboxClient.files.uploadSessionStart(
            close: firstChunk.count == totalFileSize,
            contentHash: firstChunk.dropboxContentHash(),
            input: firstChunk
        ).asyncResponse()
        let sessionId = result.sessionId
        var cursorOffset = firstChunk.count

        // ..keep loading and appending as long as there is more data..
        while let nextData = await dataReader.next() {
            let cursor = Files.UploadSessionCursor(
                sessionId: sessionId,
                offset: UInt64(cursorOffset)
            )
            try await dropboxClient.files.uploadSessionAppendV2(
                cursor: cursor,
                close: cursorOffset + nextData.count == totalFileSize,
                contentHash: nextData.dropboxContentHash(),
                input: nextData
            ).asyncResponse()
            cursorOffset += nextData.count
        }

        // ..and the finish call will wrap it up.
        let cursor = Files.UploadSessionCursor(
            sessionId: sessionId,
            offset: UInt64(cursorOffset)
        )
        let commitInfo = Files.CommitInfo(
            path: filename,
            mode: .overwrite,
            autorename: false,
            clientModified: date
            //propertyGroups: [.init(templateId: "foo", fields: [.init(name: "cloudIdentifier", value: cloudIdentifier)])]
        )
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo, contentHash: contentHash)
    }

    private static func finish(dropboxClient: DropboxClient, entries: [UploadResult]) async throws -> [FinishResult] {
        var finishArgs = [Files.UploadSessionFinishArg]()
        for entry in entries {
            if case let .success(_, arg) = entry {
                finishArgs.append(arg)
            }
        }

        NSLog("%@", "Finishing \(finishArgs.count) uploads")
        let finishResult = try await dropboxClient.files.uploadSessionFinishBatchV2(entries: finishArgs).asyncResponse()
        var mutableFinishResults = Array(finishResult.entries)
        assert(mutableFinishResults.count == finishArgs.count)
        var finishResults = [FinishResult]()
        for entry in entries {
            switch entry {
            case let .success(filename, _):
                let result: Files.UploadSessionFinishBatchResultEntry = mutableFinishResults.removeFirst()
                switch result {
                case let .success(metaData):
                    finishResults.append(.success(metaData))
                case let .failure(error):
                    finishResults.append(.failure(path: filename, message: error.description, error: nil))
                }

            case .unchanged:
                finishResults.append(.unchanged)
            case let .failure(path, message, error):
                finishResults.append(.failure(path: path, message: message, error: error))
            }
        }
        assert(mutableFinishResults.isEmpty)
        return finishResults
    }

}
