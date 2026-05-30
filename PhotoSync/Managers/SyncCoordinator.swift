// Copyright 2022 Thomas Insam. All rights reserved.

import CoreData
import Combine
import Foundation
import Photos
import SwiftyDropbox
import UIKit

struct ServiceError: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let message: String
    let error: Error?
}

@MainActor
protocol SyncCoordinator: Observable {
    var isLoggedIn: Bool { get }
    var dropboxEmail: String? { get }

    /// Progress for individual jobs
    var states: [TaskProgress] { get }
    /// Erorrs from jobs
    var errors: [ServiceError] { get }
    /// Set once we have worked out an upload plan
    var pendingPlan: UploadManager.SyncPlan? { get }

    func connectDropbox()
    func disconnectDropbox()

    func sync() async
    /// Call when there is a plan to start sync
    func confirmPlan() async
    /// Fetch content hashes for unknown items only, then restart sync
    func confirmPlanFetchOnly() async
}

/// Master coordinator for the whole sync operation, tracks state, and it's also the view
/// model because i am very good at architecture.
@MainActor
@Observable
class SyncCoordinatorImpl: SyncCoordinator {
    let database: Database
    let progressManager = ProgressManager()
    var photoManager: PhotoKitManager?
    var dropboxManager: DropboxManager?
    var uploadManager: UploadManager?
    
    // set if there's a sync running
    var syncTask: Task<Void, Never>?

    // set while waiting for the user to confirm a planned sync
    var pendingPlan: UploadManager.SyncPlan?

    // UI state
    var isLoggedIn: Bool = false
    var dropboxEmail: String?
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
        if dropboxEmail == nil {
            Task {
                if let account = try? await dropboxClient?.users.getCurrentAccount().asyncResponse() {
                    dropboxEmail = account.email
                }
            }
        }
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
        
        progressManager.reset()
        
        photoManager = PhotoKitManager(
            database: database,
            progressManager: progressManager,
            errorUpdate: self.logError,
        )
        
        dropboxManager = DropboxManager(
            database: database,
            dropboxClient: client,
            progressManager: progressManager,
            errorUpdate: self.logError,
        )
        
        uploadManager = UploadManager(
            database: database,
            dropboxClient: client,
            progressManager: progressManager,
            errorUpdate: self.logError,
        )
        
        // Sync photos and dropbox at the same time
        await withTaskGroup { group in
            group.addTask {
                NSLog("%@", "Starting photo sync")
                await self.photoManager?.sync()
            }
            group.addTask {
                NSLog("%@", "Starting dropbox sync")
                await self.dropboxManager?.sync()
            }
        }
        
        // Those both need to have passed otherwise it's not safe to do any writes.
        guard errors.isEmpty, let allAssets = photoManager?.allAssets else {
            logError(ServiceError(path: "/", message: "Sync failed, aborting upload", error: nil))
            return
        }
        
        NSLog("%@", "Planning upload")
        let plan: UploadManager.SyncPlan?
        do {
            plan = try await uploadManager?.plan(allAssets: allAssets)
        } catch {
            logError(ServiceError(path: "/", message: error.localizedDescription, error: error))
            return
        }
        
        pendingPlan = plan
    }
    
    func confirmPlan() async {
        guard let plan = pendingPlan else {
            return
        }
        NSLog("%@", "Starting upload")
        pendingPlan = nil

        let identifier = beginBackgroundSync()
        defer { endBackgroundSync(identifier) }
        UIApplication.shared.isIdleTimerDisabled = true

        await uploadManager?.execute(plan: plan)
        await sync()
        if pendingPlan?.isEmpty == true {
            pendingPlan?.removeStates()
            pendingPlan = nil
        }

        UIApplication.shared.isIdleTimerDisabled = false
    }

    func confirmPlanFetchOnly() async {
        guard let plan = pendingPlan else {
            return
        }
        NSLog("%@", "Starting hash fetch for unknowns")
        pendingPlan = nil

        let identifier = beginBackgroundSync()
        defer { endBackgroundSync(identifier) }
        UIApplication.shared.isIdleTimerDisabled = true

        await uploadManager?.fetchUnknownOnly(plan: plan)

        if let allAssets = photoManager?.allAssets {
            NSLog("%@", "Re-planning after hash fetch")
            do {
                pendingPlan = try await uploadManager?.plan(allAssets: allAssets)
            } catch {
                logError(ServiceError(path: "/", message: error.localizedDescription, error: error))
            }
        }

        UIApplication.shared.isIdleTimerDisabled = false

    }

    private func beginBackgroundSync() -> UIBackgroundTaskIdentifier? {
        var identifier: UIBackgroundTaskIdentifier?
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Sync") {
            NSLog("Stopping background task")
            MainActor.assumeIsolated {
                if let identifier {
                    UIApplication.shared.endBackgroundTask(identifier)
                }
            }
        }
        return identifier
    }

    private func endBackgroundSync(_ identifier: UIBackgroundTaskIdentifier?) {
        if let identifier {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
    
    func connectDropbox() {
        // We need something to present a view controller from
        let controller = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.rootViewController

        let scopeRequest = ScopeRequest(
            scopeType: .user,
            scopes: ["files.metadata.read", "files.content.write", "account_info.read"],
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
        syncTask = nil
        DropboxClientsManager.unlinkClients()
        isLoggedIn = false
        dropboxEmail = nil
        progressManager.reset()
        pendingPlan = nil
    }
}
