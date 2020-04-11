//
//  Alert+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit

extension UIAlertController {
    static func simpleAlert(title: String, message: String, action: String, handler: ((UIAlertAction) -> Void)? = nil) -> UIAlertController {
        let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let action = UIAlertAction(title: action, style: .default, handler: handler)
        controller.addAction(action)
        return controller

    }
}
