//
//  UIControl+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit

class ClosureSleeve {
    let closure: () -> ()

    init(closure: @escaping () -> ()) {
        self.closure = closure
    }

    @objc
    func invoke() {
        self.closure()
    }
}

extension NSObject {

    private struct ClosureSleeveKey {
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
    func addAction(for controlEvents: UIControl.Event = .primaryActionTriggered, action: @escaping () -> ()) {
        closureSleeve = ClosureSleeve(closure: action)
        addTarget(closureSleeve, action: #selector(ClosureSleeve.invoke), for: controlEvents)
    }
}
