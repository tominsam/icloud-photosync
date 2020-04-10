//
//  ConnectViewController.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import SwiftyDropbox

class ConnectViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let button = UIButton(type: .roundedRect)
        button.setTitle("Connect", for: .normal)
        button.addAction {
            DropboxClientsManager.authorizeFromController(
                UIApplication.shared,
                controller: self,
                openURL: { UIApplication.shared.open($0, options: [:], completionHandler: nil) }
            )

        }
        view.addSubviewInCenter(button)
    }


}

