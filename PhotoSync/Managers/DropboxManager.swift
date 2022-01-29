//
//  DropboxManager.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import CoreData
import SwiftyDropbox
import KeychainSwift
import Photos

extension NSNotification.Name {
    static let DropboxManagerSyncProgress = NSNotification.Name("DropboxManagerSyncProgress")
}

class DropboxManager: NSObject {

    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"

    enum State {
        case notStarted
        case syncing
        case error(String)
        case finished
    }
    public private(set) var state: State = .notStarted
    public let progress = Progress()
    public var isLoggedIn: Bool { return dropboxClient != nil }
    public var dropboxClient: DropboxClient?

    private let persistentContainer = AppDelegate.shared.persistentContainer
    private let keychain = KeychainSwift()

    override init() {
        super.init()
        connect()
    }

    func connect() {
        assert(Thread.isMainThread)
        if let accessToken = keychain.get(Self.KeychainDropboxAccessToken) {
            dropboxClient = DropboxClient(accessToken: accessToken)
        } else {
            dropboxClient = nil
        }
    }

    func logIn(accessToken: String) {
        assert(Thread.isMainThread)
        keychain.set(accessToken, forKey: Self.KeychainDropboxAccessToken)
        connect()
        sync()
    }

    func logOut() {
        assert(Thread.isMainThread)
        dropboxClient?.auth.tokenRevoke().response { _, _ in
            // We don't care if there are errors
        }
        keychain.delete(Self.KeychainDropboxAccessToken)
        dropboxClient = nil
        state = .notStarted
        sync()
    }

    func sync() {
        assert(Thread.isMainThread)
        guard let client = dropboxClient else {
            progress.totalUnitCount = 0
            progress.completedUnitCount = 0
            self.progress.pause()
            NotificationCenter.default.post(name: .PhotoKitManagerSyncProgress, object: self.progress)
            return
        }
        if case .syncing = state { return }
        state = .syncing
        progress.totalUnitCount = Int64(DropboxFile.count(in: persistentContainer.viewContext))
        progress.completedUnitCount = 0

        let runIdentifier = UUID().uuidString

        client.files.listFolder(path: "", recursive: true).response { [unowned self] listResult, error in
            if let error = error {
                NSLog("Dropbox error: %@", error.description)
                self.state = .error(error.description)
                if case .authError = error {
                    self.logOut()
                }
            } else {
                self.handlePage(listResult!, runIdentifier: runIdentifier)
            }
        }
    }

    func handlePage(_ listResult: Files.ListFolderResult, runIdentifier: String) {
        guard let client = dropboxClient else { return }

        // Only consider actual files
        let fileMetadata = listResult.entries.compactMap { $0 as? Files.FileMetadata }

        persistentContainer.performBackgroundTask { [unowned self] context in
            NSLog("Inserting / updating \(fileMetadata.count) file(s)")
            DropboxFile.insertOrUpdate(fileMetadata, syncRun: runIdentifier, into: context)

            if listResult.hasMore {
                client.files.listFolderContinue(cursor: listResult.cursor).response { [unowned self] listResult, error in
                    if let error = error {
                        NSLog("Dropbox error: %@", error.description)
                        self.state = .error(error.description)
                        if case .authError = error {
                            self.logOut()
                        }
                    } else {
                        self.handlePage(listResult!, runIdentifier: runIdentifier)
                    }
                }

            } else {
                let removed = DropboxFile.matching("syncRun != %@", args: [runIdentifier], in: context)
                if !removed.isEmpty {
                    NSLog("Removing \(removed.count) deleted file(s)")
                    for file in removed {
                        context.delete(file)
                    }
                }
                NSLog("File sync complete")
                self.state = .finished
            }

            try! context.save()

            // We can't actually count these, so we'll do our best
            self.progress.completedUnitCount += Int64(fileMetadata.count)
            self.progress.totalUnitCount = max(
                self.progress.totalUnitCount,
                Int64(DropboxFile.count(in: context)))

            DispatchQueue.main.async { [unowned self] in
                NotificationCenter.default.post(name: .PhotoKitManagerSyncProgress, object: self.progress)
            }
        }

    }

}
