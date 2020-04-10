//
//  PhotosViewController.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import SwiftyDropbox

class PhotosViewController: UIViewController {

    var client: DropboxClient { AppDelegate.shared.dropboxClient! }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Log out", action: {
            AppDelegate.shared.logOut()
        })

        client.files.listFolder(path: "").response { files, error in
            NSLog("git \(files) \(error)")
        }
    }
}
