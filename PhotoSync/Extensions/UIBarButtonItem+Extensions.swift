//
//  UIBarButtonItem+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit

extension UIBarButtonItem {
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, style: .plain, target: nil, action: nil)
        closureSleeve = ClosureSleeve(closure: action)
        self.target = closureSleeve
        self.action = #selector(ClosureSleeve.invoke)
    }
}
