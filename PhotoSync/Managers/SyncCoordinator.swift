// Copyright 2022 Thomas Insam. All rights reserved.

import CoreData
import Combine
import Foundation
import KeychainSwift
import Photos
import SwiftyDropbox
import UIKit

struct ServiceError: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let message: String
    let error: Error?
}

/// Master coordinator for the whole sync operation, tracks state, and it's also the view
/// model because i am very good at architecture.
@MainActor
@Observable
class SyncCoordinator {
    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"
    private let keychain = KeychainSwift()

    static let tempDir = URL(
        fileURLWithPath: NSTemporaryDirectory(),
        isDirectory: true
    ).appendingPathComponent("PhotoSync", conformingTo: .folder)
    
    let database: Database
    let progressManager = ProgressManager()

    // keep the app alive when we background it for as long as possible
    var backgroundTask: UIBackgroundTaskIdentifier?
    
    // set if there's a sync running
    var syncTask: Task<Void, Never>?

    // UI state
    var isLoggedIn: Bool = false
    var errors: [ServiceError] = []
    var states: [TaskProgress] { progressManager.states }

    private var dropboxClient: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }
    
    init(database: Database) {
        self.database = database
    }
    
    func maybeSync() {
        isLoggedIn = dropboxClient != nil
        guard isLoggedIn else { return }
        guard PhotoKitManager.hasPermission else { return }
        guard syncTask == nil else { return }
        syncTask = Task {
            defer { syncTask = nil }
            await sync()
        }
    }
    
    func logError(_ error: ServiceError) {
        NSLog("%@", "[ERROR] \(error.message): \(error.path)")
        errors.append(error)
    }
    
    func sync() async {
        guard let client = dropboxClient else {
            fatalError()
        }

        // If the user backgrounds the app, try to stay alive as long as possible
        // Future work - schedule a notification for when we lose this?
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sync") { [weak self] in
            NSLog("Stopping background task")
            if let identifier = self?.backgroundTask {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
        
        // Clear out anything we left in temp from the last run
        try? FileManager.default.createDirectory(at: SyncCoordinator.tempDir, withIntermediateDirectories: true)
        if let tempFiles = try? FileManager.default.contentsOfDirectory(at: SyncCoordinator.tempDir, includingPropertiesForKeys: nil) {
            for file in tempFiles {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    logError(ServiceError(path: file.absoluteString, message: "Failed to delete temp file", error: nil))
                }
            }
        }
        
        let photoManager = PhotoKitManager(
            database: database,
            progressManager: progressManager,
            errorUpdate: self.logError,
        )

        let dropboxManager = DropboxManager(
            database: database,
            dropboxClient: client,
            progressManager: progressManager,
            errorUpdate: self.logError,
        )

        let uploadManager = UploadManager(
            database: database,
            dropboxClient: client,
            progressManager: progressManager,
            errorUpdate: self.logError,
        )
        
        // Sync photos and dropbox at the same time
        await withTaskGroup { group in
            group.addTask {
                NSLog("%@", "Starting photo sync")
                await photoManager.sync()
            }
            group.addTask {
                NSLog("%@", "Starting dropbox sync")
                await dropboxManager.sync()
            }
        }

        // Those both need to have passed otherwise it's not safe to do any writes.
        if !errors.isEmpty {
            logError(ServiceError(path: "/", message: "Sync failed, aborting upload", error: nil))
            return
        }
        
        NSLog("%@", "Starting upload")
        await uploadManager.sync()
        
        // resync dropbox at the end to get the newly-uploaded files
        await dropboxManager.sync()
        
        if let identifier = backgroundTask {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    func connectDropbox() {
        // We need something to present a view controller from
        let controller = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.rootViewController

        let scopeRequest = ScopeRequest(
            scopeType: .user,
            scopes: ["files.metadata.read", "files.content.write"],
            includeGrantedScopes: false
        )
        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: controller,
            loadingStatusDelegate: nil,
            openURL: { UIApplication.shared.open($0, options: [:], completionHandler: nil) },
            scopeRequest: scopeRequest
        )
    }
    
    func disconnectDropbox() {
        syncTask?.cancel()
        DropboxClientsManager.unlinkClients()
        isLoggedIn = false
    }
}
