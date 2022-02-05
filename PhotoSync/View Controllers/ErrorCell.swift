//
//  ErrorCell.swift
//  PhotoSync
//
//  Created by Thomas Insam on 2/3/22.
//

import Foundation
import UIKit

class ErrorCell: UITableViewCell {
    override init(style _: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
