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

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"

    static var shared: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

    lazy var window: UIWindow? = UIWindow()
    lazy var navigationController = UINavigationController()

    lazy var keychain = KeychainSwift()

    var dropboxClient: DropboxClient?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")
        window!.rootViewController = navigationController
        window!.makeKeyAndVisible()
        updateViewController()
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

    // MARK: - Core Data stack
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "PhotoSync")
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        return container
    }()

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

        } else {
            dropboxClient = nil
            navigationController.viewControllers = [ConnectViewController()]
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

