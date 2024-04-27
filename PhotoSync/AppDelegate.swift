//
//  AppDelegate.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import CoreData
import Photos
import SwiftyDropbox
import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    lazy var window: UIWindow? = UIWindow()
    lazy var navigationController = UINavigationController()

    lazy var persistentContainer: NSPersistentContainer = {
        let persistentContainer = NSPersistentContainer(name: "PhotoSync")

        var failed = false
        // this completion handler is called synchonously by default
        persistentContainer.loadPersistentStores(completionHandler: { _, error in
            if let error = error as NSError? {
                failed = true
            }
        })
        // If store creation failed, delete the database and try again (it's just a cache)
        if failed {
            NSLog("%@", "Failed to open database, re-creating")
            let storeURL = persistentContainer.persistentStoreCoordinator.persistentStores.first!.url!
            try! persistentContainer.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
            persistentContainer.loadPersistentStores { _, error in
                if let error = error as NSError? {
                    fatalError(error.localizedDescription)
                }
            }
        }

        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
        return persistentContainer
    }()

    lazy var syncManager = SyncManager(persistentContainer: persistentContainer)

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")
        window!.rootViewController = navigationController
        window!.makeKeyAndVisible()
        navigationController.viewControllers = [StatusViewController(syncManager: syncManager)]
        // navigationController.viewControllers = [PhotosViewController()]
        updateDropboxNavigationItem()
        startDropboxSync()
        startPhotoSync()
        return true
    }

    func application(_: UIApplication, open url: URL, options _: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { authResult in
            switch authResult {
            case .success:
                self.updateDropboxNavigationItem()
                self.syncManager.maybeSync()
            case .cancel:
                break
            case let .error(_, description):
                self.navigationController.present(UIAlertController.simpleAlert(
                    title: "Dropbox Error",
                    message: description ?? "Unknown error",
                    action: "OK"
                ), animated: true, completion: nil)
            case .none:
                break
            }
        }
    }

    func applicationDidBecomeActive(_: UIApplication) {}

    func startPhotoSync() {
        // Request photo access if we need it
        switch PHPhotoLibrary.authorizationStatus() {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { _ in
                DispatchQueue.main.async {
                    self.startPhotoSync()
                }
            }
        case .authorized:
            syncManager.maybeSync()
        default:
            // TODO: open settings or something, don't use alert here, etc.
            let alert = UIAlertController.simpleAlert(title: "Error", message: "Photo permission", action: "OK") { _ in
            }
            navigationController.present(alert, animated: true, completion: nil)
        }
    }

    func startDropboxSync() {
        syncManager.maybeSync()
    }

    func updateDropboxNavigationItem() {
        let item: UIBarButtonItem
        if syncManager.isLoggedIn {
            item = UIBarButtonItem(title: "Log out", action: {
                DropboxClientsManager.resetClients()
                self.updateDropboxNavigationItem()
                self.startDropboxSync()
            })
        } else {
            item = UIBarButtonItem(title: "Connect to Dropbox", action: {
                let scopeRequest = ScopeRequest(
                    scopeType: .user,
                    scopes: ["files.metadata.read", "files.content.write"],
                    includeGrantedScopes: false)
                DropboxClientsManager.authorizeFromControllerV2(
                    UIApplication.shared,
                    controller: self.navigationController,
                    loadingStatusDelegate: nil,
                    openURL: { UIApplication.shared.open($0, options: [:], completionHandler: nil) },
                    scopeRequest: scopeRequest)
            })
        }

        navigationController.viewControllers.first?.navigationItem.rightBarButtonItem = item
    }
}
