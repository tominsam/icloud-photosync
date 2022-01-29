//
//  AppDelegate.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import CoreData
import SwiftyDropbox
import Photos

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    static var shared = UIApplication.shared.delegate as! AppDelegate

    lazy var window: UIWindow? = UIWindow()
    lazy var navigationController = UINavigationController()

    lazy var persistentContainer: NSPersistentContainer = {
        let persistentContainer = NSPersistentContainer(name: "PhotoSync")
        // this completion handler is called synchonously by default
        persistentContainer.loadPersistentStores(completionHandler: { _, error in
            if let error = error as NSError? {
                // If there's an error, just dump the database on the floor
                let alert = UIAlertController.simpleAlert(title: "Database Error", message: error.localizedDescription, action: "Reset Database") { _ in
                    // TODO this is the entire application support folder, it's way too destuctive and the app doesn't recover from this
                    try! FileManager.default.removeItem(at: NSPersistentContainer.defaultDirectoryURL())
                    persistentContainer.loadPersistentStores { _, error in
                        if let error = error as NSError? {
                            fatalError(error.localizedDescription)
                        }
                    }
                }
                self.navigationController.present(alert, animated: true, completion: nil)
            }
        })
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
        return persistentContainer
    }()

    lazy var photoKitManager = PhotoKitManager()
    lazy var dropboxManager = DropboxManager()
    lazy var syncManager = SyncManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")
        window!.rootViewController = navigationController
        window!.makeKeyAndVisible()
        navigationController.viewControllers = [StatusViewController()]
        //navigationController.viewControllers = [PhotosViewController()]
        updateDropboxNavigationItem()
        startDropboxSync()
        startPhotoSync()
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return DropboxClientsManager.handleRedirectURL(url) { authResult in
            switch authResult {
            case .success(let accessToken):
                self.dropboxManager.logIn(accessToken: accessToken.accessToken)
                self.updateDropboxNavigationItem()
            case .cancel:
                break
            case .error(_, let description):
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

    func applicationDidBecomeActive(_ application: UIApplication) {
    }


    func startPhotoSync() {
        // Request photo access if we need it
        switch PHPhotoLibrary.authorizationStatus() {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.startPhotoSync()
                }
            }
        case .authorized:
            photoKitManager.sync()
        default:
            // TODO
            let alert = UIAlertController.simpleAlert(title: "Error", message: "Photo permission", action: "OK") { _ in
                // TODO open settings or something
            }
            navigationController.present(alert, animated: true, completion: nil)
        }
    }

    func startDropboxSync() {
        dropboxManager.sync()
    }

    func updateDropboxNavigationItem() {
        let item: UIBarButtonItem
        if dropboxManager.isLoggedIn {
            item = UIBarButtonItem(title: "Log out", action: {
                self.dropboxManager.logOut()
                self.updateDropboxNavigationItem()
            })
        } else {
            item = UIBarButtonItem(title: "Connect to Dropbox", action: {
                DropboxClientsManager.authorizeFromController(
                    UIApplication.shared,
                    controller: self.navigationController,
                    openURL: { UIApplication.shared.open($0, options: [:], completionHandler: nil) })
            })
        }

        navigationController.viewControllers.first?.navigationItem.rightBarButtonItem = item
    }

}

