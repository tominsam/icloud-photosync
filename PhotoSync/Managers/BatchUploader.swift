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

enum AssetData {
    case image(Data)
    case video(AVURLAsset)

    func dropboxContentHash() -> String? {
        switch self {
        case .image(let data):
            return data.dropboxContentHash()
        case .video(let asset):
            return asset.dropboxContentHash()
        }
    }

}

// Upload bundles of assets to dropbox at once - this is much much faster than uploading individually,
// even though it's much more complicated, because Dropbox has internal transaction / locking that effectively
// prevent me uploading more than one file at once.
class BatchUploader: LoggingOperation {
    struct UploadTask {
        let asset: PHAsset
        let filename: String
        let existingContentHash: String?
    }

    static func batchUpload(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, tasks: [UploadTask]) async throws {

        // concurrent upload
        let finishEntries = try await withThrowingTaskGroup(of: Files.UploadSessionFinishArg?.self) { group -> [Files.UploadSessionFinishArg?] in

            for task in tasks {
                group.addTask {
                    try await upload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, task: task)
                }
            }

            var output = [Files.UploadSessionFinishArg?]()
            for try await value in group {
                output.append(value)
            }
            return output
        }.compactMap {$0}

        guard !finishEntries.isEmpty else {
            // Everything in the batch was already on dropbox
            NSLog("Nothing to upload")
            return
        }

        let metadata = try await finish(dropboxClient: dropboxClient, entries: finishEntries)

        try await jobComplete(persistentContainer: persistentContainer, success: metadata)
    }

    private static func getImageData(asset: PHAsset) async throws -> AssetData? {
        let manager = PHImageManager.default()

        switch asset.mediaType {
        case .image:
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current // save out edited versions (or original if no edits)
            options.isNetworkAccessAllowed = true // download if required
            options.isSynchronous = true // block operation
            return try await withCheckedThrowingContinuation { continuation in
                manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    guard let data = data else {
//                        continuation.resume(throwing: UploadError.photoKit("Can't fetch photo: \(info)"))
                        NSLog("%@", "Can't fetch photo: \(info)")
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: .image(data))
                }
            }

        case .video:
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current // save out edited versions (or original if no edits)
            options.isNetworkAccessAllowed = true // download if required
            return try await withCheckedThrowingContinuation { continuation in
                manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    guard let avUrlAsset = avAsset as? AVURLAsset else {
                        // continuation.resume(throwing: UploadError.photoKit("Can't fetch video"))
                        NSLog("%@", "Can't fetch video: \(info)")
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: .video(avUrlAsset))
                }
            }

        default:
            NSLog("%@", "Skipping media type \(asset.mediaType.rawValue)")
            fatalError()
        }

    }

    private static func upload(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, task: BatchUploader.UploadTask) async throws -> Files.UploadSessionFinishArg? {
        // Get photo from photoKit
        NSLog("%@", "Downloading \(task.filename)")
        guard let data = try await getImageData(asset: task.asset) else {
            return nil
        }

        // TODO get this async, it's potentially reading hundreds of megs off disk
        guard let hash = data.dropboxContentHash() else {
            throw UploadError.photoKit("Can't fetch image contents for \(task.filename)")
        }

        // Store the content hash on the database object before we start the upload
        let context = persistentContainer.newBackgroundContext()
        try await context.perform {
            if let photo = Photo.forAsset(task.asset, in: context) {
                photo.contentHash = hash
                try context.save()
            }
        }

        // Skip the upload if the file is unchanged
        if task.existingContentHash == hash {
            return nil
        }

        // Upload the file to dropbox. This needs to be "finished", but we do that in batches.
        NSLog("%@", "Uploading \(task.filename) with \(hash) replacing \(task.existingContentHash ?? "nil")")
        switch data {
        case .image(let data):
            return try await upload(dropboxClient: dropboxClient, task: task, data: data)
        case .video(let avUrlAsset):
            return try await upload(dropboxClient: dropboxClient, task: task, avAsset: avUrlAsset)
        }
    }

    static func upload(dropboxClient: DropboxClient, task: BatchUploader.UploadTask, data: Data) async throws -> Files.UploadSessionFinishArg {
        let result = try await dropboxClient.files.uploadSessionStart(close: true, input: data).asyncResponse()
        let length = data.count
        NSLog("%@", "..uploaded \(length.formatted()) bytes")

        let cursor = Files.UploadSessionCursor(
            sessionId: result.sessionId,
            offset: UInt64(length)
        )
        let commitInfo = Files.CommitInfo(
            path: task.filename,
            mode: .overwrite,
            autorename: false,
            clientModified: task.asset.creationDate ?? task.asset.modificationDate
        )
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
    }

    static func upload(dropboxClient: DropboxClient, task: BatchUploader.UploadTask, avAsset: AVURLAsset) async throws -> Files.UploadSessionFinishArg {
        let result = try await dropboxClient.files .uploadSessionStart(close: true, input: avAsset.url).asyncResponse()

        let resources = try avAsset.url.resourceValues(forKeys: [.fileSizeKey])
        let length = resources.fileSize!
        NSLog("%@", "..uploaded \(length.formatted()) bytes")

        let cursor = Files.UploadSessionCursor(
            sessionId: result.sessionId,
            offset: UInt64(length)
        )
        let commitInfo = Files.CommitInfo(
            path: task.filename,
            mode: .overwrite,
            autorename: false,
            clientModified: task.asset.creationDate ?? task.asset.modificationDate
        )
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
    }

    private static func finish(dropboxClient: DropboxClient, entries: [Files.UploadSessionFinishArg]) async throws -> [Files.FileMetadata] {
        NSLog("%@", "Finishing \(entries.count) uploads")
        let result = try await dropboxClient.files.uploadSessionFinishBatchV2(entries: entries).asyncResponse()
        var success = [Files.FileMetadata]()
        for entry in result.entries {
            switch entry {
            case let .success(fileMetadata):
                success.append(fileMetadata)
            case let .failure(error):
                throw UploadError.dropbox(error.description)
            }
        }
        return success
    }

    private static func jobComplete(persistentContainer: NSPersistentContainer, success: [Files.FileMetadata]) async throws {
        // Now we've uploaded all the files, we can connect them to the original assets in core data.
        NSLog("%@", "Complete")
        // Really need better error handling
        let context = persistentContainer.newBackgroundContext()
        try await context.perform {
            for file in success {
                DropboxFile.insertOrUpdate([file], syncRun: "", into: context)
            }
            try context.save()
        }
    }
}
