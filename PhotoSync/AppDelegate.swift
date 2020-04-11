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
import KeychainSwift
import Photos

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"

    static var shared: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

    lazy var window: UIWindow? = UIWindow()
    lazy var navigationController = UINavigationController()

    lazy var keychain = KeychainSwift()
    var persistentContainer: NSPersistentContainer!

    var dropboxClient: DropboxClient?
    lazy var photoKitManager = PhotoKitManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")

        window!.rootViewController = navigationController
        window!.makeKeyAndVisible()

        persistentContainer = NSPersistentContainer(name: "PhotoSync")
        persistentContainer.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                self.navigationController.present(UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert), animated: true, completion: nil)
//                fatalError("Unresolved error \(error), \(error.userInfo)")
            } else {
                self.persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
                self.updateViewController()
            }
        })

        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if let authResult = DropboxClientsManager.handleRedirectURL(url) {
            switch authResult {
            case .success(let accessToken):
                logIn(accessToken: accessToken.accessToken)

            case .cancel:
                break

            case .error(_, let description):
                navigationController.present(UIAlertController(title: "Error", message: description, preferredStyle: .alert), animated: true, completion: nil)
            }
        }
        return true
    }

    // MARK: - Core Data Saving support
    func saveContext () {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let error = error as NSError
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
    }

    func updateViewController() {
        
        if let accessToken = keychain.get(Self.KeychainDropboxAccessToken) {
            dropboxClient = DropboxClient(accessToken: accessToken)
            navigationController.viewControllers = [PhotosViewController()]

            // Check that we're still the user we think we are.
            dropboxClient?.users.getCurrentAccount().response { _, error in
                if case .authError = error {
                    self.logOut()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                self.startSync()
            }

        } else {
            dropboxClient = nil
            navigationController.viewControllers = [ConnectViewController()]
        }
    }

    func startSync() {
        switch PHPhotoLibrary.authorizationStatus() {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.startSync()
                }
            }
        case .authorized:
            photoKitManager.sync()
        default:
            // TODO
            navigationController.present(UIAlertController(title: "Error", message: "Photo permission", preferredStyle: .alert), animated: true, completion: nil)
        }
    }

    func logIn(accessToken: String) {
        keychain.set(accessToken, forKey: Self.KeychainDropboxAccessToken)
        updateViewController()
    }

    func logOut() {
        dropboxClient?.auth.tokenRevoke().response { _, _ in
            // Don't actually care, this is best effort
        }
        keychain.delete(Self.KeychainDropboxAccessToken)
        updateViewController()
    }

}

