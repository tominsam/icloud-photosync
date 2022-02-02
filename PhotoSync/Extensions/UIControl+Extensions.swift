//
//  UIControl+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit

class ClosureSleeve {
    let closure: () -> Void

    init(closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc
    func invoke() {
        closure()
    }
}

extension NSObject {
    private enum ClosureSleeveKey {
        static var closureSleeve = "closureSleeve"
    }

    var closureSleeve: ClosureSleeve? {
        get {
            return objc_getAssociatedObject(self, &ClosureSleeveKey.closureSleeve) as? ClosureSleeve
        }
        set(newValue) {
            objc_setAssociatedObject(self, &ClosureSleeveKey.closureSleeve, newValue, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

extension UIControl {
    func addAction(for controlEvents: UIControl.Event = .primaryActionTriggered, action: @escaping () -> Void) {
        closureSleeve = ClosureSleeve(closure: action)
        addTarget(closureSleeve, action: #selector(ClosureSleeve.invoke), for: controlEvents)
    }
}
