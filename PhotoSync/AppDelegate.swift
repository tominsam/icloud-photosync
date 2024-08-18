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
    var syncManager: SyncManager?

    func loadPersistentContainer(completion: @escaping (NSPersistentContainer) -> Void) {
        let persistentContainer = NSPersistentContainer(name: "PhotoSync")

        // this completion handler is called synchonously by default
        persistentContainer.loadPersistentStores(completionHandler: { _, error in
            if let error {
                NSLog("%@", "Failed to open database \(error), re-creating")
                let storeURL = persistentContainer.persistentStoreCoordinator.persistentStores.first!.url!
                try! persistentContainer.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
                persistentContainer.loadPersistentStores { _, error in
                    if let error = error as NSError? {
                        fatalError(error.localizedDescription)
                    }
                    persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
                    completion(persistentContainer)
                }
            } else {
                persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
                completion(persistentContainer)
            }
        })
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()

        loadPersistentContainer { [self] container in
            syncManager = SyncManager(persistentContainer: container)
            self.navigationController.viewControllers = [
                StatusViewController(syncManager: syncManager!)
            ]
            requestPhotoPermission()
        }

        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    func application(_: UIApplication, open url: URL, options _: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { [self] authResult in
            switch authResult {
            case .success:
                requestPhotoPermission()
            case .cancel:
                break
            case let .error(_, description):
                navigationController.present(UIAlertController.simpleAlert(
                    title: "Dropbox Error",
                    message: description ?? "Unknown error",
                    action: "OK"
                ), animated: true, completion: nil)
            case .none:
                break
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NSLog("Entering background, \(application.backgroundTimeRemaining) remaining")
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func applicationDidBecomeActive(_: UIApplication) {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func requestPhotoPermission() {
        // Request photo access if we need it
        switch PHPhotoLibrary.authorizationStatus() {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { _ in
                DispatchQueue.main.async {
                    self.requestPhotoPermission()
                }
            }
        case .authorized:
            startSync()
        default:
            // TODO: open settings or something, don't use alert here, etc.
            let alert = UIAlertController.simpleAlert(
                title: "Error",
                message: "Photo permission not granted",
                action: "OK"
            ) { _ in
            }
            navigationController.present(alert, animated: true, completion: nil)
        }
    }

    func startSync() {
        syncManager?.maybeSync()
    }
}
