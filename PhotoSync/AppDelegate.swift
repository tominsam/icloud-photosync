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
    var persistentContainer: NSPersistentContainer?

    var dropboxClient: DropboxClient?
    lazy var photoKitManager = PhotoKitManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")
        window!.rootViewController = navigationController
        window!.makeKeyAndVisible()
        loadPersistentStore()
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
                navigationController.present(UIAlertController.simpleAlert(title: "Dropbox Error", message: description, action: "OK"), animated: true, completion: nil)
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        startSync()
    }

    func loadPersistentStore() {
        guard persistentContainer == nil else {
            return
        }

        let persistentContainer = NSPersistentContainer(name: "PhotoSync")
        persistentContainer.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                let alert = UIAlertController.simpleAlert(title: "Database Error", message: error.localizedDescription, action: "OK") { _ in
                    try! FileManager.default.removeItem(at: NSPersistentContainer.defaultDirectoryURL())
                    self.loadPersistentStore()
                }
                self.navigationController.present(alert, animated: true, completion: nil)
            } else {
                persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
                self.persistentContainer = persistentContainer
                self.updateViewController()
            }
        })
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
        guard persistentContainer != nil else { return }

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
            let alert = UIAlertController.simpleAlert(title: "Error", message: "Photo permission", action: "OK") { _ in
                // TODO open settings or something
            }
            navigationController.present(alert, animated: true, completion: nil)
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

