//  Copyright 2022 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import KeychainSwift
import Photos
import SwiftyDropbox
import UIKit

struct ServiceError {
    let path: String
    let message: String
    let error: Error?
}

struct ServiceState {
    var progress: Int = 0
    var total: Int = 0
    var complete: Bool = false
    var errors: [ServiceError] = []
}

protocol SyncManagerDelegate: NSObjectProtocol {
    func syncManagerUpdatedState(_ syncManager: SyncManager)
}

class SyncManager {
    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"
    private let keychain = KeychainSwift()

    static let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PhotoSync", conformingTo: .folder)

    let persistentContainer: NSPersistentContainer

    var syncing: Bool = false
    var photoState: ServiceState?
    var dropboxState: ServiceState?
    var uploadState: ServiceState?

    var errors: [ServiceError] {
        return (photoState?.errors ?? []) + (dropboxState?.errors ?? []) + (uploadState?.errors ?? [])
    }

    public weak var delegate: SyncManagerDelegate?

    public var isLoggedIn: Bool { return dropboxClient != nil }
    private var dropboxClient: DropboxClient? { DropboxClientsManager.authorizedClient }

    init(persistentContainer: NSPersistentContainer) {
        self.persistentContainer = persistentContainer
    }

    func maybeSync() {
        guard !syncing else { return }
        guard isLoggedIn else { return }
        guard PhotoKitManager.hasPermission else { return }
        sync()
    }

    func sync() {
        assert(!syncing)
        guard let client = dropboxClient else {
            fatalError()
        }
        syncing = true

        // Clear out anything we left in temp from the last run
        try? FileManager.default.createDirectory(at: SyncManager.tempDir, withIntermediateDirectories: true)
        if let tempFiles = try? FileManager.default.contentsOfDirectory(at: SyncManager.tempDir, includingPropertiesForKeys: nil) {
            for file in tempFiles {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    NSLog("%@", "Failed to delete temp file! \(error)")
                }
            }
        }

        let photoManager = PhotoKitManager(persistentContainer: persistentContainer, dropboxClient: client) { progress in
            self.photoState = progress
            self.delegate?.syncManagerUpdatedState(self)
        }
        let dropboxManager = DropboxManager(persistentContainer: persistentContainer, dropboxClient: client) { progress in
            self.dropboxState = progress
            self.delegate?.syncManagerUpdatedState(self)
        }
        let uploadManager = UploadManager(persistentContainer: persistentContainer, dropboxClient: client) { progress in
            self.uploadState = progress
            self.delegate?.syncManagerUpdatedState(self)
        }

        Task {
            do {
                NSLog("%@", "Starting photo sync")
                async let photoFetch: Void = photoManager.sync()
                NSLog("%@", "Starting dropbox sync")
                async let dropboxFetch: Void = dropboxManager.sync()

                try await photoFetch
                try await dropboxFetch

            } catch SwiftyDropbox.CallError<SwiftyDropbox.Files.ListFolderError>.authError,
                    SwiftyDropbox.CallError<SwiftyDropbox.Files.ListFolderContinueError>.authError {
                // TODO this is not the way to handle auth errors!
                exit(1)
            } catch {
                fatalError(error.localizedDescription)
            }
            if dropboxState?.errors.isEmpty != true && photoState?.errors.isEmpty != true {
                NSLog("There are errors in initial sync!")
                return
            }

            do {
                NSLog("%@", "Starting upload")
                try await uploadManager.sync(allAssets: photoManager.allAssets)
                syncing = false
            } catch {
                NSLog("%@", "Upload failed - \(error) \(String(describing: error)) \(error.localizedDescription)")
                fatalError(error.localizedDescription)
            }

            // resync dropbox at the end
            try? await dropboxManager.sync()
        }
    }
}
